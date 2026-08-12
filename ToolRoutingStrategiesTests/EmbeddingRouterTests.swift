/*
Evaluation for the embedding router (MiniLM / MLX), self-contained.

What this router produces is a top-5 SHORTLIST, so exactly one thing is
measured: Recall@5 — of the tools a query's answer needs, how many made
the shortlist? Read as a mean and as a minimum.

Nothing else is graded here, deliberately:

  • Rank is not measured. Whoever consumes the shortlist sees all five
    entries, so the right tool ranking #1 or #5 changes nothing. MRR or
    top-1 accuracy would penalize behavior that costs nothing.
  • Precision is not measured. A shortlist is allowed to be generous;
    it is only forbidden to be missing something. The cost of the extra
    entries is attention dilution downstream, and that shows up where it
    is real — in HybridRouterTests' end-to-end number.
  • Chains, multi-intent, parameters and lookup-vs-action are not
    graded. There is no generation on this path, so measuring them says
    nothing about the embedder. They live in LLMRouterTests and
    HybridRouterTests.

Multi-tool queries DO belong here even though the router cannot order
them: retrieval can surface a whole chain's worth of tools at once, and
whether it does is precisely what recall asks.

Needs MLX (Apple-silicon Metal): run on device or a Mac, not the iOS
simulator. The first run downloads the MiniLM weights from the Hugging
Face Hub, so it needs network once.
*/

import Evaluations
import Foundation
import Testing
@testable import ToolRoutingStrategies

// MARK: - Evaluation

/// The ranked shortlist for one query. Order never matters: retrieval is
/// a similarity search, and the ranking is confidence, not a plan.
struct EmbeddingShortlist: Codable, Sendable {
    /// Tool display names above the similarity threshold, best first.
    var tools: [String]
    /// Cosine similarity per tool, parallel to `tools`.
    var scores: [Double] = []
}

/// Grades `MiniLMRouter.retrieve`: for a query whose answer needs N
/// tools, how many of them made the top-k shortlist?
struct EmbeddingRetrievalEvaluation: Evaluation {
    /// Shortlist size. HybridRouter happens to use the same k, but
    /// this eval measures the embedder on its own terms — change one
    /// without assuming the other must follow. Change it here and the
    /// metric's name should change with it.
    let topK = 5

    func subject(from sample: ModelSample<EmbeddingShortlist>) async throws -> ModelSubject<EmbeddingShortlist> {
        // Fresh router per sample. The downloaded MLX weights and the
        // persisted tool index are shared across instances, so this
        // stays cheap.
        let router = await MiniLMRouter()
        let retrieved = try await router.retrieve(sample.promptDescription, topK: topK)
        return ModelSubject(value: EmbeddingShortlist(
            tools: retrieved.map(\.toolName),
            scores: retrieved.map { Double($0.score) }
        ))
    }

    // Expected = the deduplicated tool SET a correct answer needs. For a
    // chain that is every step ("nearest ATM" needs get_location AND
    // find_nearest_atm); for a repeated lookup it is one entry (June and July
    // statements are both served by bank_statement).
    //
    // Balanced 7/7/8/7 across answer sizes — roughly a quarter each
    // needing one, two, three and four tools. The extra three-tool sample
    // is "What time does the Main St branch close?", which was a one-tool
    // query until branch_hours started taking an ID on 2026-08-12; it
    // moved rather than being dropped, because a named branch that STILL
    // needs the full chain is the case most likely to be got wrong.
    // That is NOT the production distribution,
    // where most requests want a single tool. It is deliberately weighted
    // toward the hard end so the mean says something: on a single-tool
    // dataset recall is a near-constant 1.0 and tells you nothing about
    // where retrieval breaks. Read the number as a stress test, not as an
    // estimate of field performance.
    //
    // The four-tool samples are the real gate. With k = 5 they leave one
    // spare slot: the query embedding is a blend of four topics, and all
    // four have to beat every distractor in the catalog.
    var dataset = ArrayLoader(samples: [
        // MARK: One tool (7)
        //
        // Weighted toward near-miss pairs and informal phrasing, since a
        // plainly-worded single-tool query is the case retrieval never
        // gets wrong.

        // "transactions": merchant-specific vs. general listing.
        ModelSample(prompt: "What did I spend at Starbucks?", expected: EmbeddingShortlist(tools: ["search_transactions"])),
        // "payments": processing now vs. scheduled future.
        ModelSample(prompt: "Do I have any payments still processing?", expected: EmbeddingShortlist(tools: ["pending_payments"])),
        // "credit": the score vs. the card's limit.
        ModelSample(prompt: "What's my credit limit?", expected: EmbeddingShortlist(tools: ["card_limits"])),
        // "number": account vs. routing vs. card.
        ModelSample(prompt: "I need my checking account number for direct deposit", expected: EmbeddingShortlist(tools: ["account_number"])),
        // Took the branch-hours slot when that sample became a three-tool
        // chain. "score" vs. "limit" is the same near-miss shape the
        // bucket is built from.
        ModelSample(prompt: "What's my credit score?", expected: EmbeddingShortlist(tools: ["credit_score"])),
        // Informal.
        ModelSample(prompt: "bal in savings?", expected: EmbeddingShortlist(tools: ["account_balance"])),
        ModelSample(prompt: "pts balance", expected: EmbeddingShortlist(tools: ["reward_points"])),

        // MARK: Two tools (7)
        //
        // Dependency chains and independent fan-out both land here — the
        // difference is the LLM's problem, not retrieval's. All the
        // shortlist has to do is hold both.

        ModelSample(prompt: "Find the nearest ATM", expected: EmbeddingShortlist(tools: ["get_location", "find_nearest_atm"])),
        ModelSample(prompt: "How much is my savings balance in euros?", expected: EmbeddingShortlist(tools: ["account_balance", "convert_currency"])),
        ModelSample(prompt: "Show my balance and this week's transactions", expected: EmbeddingShortlist(tools: ["account_balance", "list_transactions"])),
        ModelSample(prompt: "What's my credit score and do I have any pending payments?", expected: EmbeddingShortlist(tools: ["credit_score", "pending_payments"])),
        ModelSample(prompt: "What fees did I pay and what interest did I earn last month?", expected: EmbeddingShortlist(tools: ["fees_and_charges", "interest_earned"])),
        ModelSample(prompt: "Show my reward points and my credit card limit", expected: EmbeddingShortlist(tools: ["reward_points", "card_limits"])),
        // Informal.
        ModelSample(prompt: "starbucks charges this month and whats my balance", expected: EmbeddingShortlist(tools: ["search_transactions", "account_balance"])),

        // MARK: Three tools (8)

        // Three-step chain: location → branch → its hours.
        ModelSample(prompt: "How late is the nearest branch open?", expected: EmbeddingShortlist(tools: ["get_location", "find_nearest_branch", "branch_hours"])),
        // The SAME chain even though the branch is named, which is what
        // makes it worth keeping: branch_hours takes an ID, and naming
        // the branch does not produce one. Was a one-tool sample until
        // 2026-08-12.
        ModelSample(prompt: "What time does the Main St branch close?", expected: EmbeddingShortlist(tools: ["get_location", "find_nearest_branch", "branch_hours"])),
        // Chain plus an unrelated lookup riding along.
        ModelSample(prompt: "Find the nearest ATM and tell me my daily withdrawal limit", expected: EmbeddingShortlist(tools: ["get_location", "find_nearest_atm", "card_limits"])),
        // One topic area, three tools that share vocabulary — the case
        // where near-miss twins can crowd each other out.
        ModelSample(prompt: "Show my balance, my pending payments and my scheduled payments", expected: EmbeddingShortlist(tools: ["account_balance", "pending_payments", "scheduled_payments"])),
        ModelSample(prompt: "What's my credit score, my credit limit and my reward points?", expected: EmbeddingShortlist(tools: ["credit_score", "card_limits", "reward_points"])),
        ModelSample(prompt: "I need my routing number, my account number and my card number", expected: EmbeddingShortlist(tools: ["routing_number", "account_number", "card_number"])),
        // Spread across topic areas instead.
        ModelSample(prompt: "What fees did I pay, what interest did I earn, and what's my balance?", expected: EmbeddingShortlist(tools: ["fees_and_charges", "interest_earned", "account_balance"])),
        ModelSample(prompt: "Show my recent transactions, my Amazon purchases and my June statement", expected: EmbeddingShortlist(tools: ["list_transactions", "search_transactions", "bank_statement"])),

        // MARK: Four tools (7)
        //
        // One spare slot at k = 5. A single distractor scoring above any
        // of the four costs 0.25 on this sample, so this is where the
        // minimum reading earns its keep.

        ModelSample(prompt: "Show my balance, my recent transactions, my pending payments and my scheduled payments", expected: EmbeddingShortlist(tools: ["account_balance", "list_transactions", "pending_payments", "scheduled_payments"])),
        ModelSample(prompt: "I'm setting up direct deposit — give me my routing number, my account number, my balance and my last statement", expected: EmbeddingShortlist(tools: ["routing_number", "account_number", "account_balance", "bank_statement"])),
        ModelSample(prompt: "What's my credit score, my credit limit, my reward points and any open disputes?", expected: EmbeddingShortlist(tools: ["credit_score", "card_limits", "reward_points", "get_dispute_status"])),
        ModelSample(prompt: "What did I spend at Starbucks, what fees did I pay, what interest did I earn and what's my balance?", expected: EmbeddingShortlist(tools: ["search_transactions", "fees_and_charges", "interest_earned", "account_balance"])),
        // Chain (location → branch → hours) plus a fourth lookup.
        ModelSample(prompt: "Find the nearest branch, tell me its opening hours and show my balance", expected: EmbeddingShortlist(tools: ["get_location", "find_nearest_branch", "branch_hours", "account_balance"])),
        ModelSample(prompt: "Where's the closest ATM, what's my balance and what's my withdrawal limit?", expected: EmbeddingShortlist(tools: ["get_location", "find_nearest_atm", "account_balance", "card_limits"])),
        ModelSample(prompt: "Convert my savings balance to euros, then show my recent transactions and anything still pending", expected: EmbeddingShortlist(tools: ["account_balance", "convert_currency", "list_transactions", "pending_payments"]))
    ])

    // MARK: Metric

    /// Textbook recall, per query: |needed ∩ retrieved| / |needed|, a
    /// FRACTION — a query needing 3 tools that retrieves 2 scores 0.67.
    ///
    /// One metric, two readings (see `aggregateMetrics`):
    ///   • mean    — average recall across the dataset
    ///   • minimum — the worst query. Only minimum = 1.000 proves that no
    ///     query lost a tool; the mean can hide one total miss behind two
    ///     dozen perfect scores. For a shortlist feeding a downstream
    ///     stage, the worst query is what actually bounds the system.
    let recall = Metric("Recall@5")

    var evaluators: Evaluators {
        Evaluator { input, subject in
            guard let expected = input.expected, !expected.tools.isEmpty else {
                return recall.ignore()
            }
            let needed = Set(expected.tools)
            let found = needed.intersection(subject.value.tools)
            let shortlist = zip(subject.value.tools, subject.value.scores)
                .map { String(format: "%@ %.2f", $0.0, $0.1) }
                .joined(separator: ", ")
            let missing = needed.subtracting(found).sorted()

            return recall.scoring(
                Double(found.count) / Double(needed.count),
                rationale: missing.isEmpty
                    ? "all \(needed.count) of \(expected.tools.joined(separator: ", ")) in [\(shortlist)]"
                    : "\(found.count)/\(needed.count) — missing \(missing.joined(separator: ", ")) from [\(shortlist)]"
            )
        }
    }

    func aggregateMetrics(using aggregator: inout MetricsAggregator) {
        aggregator.computeMean(of: recall)
        aggregator.computeMinimum(of: recall)
    }
}

// MARK: - Suite

@Suite("Embedding Router Evaluations")
struct EmbeddingRouterTests {
    static let evaluation = EmbeddingRetrievalEvaluation()

    @Test(
        "MiniLM Retrieval — Recall@5",
        .evaluates(evaluation, info: [
            "ModelName": "all-MiniLM-L6-v2 (MLX)",
            "Strategy": "MiniLM Retrieval (top-5 shortlist)",
            "AppVersion": "1.0",
            "Feature": "Tool selection (routing) for the banking assistant"
        ])
    )
    func evaluateRetrieval() async throws {
        let result = EvaluationContext.current.result

        // Both floors are provisional and deliberately loose: the old
        // 1.000 was measured on a dataset that was 68% single-tool, and
        // this one is 25%. Tighten them once there is a real number.
        #expect(result.aggregateValue(.mean(of: Self.evaluation.recall)) >= 0.75)

        // The worst query, which on this dataset is almost certainly a
        // four-tool one: 0.5 means it lost two of its four. Anything
        // above 0.5 here means every sample kept at least half its
        // answer — a low bar, and the first run should replace it.
        #expect(result.aggregateValue(.minimum(of: Self.evaluation.recall)) >= 0.5)
    }
}
