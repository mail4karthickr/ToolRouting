/*
Evaluation for the LLM router in its real job: STAGE 2 of the cascade.

Each sample runs MiniLMRouter.retrieve first and hands the resulting
top-k shortlist to LLMRouter.select, so the LLM is graded on the input it
actually gets in production — not on a hand-written shortlist, and not on
the whole catalog. What comes back is the model's raw plan.

Deliberately NOT run here: HybridRouter's policy layer. No
none-collapse, no candidate-set validation, no dedupe. That code exists
to repair or reject bad plans, so running it would hide the mistakes this
eval is looking for. HybridRouterTests runs the same two stages WITH the
policy on top — the gap between the two numbers is what the policy layer
is worth.

Same shape as the embedding eval: the dataset is BALANCED by the size of
the answer, 7 samples each, so the mean cannot be carried by whichever
case happens to be easy. Two buckets have since outgrown seven, both on
2026-08-12 and both for the same underlying change — tools that used to
accept a name or a place now take an identifier only:

  none (9)     "Find ATMs in Chicago" and "Is there a branch in Chicago?"
               moved here when the two location tools stopped taking
               place names. An uncovered ARGUMENT is a genuinely
               different reason to escalate from an uncovered
               capability, so they were added rather than swapped in.
  3 calls (8)  "Is the airport branch open on Saturday?" moved up from
               1 call when branch_hours started taking a branch ID.
               Naming the branch no longer skips a step, and a router
               that thinks it does is exactly what this sample catches.

  none     the request needs an action, an uncovered capability, or
           mixes one in — the whole thing goes to the cloud. This bucket
           exists only here; the embedder has no such output.
  1 call   a single lookup, including the chain-skip controls where a
           second call would be WRONG
  2 calls  ordered chains and independent fan-out
  3 calls  the same, one step deeper

Bucketing is by CALL count, not distinct tools: "June and July
statements" is two calls of bank_statement, and getting that to two is
the thing being measured.

Plans stop at three calls, one short of the .maximumCount(4) the schema
allows. That headroom is the point: a router that over-decomposes has
room to emit a fourth call and fail visibly, where a dataset sitting on
the ceiling would have the schema silently truncate the mistake. Whether
four-call plans work end to end is a Stage-1 question anyway — the
Recall@5 run put four-intent retrieval at 4/7, so those requests are
blocked on query decomposition (Plan/Todo.txt), not on this router.

What is graded is the plan, exactly: right tools, right count, and right
order wherever the sample says order is part of the contract. Partial
credit would hide the failure that matters — a plan with a missing or
transposed step does not execute.

Reading a failure: check the shortlist first. If Stage 1 never retrieved
the tool, the LLM could not have picked it and the sample is really a
retrieval failure — EmbeddingRouterTests' Recall@5 is the place to
confirm that. Only once the tool was on the list is the miss this
router's.

Nothing here is shared with the embedding or hybrid evals: this file owns
its dataset, its types and its metric outright, so a change made to grade
one router can never silently move another's number.

Needs BOTH stages: MLX (Apple-silicon Metal) plus a one-time MiniLM
weight download, and Apple Intelligence. Device or Mac only, never the
iOS simulator. Every sample is a full generation with no session reuse,
so this eval takes minutes.
*/

import Evaluations
import Foundation
import FoundationModels
import Testing
@testable import ToolRoutingStrategies

// MARK: - Evaluation

/// One routing plan: the tools in the order they must run.
struct LLMSelection: Codable, Sendable {
    /// Tool display names, in plan order.
    var tools: [String]
    /// Whether the expected order is part of the contract (dependent
    /// chains) or the tools may appear in any order (independent fan-out).
    var orderMatters: Bool = true
}

/// Grades `LLMRouter.select` over a real Stage-1 shortlist.
struct LLMRoutingEvaluation: Evaluation {
    func subject(from sample: ModelSample<LLMSelection>) async throws -> ModelSubject<LLMSelection> {
        do {
            return ModelSubject(value: LLMSelection(
                tools: try await Self.selectOverShortlist(for: sample.promptDescription)
            ))
        } catch where LLMRouter.isDecliningToRoute(error) {
            // Mirror production: a guardrail trip or refusal degrades to
            // the cloud, so it is graded as the `none` the user would see.
            // The eval grades the routing SYSTEM (model + fallback
            // policy), not the raw model.
            //
            // Only those two. A context overflow or a timeout is a broken
            // run, not an abstention, and scoring it as `none` would hand
            // the router credit for failing.
            return ModelSubject(value: LLMSelection(tools: ["none"]))
        }
    }

    /// Stage 1 then Stage 2, exactly as HybridRouter wires them,
    /// minus the policy it applies afterwards. Fresh routers per sample:
    /// no session, cache or transcript can leak context from the previous
    /// question. The MLX weights and the persisted tool index are shared
    /// across instances, so that stays cheap.
    @MainActor
    private static func selectOverShortlist(for query: String) async throws -> [String] {
        // k comes from the hybrid router's own config rather than a copy,
        // so retuning the shortlist size cannot leave this eval measuring
        // a k that production no longer uses.
        let shortlist = try await MiniLMRouter().retrieve(query, topK: ChatAgent.Config().topK)

        // Stage 1 abstained, so Stage 2 never runs and the request goes to
        // the cloud. Counts as "none" because that is the outcome, but it
        // is worth noticing when a `none` sample passes this way: the LLM
        // was never asked, so the sample proved nothing about it.
        guard !shortlist.isEmpty else { return ["none"] }

        let candidates = shortlist.compactMap { ToolCatalog.byName[$0.toolName] }
        let plan = try await LLMRouter().select(query, from: candidates)

        // The RAW selection, with no policy applied. Stage 2 now emits
        // tool NAMES and `none` is one of them, so an abstention already
        // reads as ["none"] with nothing to translate.
        //
        // Deliberately unrepaired: a selection mixing `none` with real
        // tools stays mixed and fails the comparison. The hybrid router
        // collapses that to an escalation, and doing the same here would
        // grade the policy instead of the model.
        return plan.toolNames
    }

    // A note on `orderMatters`. It is true for pure dependency chains,
    // where a later call literally cannot run without an earlier one's
    // result. It is false when the request is independent lookups, and
    // ALSO false when a chain and an independent lookup share one
    // request ("nearest ATM and my withdrawal limit") — there the chain's
    // internal order matters but its position relative to the extra
    // lookup does not, and a single flag cannot say that. Those samples
    // therefore under-test ordering by design.
    var dataset = ArrayLoader(samples: [
        // MARK: none (9) — the cloud class
        //
        // Each of the first five shares its noun with a real tool, so a
        // router matching on topic alone gets every one of them wrong.

        ModelSample(prompt: "Freeze my debit card", expected: LLMSelection(tools: ["none"])),
        ModelSample(prompt: "Increase my ATM withdrawal limit", expected: LLMSelection(tools: ["none"])),
        ModelSample(prompt: "I want to dispute a charge from Amazon", expected: LLMSelection(tools: ["none"])),
        ModelSample(prompt: "cancel my netflix payment", expected: LLMSelection(tools: ["none"])),
        // The conversion QUESTION is a lookup; moving money is not.
        ModelSample(prompt: "Send 200 euros to my friend in Berlin", expected: LLMSelection(tools: ["none"])),
        // Uncovered capability rather than an action.
        ModelSample(prompt: "What are your mortgage rates for first-time buyers?", expected: LLMSelection(tools: ["none"])),
        // All-or-nothing policy: half the request is serviceable, the
        // whole thing still goes to the cloud with full context.
        ModelSample(prompt: "Show my balance and transfer $200 to savings", expected: LLMSelection(tools: ["none"])),
        // Uncovered ARGUMENT rather than an uncovered capability, and the
        // only kind of sample like that: ATMs and branches are both
        // covered, but find_nearest_atm and find_nearest_branch take
        // coordinates and get_location only ever yields the device's own,
        // so no chain reaches Chicago. The ATM one was ["find_atm"] until
        // 2026-08-12; the branch one was ["find_branch"] until the branch
        // tool took the same treatment. A named place is now `none`
        // whichever of the two it asks for.
        ModelSample(prompt: "Find ATMs in Chicago", expected: LLMSelection(tools: ["none"])),
        ModelSample(prompt: "Is there a branch in Chicago?", expected: LLMSelection(tools: ["none"])),

        // MARK: 1 call (7)
        //
        // Six are the lookup half of a verb pair above or a plain single
        // lookup. ONE is a chain-skip control — "Convert $500 to yen",
        // where the user names the amount, so emitting a lookup step
        // first is a wrong answer rather than a harmless extra one. The
        // branch version used to be the second such control; it stopped
        // being one on 2026-08-12, when branch_hours started taking an ID
        // and naming the branch stopped saving a step.

        ModelSample(prompt: "What's my debit card number?", expected: LLMSelection(tools: ["card_number"])),
        ModelSample(prompt: "What's my daily ATM withdrawal limit?", expected: LLMSelection(tools: ["card_limits"])),
        ModelSample(prompt: "Any update on the charge I disputed?", expected: LLMSelection(tools: ["get_dispute_status"])),
        ModelSample(prompt: "What payments are scheduled to go out next week?", expected: LLMSelection(tools: ["scheduled_payments"])),
        // Keeps the bucket at seven. Replaced the branch-in-Chicago
        // sample, which moved to `none` when find_nearest_branch stopped
        // taking place names — no location sample can be a chain-skip
        // control any more, because no location tool accepts a place.
        ModelSample(prompt: "What's my routing number?", expected: LLMSelection(tools: ["routing_number"])),
        // Took the airport-branch slot when that sample became a chain.
        ModelSample(prompt: "How many reward points do I have?", expected: LLMSelection(tools: ["reward_points"])),
        ModelSample(prompt: "Convert $500 to yen", expected: LLMSelection(tools: ["convert_currency"])),

        // MARK: 2 calls (7)

        // Ordered — the second call needs the first one's result.
        ModelSample(prompt: "Find the nearest ATM", expected: LLMSelection(tools: ["get_location", "find_nearest_atm"])),
        ModelSample(prompt: "How much is my savings balance in euros?", expected: LLMSelection(tools: ["account_balance", "convert_currency"])),
        // Independent — any order.
        ModelSample(
            prompt: "Show my balance and this week's transactions",
            expected: LLMSelection(tools: ["account_balance", "list_transactions"], orderMatters: false)
        ),
        ModelSample(
            prompt: "What's my credit score and do I have any pending payments?",
            expected: LLMSelection(tools: ["credit_score", "pending_payments"], orderMatters: false)
        ),
        ModelSample(
            prompt: "What fees did I pay and what interest did I earn last month?",
            expected: LLMSelection(tools: ["fees_and_charges", "interest_earned"], orderMatters: false)
        ),
        // Same tool twice, different parameters — the call COUNT is the
        // measurement here, not the tool choice.
        ModelSample(
            prompt: "Get my June and July statements for checking",
            expected: LLMSelection(tools: ["bank_statement", "bank_statement"], orderMatters: false)
        ),
        // Informal, and two intents the model has to keep apart: the
        // Starbucks clause must not swallow the balance clause.
        ModelSample(
            prompt: "starbucks charges this month and whats my balance",
            expected: LLMSelection(tools: ["search_transactions", "account_balance"], orderMatters: false)
        ),

        // MARK: 3 calls (8)

        // Three-step chain: location → branch → its hours.
        ModelSample(prompt: "How late is the nearest branch open?", expected: LLMSelection(tools: ["get_location", "find_nearest_branch", "branch_hours"])),
        // The same chain with the branch NAMED, which is the harder half:
        // the model has to notice that naming the branch does not supply
        // the ID branch_hours wants, so no step can be skipped. This is
        // the sample that catches a router treating a name as an ID.
        ModelSample(prompt: "Is the airport branch open on Saturday?", expected: LLMSelection(tools: ["get_location", "find_nearest_branch", "branch_hours"])),
        // Chain plus an unrelated lookup riding along.
        ModelSample(
            prompt: "Find the nearest ATM and tell me my daily withdrawal limit",
            expected: LLMSelection(tools: ["get_location", "find_nearest_atm", "card_limits"], orderMatters: false)
        ),
        // Independent fan-out, three ways.
        ModelSample(
            prompt: "Show my balance, my pending payments and my scheduled payments",
            expected: LLMSelection(tools: ["account_balance", "pending_payments", "scheduled_payments"], orderMatters: false)
        ),
        ModelSample(
            prompt: "What's my credit score, my credit limit and my reward points?",
            expected: LLMSelection(tools: ["credit_score", "card_limits", "reward_points"], orderMatters: false)
        ),
        ModelSample(
            prompt: "I need my routing number, my account number and my card number",
            expected: LLMSelection(tools: ["routing_number", "account_number", "card_number"], orderMatters: false)
        ),
        // A dependency INSIDE a three-call plan: the balance feeds the
        // conversion, and the transactions lookup is independent of both.
        ModelSample(
            prompt: "Convert my savings balance to euros and show my recent transactions",
            expected: LLMSelection(tools: ["account_balance", "convert_currency", "list_transactions"], orderMatters: false)
        ),
        ModelSample(
            prompt: "Show my recent transactions, my Amazon purchases and my June statement",
            expected: LLMSelection(tools: ["list_transactions", "search_transactions", "bank_statement"], orderMatters: false)
        )
    ])

    /// Pass when every expected tool was selected — in the expected order
    /// when the sample says order matters, in any order otherwise. Extra
    /// or missing tools fail either way.
    let routingAccuracy = Metric("Routing Accuracy")

    var evaluators: Evaluators {
        Evaluator { input, subject in
            guard let expected = input.expected else { return routingAccuracy.ignore() }

            let actual = subject.value.tools
            let matches = expected.orderMatters
                ? actual == expected.tools
                : actual.sorted() == expected.tools.sorted()

            if matches {
                return routingAccuracy.passing(rationale: actual.joined(separator: " → "))
            }
            return routingAccuracy.failing(
                rationale: "Expected \(expected.tools.joined(separator: " → ")); got \(actual.joined(separator: " → "))"
            )
        }
    }

    func aggregateMetrics(using aggregator: inout MetricsAggregator) {
        aggregator.computeMean(of: routingAccuracy)
    }
}

// MARK: - Suite

@Suite("LLM Router Evaluations")
struct LLMRouterTests {
    static let evaluation = LLMRoutingEvaluation()

    private static func info(_ strategy: String) -> [String: String] {
        [
            "ModelName": "SystemLanguageModel (whole catalog in prompt)",
            "Strategy": strategy,
            "AppVersion": "1.0",
            "Feature": "Tool selection (routing) for the banking assistant"
        ]
    }

    @Test(
        "LLM Router Tool Selection",
        .enabled(if: SystemLanguageModel.default.isAvailable),
        .evaluates(evaluation, info: info("On-Device LLM Router"))
    )
    func evaluateToolSelection() async throws {
        let result = EvaluationContext.current.result

        // Measured 0.679 (19/28) on 2026-08-06, iPhone 17 Pro, before the
        // Stage-2 prompt regained its dependency and verb rules:
        //   none 3/7 · 1 call 7/7 · 2 calls 4/7 · 3 calls 5/7
        // Every multi-call miss was a correct plan truncated after the
        // first tool. This 0.8 is therefore a TARGET, not a floor the
        // code has met — it fails until those two rules earn it back.
        //
        // The number is not comparable to the embedding router's:
        // different samples, different question. And read the per-bucket
        // breakdown in the .xcevalresult attachment rather than the mean —
        // 0.8 made of "none 7/7, 3 calls 2/7" means something completely
        // different from an even spread.
        #expect(result.aggregateValue(.mean(of: Self.evaluation.routingAccuracy)) >= 0.8)
    }
}
