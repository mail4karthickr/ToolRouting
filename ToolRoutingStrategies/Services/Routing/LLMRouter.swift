import Foundation
import FoundationModels

// MARK: - LLM selection over a candidate set
//
// One selector, two roles, distinguished only by how many tools it is
// handed:
//
//   route(_:)          Sample 1 — LLM-ONLY routing. The whole catalog
//                      goes in the prompt. This is the baseline that
//                      justifies retrieval: it measures what the LLM
//                      can do when nothing has narrowed the field.
//   select(_:from:)    Hybrid Stage 2. Only the k tools Stage 1
//                      surfaced, so the LLM spends its attention
//                      filtering and ordering rather than scanning.
//
// Either way the job is the same: given the user's question and a set of
// candidates, decide which ones the request actually needs and emit them
// in execution order — or answer `none`.
//
// In the hybrid the filter matters because retrieval always returns
// something: similarity search has no "no match" concept, so its
// shortlist is full of plausible-but-wrong tools for any request the
// catalog can't serve. Stage 2 is what can say no. It also does what
// similarity search can't at all: verb reasoning (lookup vs. action),
// multi-intent decomposition, dependency ordering, and parameter
// extraction.
//
// `none` is the escalation signal: no on-device tool serves the
// request, so the caller sends it to the CLOUD model instead. That's
// the hybrid in one word — on-device wherever the local tools reach,
// cloud for everything else.
//
// Keeping the candidate set small is the load-bearing design decision
// of the HYBRID (and the thing route() deliberately does not do):
// LLM routing accuracy degrades as distractor tools pile into the
// instructions (attention dilution; ~20-tool practical ceiling), and on
// a ~3B model every schema costs context-window budget. With O(k)
// instructions per request, prompt size stays flat as the catalog grows.
//
// That O(k) property is easy to lose by accident — anything derived from
// the ToolName enum (a serialized generationSchema, a case list) is
// O(catalog) and reintroduces exactly the distractors Stage 1 removed.
// Everything the prompt says about tools is built from `candidates`.

@MainActor
final class LLMRouter: ToolRouter {
    let strategyName = "On-Device LLM Router"

    private let model = SystemLanguageModel.default

    // MARK: Generable output

    // SELECTION ONLY. This stage answers one question — which of the k
    // retrieved tools does this query need, if any — and its output is a
    // list of names. It does not extract parameters, and it does not
    // order anything.
    //
    // That is the source article's design, not a simplification of it.
    // Its ranking stage is "use the LLM to select from the k candidates,
    // or determine that none are appropriate", and its reference code
    // returns `Optional[Tool]` under the prompt line "Select the most
    // appropriate tool by name, or respond 'none' if no tool is
    // suitable." Parameters appear in that prompt as part of a tool's
    // DESCRIPTION — what it takes, so the model can judge fit — never as
    // something the model emits. The design doc's §5.5 reads "selection +
    // argument extraction + invocation in one pass"; that is the doc
    // extrapolating to Apple's native Tool protocol, and where the two
    // disagree the article is the authority.
    //
    // WHAT THIS REPLACED, and why each part went:
    //
    //   reasoning: String     removed 2026-08-10. A whole sentence,
    //       generated before everything else. Took the stage from 2.26s
    //       to 1.62s — about 25ms per output token, the exchange rate
    //       everything here is priced at.
    //   useTools: Bool        removed 2026-08-11. A separate flag can
    //       disagree with the list, and did: "Nearest atm" produced
    //       `true` with `calls: []` and escalated to the cloud despite
    //       find_atm scoring 0.98. Two fields, one invariant, nothing
    //       enforcing it. `"none"` is now a member of the same list, so
    //       abstention is a choice rather than a claim about a choice.
    //   calls: [ToolName]     removed 2026-08-11. ToolName carries
    //       parameters as associated values, so every plan paid to
    //       generate arguments that were then thrown away — the AGENT
    //       re-derives all of them from each Tool's own @Generable
    //       schema, which is the only extraction that reaches an API.
    //       It was also the "bespoke return-the-tool-name-as-JSON
    //       protocol" the design doc itself warned against building.
    //
    // The remaining output is roughly ten tokens: a short list of short
    // strings. On a stage that is entirely generation-bound, that is
    // where its latency went.
    //
    // NOT ORDERED, either. Which tool runs first is Stage 3's business,
    // and always was — the agent can only know that find_atm needs
    // get_location's output once it holds it.
    /// What this stage produces: tool NAMES, nothing else.
    ///
    /// Not `@Generable`. The schema is built per request from the
    /// shortlist (see `schema(for:)`), which is the only way to make
    /// "Stage 2 may choose only from Stage 1's output" a fact about the
    /// grammar rather than a rule checked afterwards.
    struct RoutingPlan {
        /// The model's own one-sentence read of the query, generated
        /// BEFORE the tools and framed around the question it kept
        /// getting wrong: is this an action or a lookup?
        let reasoning: String

        /// Selected tool names, or exactly `["none"]`. Never empty — the
        /// schema's `minimumElements` sees to that.
        let toolNames: [String]

        var isAbstention: Bool {
            toolNames.allSatisfy { $0 == ToolName.none.displayName }
        }
    }

    // MARK: Availability

    var unavailabilityMessage: String? {
        switch model.availability {
        case .available:
            return nil
        case .unavailable(.deviceNotEligible):
            return "This device doesn't support Apple Intelligence. Requests will be handled by the cloud model."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Apple Intelligence is turned off. Requests will be handled by the cloud model."
        case .unavailable(.modelNotReady):
            return "The on-device model is still downloading. Requests will be handled by the cloud model."
        case .unavailable:
            return "The on-device model is unavailable. Requests will be handled by the cloud model."
        }
    }

    // MARK: Session
    //
    // ONE session, built when the chat screen appears and reused for
    // every selection after that.
    //
    // That is only possible because the candidate tools moved OUT of the
    // instructions and into the prompt. Instructions are fixed at `init`
    // and the shortlist changes per query, so as long as the tool list
    // lived there, every request needed its own session and paid a cold
    // prefill for rules that never change. Split the two — rules in the
    // instructions, candidates in the prompt — and the unchanging half
    // gets prefilled once, at prewarm.
    //
    // The candidates still cost their tokens on every request. Nothing
    // makes a per-query prompt free; what this removes is re-paying for
    // the ~2k characters of routing policy alongside them.

    private var session: LanguageModelSession?

    /// The session exactly as built: instructions, nothing else. Each
    /// selection is restored to this.
    private var baseline = Transcript()

    /// How many sessions this router has built. The reuse tripwire: 1
    /// after prewarm, and 1 forever after.
    private(set) var sessionsBuilt = 0

    /// What the last `select` cost, in tokens.
    ///
    /// Separates the two halves of this stage's latency, which respond to
    /// completely different fixes: INPUT is the prompt — the k tool
    /// descriptions, which shrink by cutting examples or lowering k —
    /// and OUTPUT is generation, which is dominated by `reasoning` being
    /// the first and longest field of the plan. Without the split, "Stage
    /// 2 takes 2.2s" is not an actionable number.
    ///
    /// A property rather than a return value because `select` has three
    /// other callers, all evals, that want the plan and nothing else.
    /// Safe to read immediately after the `await` returns: this router is
    /// main-actor isolated and serves one request at a time, so nothing
    /// can overwrite it in between.
    private(set) var lastUsage: TokenUsage?

    struct TokenUsage {
        let input: Int
        let output: Int
    }

    @discardableResult
    private func warmSession() -> LanguageModelSession {
        if let session { return session }
        let session = LanguageModelSession(instructions: Self.policy)
        baseline = session.transcript
        self.session = session
        sessionsBuilt += 1
        return session
    }

    // MARK: Prewarm

    func prewarm() {
        guard unavailabilityMessage == nil else { return }
        // Pages the base model in — the dominant cold-start cost — and
        // now also prefills the instructions the session keeps for good.
        warmSession().prewarm()
    }

    // MARK: Routing (Sample 1 — LLM-only, whole catalog)

    /// The standalone strategy: no retrieval, every tool in the prompt.
    /// Policy is enforced here in code rather than trusted to the model,
    /// mirroring `HybridRouter` — minus the candidate-set check,
    /// which is vacuous when the candidate set IS the catalog.
    func route(_ query: String) async throws -> RoutingResult {
        let plan: RoutingPlan
        do {
            plan = try await select(query, from: ToolCatalog.all)
        } catch where Self.isDecliningToRoute(error) {
            // Declining IS abstaining. Same outcome as `none`.
            return RoutingResult(
                strategyName: strategyName,
                reasoning: "The on-device model declined to route this request; treated as an escalation.",
                calls: [RoutedCall(tool: ToolName.none, confidence: nil)]
            )
        }

        // `none` anywhere in the selection escalates the whole request —
        // alone because that is the abstention, and mixed with real tools
        // because a selection saying "account_balance, and also nothing
        // fits" contradicts itself, and running half a contradiction is
        // worse than escalating all of it.
        guard !plan.toolNames.contains(ToolName.none.displayName) else {
            return RoutingResult(
                strategyName: strategyName,
                reasoning: Self.escalationNote(for: plan),
                calls: [RoutedCall(tool: ToolName.none, confidence: nil)]
            )
        }

        return RoutingResult(
            strategyName: strategyName,
            reasoning: plan.reasoning.isEmpty ? nil : plan.reasoning,
            // No similarity score exists on this path — the LLM is the
            // only stage, and it doesn't produce one.
            calls: Self.routedCalls(for: plan, query: query, scores: [:])
        )
    }

    /// Turns selected names into `RoutedCall`s.
    ///
    /// Arguments come from `ToolName.withDefaultArguments`, the same
    /// helper the embedding router uses, because THIS STAGE NO LONGER
    /// EXTRACTS THEM. They exist only so a routed call is renderable and
    /// carries a tool identity; the agent re-derives every real argument
    /// from the tool's own schema before anything is invoked.
    ///
    /// Deduplicated by name: with parameters gone there is no such thing
    /// as the same tool twice with different arguments, so a repeat is
    /// always a repeat.
    static func routedCalls(
        for plan: RoutingPlan,
        query: String,
        scores: [String: Double]
    ) -> [RoutedCall] {
        var seen = Set<String>()
        return plan.toolNames
            .filter { $0 != ToolName.none.displayName && seen.insert($0).inserted }
            .compactMap { name in
                ToolName.withDefaultArguments(named: name, query: query)
                    .map { RoutedCall(tool: $0, confidence: scores[name]) }
            }
    }

    // MARK: Escalation

    /// Whether the model declined to route the request at all, rather
    /// than routing it somewhere wrong.
    ///
    /// A guardrail trip or a refusal is a DECISION, and it means the same
    /// thing every other abstention here means: the on-device path is not
    /// going to serve this one. Treating it as an error instead put a raw
    /// failure in front of the user for a request the cloud could have
    /// answered, and — since the model tends to decline exactly the
    /// requests that ask it to move money — it fired on precisely the
    /// class this router is supposed to escalate.
    ///
    /// MEASURED, 2026-08-11: "Increase my ATM withdrawal limit" refused,
    /// the eval's `catch` was written against the deprecated
    /// `LanguageModelSession.GenerationError` while iOS 27 throws
    /// `LanguageModelError.refusal`, and a CORRECT abstention was scored
    /// as no result at all.
    /// `nonisolated` because it reads nothing but the error, and callers
    /// need it in a `catch` guard — which cannot `await`, so a
    /// main-actor-inherited version is unusable exactly where it is used.
    nonisolated static func isDecliningToRoute(_ error: any Error) -> Bool {
        guard let error = error as? LanguageModelError else { return false }
        switch error {
        case .guardrailViolation, .refusal:
            return true
        default:
            return false
        }
    }

    /// Why a selection ended up going to the cloud.
    ///
    /// Only two shapes remain, where there used to be four. The schema
    /// cannot emit an empty list, cannot emit an unknown name, and has no
    /// second field to contradict — so the only cases left are a clean
    /// abstention and `none` sitting alongside real tools.
    ///
    /// Lives here, with the plan it describes, and is shared with
    /// `HybridRouter`. It carries weight: with `reasoning` gone, this
    /// sentence is the only account anything gives of why a request left
    /// the device.
    static func escalationNote(for plan: RoutingPlan) -> String {
        if plan.isAbstention {
            return "The model selected `none`: nothing in the shortlist answers this request."
        }
        return "The model selected `none` alongside \(plan.toolNames.filter { $0 != ToolName.none.displayName }.joined(separator: ", ")), which contradicts itself; the whole request goes to the cloud rather than executing half of it."
    }

    // MARK: Selection

    /// Picks the tools `query` needs from `candidates`, or `none`.
    ///
    /// The candidate set is enforced by the GRAMMAR, not by a check
    /// afterwards. `schema(for:)` builds a fresh output schema per
    /// request whose only legal tool names are these candidates plus
    /// `none`, so a pick outside the shortlist is not rejected — it
    /// cannot be generated. That is what makes Stage 2 a filter over
    /// Stage 1's output rather than a second opinion about the whole
    /// catalog, and it is why Recall@5 bounds the pipeline honestly.
    func select(_ query: String, from candidates: [ToolDefinition]) async throws -> RoutingPlan {
        let session = warmSession()

        // Back to instructions-only before every selection. Routing is
        // classification, and a classifier that can see the last three
        // questions it was asked is a different classifier: the evals
        // would stop being reproducible, and a shortlist from two
        // requests ago would still be in context competing with this
        // one's. Reuse buys the warm prefill; it must not buy history.
        session.transcript = baseline

        let response = try await session.respond(
            to: Self.prompt(for: query, candidates: candidates),
            schema: try Self.schema(for: candidates),
            // The prompt already lists these tools, with descriptions the
            // schema does not carry. Injecting the schema too would say
            // the names a second time in a less readable form.
            includeSchemaInPrompt: false,
            options: GenerationOptions(sampling: .greedy) // routing is classification; greedy makes it reproducible
        )
        lastUsage = TokenUsage(
            input: response.usage.input.totalTokenCount,
            output: response.usage.output.totalTokenCount
        )

        return RoutingPlan(
            reasoning: (try? response.content.value(String.self, forProperty: Self.reasoningProperty)) ?? "",
            toolNames: try response.content.value([String].self, forProperty: Self.toolsProperty)
        )
    }

    // MARK: Output schema (built per request, from the candidates only)

    private static let toolsProperty = "tools"
    private static let reasoningProperty = "reasoning"

    /// An output grammar admitting exactly one shape: a list of 1–4
    /// strings, each of which is one of THESE candidate names or `none`.
    ///
    /// Three failure modes stop existing because the decoder cannot
    /// produce them, rather than being caught and repaired downstream:
    ///
    ///   a tool Stage 1 never retrieved   not in `anyOf`
    ///   an empty selection               `minimumElements: 1`
    ///   a flag disagreeing with a list   there is only the list, and
    ///                                    `none` is one of its choices
    ///
    /// Rebuilt every request because the shortlist changes every request.
    /// That is cheap — this is string manipulation, not generation — and
    /// it is the whole point: a schema fixed at compile time can only
    /// describe the whole catalog, which is how a "shortlist" stage ends
    /// up able to name tools it was never shown.
    private static func schema(for candidates: [ToolDefinition]) throws -> GenerationSchema {
        let choices = candidates.map(\.displayName) + [ToolName.none.displayName]

        let toolName = DynamicGenerationSchema(
            name: "ToolName",
            description: "One of the listed tools, or none.",
            anyOf: choices
        )
        let plan = DynamicGenerationSchema(
            name: "ToolSelection",
            properties: [
                // FIRST, so the tools are chosen with it already written.
                // Declaration order is generation order, and the whole
                // value of this field is that it exists before the answer
                // does — moved after `tools` it would be a rationalisation
                // of a decision already made, at the same token cost.
                //
                // DELIBERATELY GENERIC. An earlier draft asked
                // specifically whether the query was an action or a
                // lookup, aimed at two escalation failures. That narrows a
                // thinking step into a single test: it would push every
                // query through one lens, do nothing for the multi-intent
                // failures that cost more samples, and need rewriting
                // whenever the catalog or the policy moves. The action
                // rule is already stated, forcefully, in the instructions
                // — this field's job is to make the model think before it
                // answers, not to re-ask one question.
                DynamicGenerationSchema.Property(
                    name: reasoningProperty,
                    description: "One short sentence: what the query is asking for, and whether any listed tool provides it.",
                    schema: DynamicGenerationSchema(type: String.self)
                ),
                DynamicGenerationSchema.Property(
                    name: toolsProperty,
                    description: "The tools needed for the query, or a single entry of none.",
                    schema: DynamicGenerationSchema(
                        arrayOf: DynamicGenerationSchema(referenceTo: "ToolName"),
                        minimumElements: 1,
                        maximumElements: 4
                    )
                )
            ]
        )
        return try GenerationSchema(root: plan, dependencies: [toolName])
    }

    // MARK: Instructions (static) and prompt (per request, candidates only)

    /// Tool entries are generated from the catalog definitions so the
    /// prompt can never drift out of sync with the UI. One numbered
    /// entry per candidate, each with the four things a selection needs:
    /// what the tool does, what to pass it, what a matching request looks
    /// like, and what it is NOT for.
    ///
    /// UNVALIDATED, 2026-08-07: the count rule reads "the fewest tools
    /// that fully answer the request" where it used to read "one tool
    /// unless the request clearly asks for several things". The old
    /// wording counted THINGS ASKED, which quietly denies the implicit
    /// chain — "find the nearest ATM" is one thing asked and two tools —
    /// and the paragraph below had to spend its example undoing that.
    /// "Fewest" keeps the pressure against over-decomposition without
    /// tying the count to the number of intents.
    ///
    /// No measurement backs this yet. It should be A/B'd once the
    /// trajectory metric reports per call-count bucket: the risk is the
    /// 1-call bucket (the majority of requests) regressing to buy the
    /// 2-3-call buckets, which the current dataset skew would hide.
    ///
    /// SPLIT ACROSS TWO PLACES since the session became long-lived: the
    /// rules below never change and live in the instructions, prefilled
    /// once; the candidate tools change every query and travel in the
    /// prompt (`prompt(for:candidates:)`). Anything added here must be
    /// true of EVERY request, or it belongs in the prompt.
    ///
    /// CUT TOO FAR ONCE, 2026-08-11, AND PARTLY RESTORED THE SAME DAY.
    /// The compression below was done for context headroom and measured
    /// afterwards: a 10-sample hybrid run scored escalation 1/3, and two
    /// of the four failures were queries whose EXAMPLES had just been
    /// deleted from this text — "how much did i spend at uber" went to
    /// pending_payments, and "I want to dispute a charge from Amazon"
    /// ran the dispute tools and answered with figures.
    ///
    /// What went back: the "most queries are lookups" framing with its
    /// merchant/dispute/branch examples, the dispute lookup-vs-action
    /// contrast, and the "cannot tell what is being asked" clause. The
    /// lesson is worth more than the text: the examples were not padding
    /// around the rules, they WERE the rules for a 3B model, and prose
    /// that reads as redundant to someone who already knows the domain is
    /// how the model learns the boundary. Cut here only with an eval run
    /// on either side of the change.
    ///
    /// Cheap to keep, too — these tokens are prefilled once per launch
    /// (see the Session note above), so the cost is context window, not
    /// latency.
    ///
    /// The original compression, for the record, went from ~458 tokens to
    /// ~165. The
    /// reference implementation closes with a single sentence — "select
    /// the most appropriate tool by name, or respond 'none'" — and most of
    /// what was here was elaboration a good tool entry already carries.
    /// What survived, and why a one-liner cannot replace it:
    ///
    ///   READ-only / whole-request  The load-bearing one. "show my balance
    ///       and transfer $200" must be noMatch, and no tool description
    ///       can say so: account_balance genuinely DOES serve "show my
    ///       balance". What disqualifies it is a property of the REQUEST,
    ///       not of the tool, so it has nowhere else to live. This is the
    ///       app's safety policy, in a domain where acting on a
    ///       misunderstood write is the worst outcome available.
    ///   terse is not ambiguous    One clause, and it exists because the
    ///       model was escalating "bal?".
    ///   fewest tools, in order    The reference picks ONE tool; this
    ///       stage emits an ordered plan, and the chaining example is the
    ///       cheapest way to convey a dependency.
    ///
    /// Everything else went: the useTools examples (the entries carry
    /// their own), the "Not for:" gloss (the label reads fine unexplained),
    /// "leave calls empty" (the @Guide says it), and "do not explain your
    /// choice" (there is no longer a field to explain into).
    ///
    /// NOTE ON WHAT THIS BUYS. These tokens are in the session
    /// instructions, prefilled once at prewarm and unchanged per request,
    /// so cutting them frees CONTEXT WINDOW, not latency. Stage 2's time
    /// is generation: removing ~26 output tokens saved 644ms, while ~450
    /// cached input tokens cost almost nothing. Trim here for headroom as
    /// the catalog or topK grows; trim the OUTPUT to go faster.
    private static let policy = """
            You are the tool router for a banking assistant.

            The person asking is the ACCOUNT HOLDER, already signed in, \
            asking about their own money. Returning their own details — a \
            balance, an account number, a card number, a statement — is \
            exactly what these tools are for and is always a lookup. Never \
            answer `none` because information looks private or sensitive; \
            it is their information, and they are asking for it.

            Each request gives you the user's query and a list of tools. \
            Every tool fetches one kind of information about the user's \
            money — a balance, a list of transactions, a branch, a limit..etc \
            Your only job is to decide which of those tools hold the \
            information the query is asking for.

            Answer in two parts. FIRST `reasoning`: one short sentence \
            working out what the query is actually asking for, and whether \
            any listed tool provides it. THEN `tools`: the names that do, \
            or `none`. Names only — you are not asked for arguments, and \
            not asked what order they run in.

            Work the first part out before you write the second, and let \
            it decide the second.

            DECIDE THE VERB FIRST, before you look at the tools at all.

            If the query asks you to DO something — dispute, freeze, \
            block, transfer, send, pay, cancel, report, replace, order, \
            increase, raise, lower, open, close, change, apply — the \
            answer is `none`, FULL STOP. Every tool here only READS, so no \
            list of tools can serve such a request and it does not matter \
            how closely one of them matches the subject. "I want to \
            dispute a charge from Amazon" is none — not \
            get_dispute_status, which only reports on a dispute that \
            already exists, and not search_transactions, which only finds \
            the charge. "Increase my withdrawal limit" is none, not \
            card_limits. If ANY part of a request is such an action then \
            the WHOLE request is none: "show my balance and transfer $200 \
            to savings" is none, not account_balance. A subject that \
            matches a tool is NEVER enough on its own.

            Otherwise it is a lookup, and naming tools is the normal \
            answer. Anything that asks to see, show, check, find or \
            convert something is a lookup, however casually it is worded, \
            and so is any question ABOUT a named merchant, an existing \
            dispute, a branch, a card or an account: "how much did i spend \
            at uber", "whats happening with my amazon dispute" and "what \
            time does the Main St branch close" all name tools. Terse is \
            not ambiguous — "bal?" and "pts balance" are perfectly clear.

            Answer `none` too when you cannot tell what is being asked, or \
            the request could mean several things and picking wrong would \
            show the customer the wrong account or amount.

            Otherwise pick the fewest tools that fully answer the query, \
            and include a tool whose result another one needs: "find the \
            nearest ATM" needs get_location as well as find_nearest_atm, \
            because find_nearest_atm takes coordinates and get_location \
            is the only tool that produces them. "Fewest" counts the \
            prerequisite: a chain of two is fewer than a wrong list of \
            one.

            find_nearest_atm and find_nearest_branch ONLY take \
            coordinates, and get_location returns exactly one thing: \
            where the user is standing right now. NOTHING turns a place \
            the user NAMES into coordinates — not a city, not a zip, not \
            a neighbourhood, not "downtown" or "the airport". So a \
            request about ATMs or branches anywhere other than the user's \
            own location has no tool that serves it AND no chain that \
            reaches it. Adding intermediate steps does not help: the \
            chain has no way in. "ATMs in Chicago", "a branch downtown", \
            "cash machine near 94103" are all `none`.

            That rule is all-or-nothing, exactly like an action. "What \
            ATMs are near Chicago, what's my withdrawal limit, and my \
            checking balance?" is `none` — not account_balance and \
            card_limits — even though two of its three parts are \
            serviceable. Check EVERY part of a request for a named place \
            before you break it into intents; one unreachable part sends \
            the whole request to the cloud.

            branch_hours is the longest chain here: it takes a branch ID, \
            find_nearest_branch is the only tool that produces one, and \
            it needs coordinates in turn. So a question about the hours \
            of a branch NEAR THE USER is get_location, \
            find_nearest_branch, branch_hours — including "what time does \
            the Main St branch close?", where the user names the branch. \
            A NAME IS NOT AN ID. Naming the branch saves no step, because \
            nothing in that chain can be skipped by knowing what the \
            branch is called.

            But that chain still begins at the user's own location, so it \
            cannot reach a branch somewhere the user is not. The rule \
            above wins: "find a branch downtown and tell me its hours" is \
            `none`, hours or no hours. Naming a PLACE is not the same as \
            naming a BRANCH — a named branch near the user is reachable, \
            a named place is not.

            A "Not for:" note rules OUT the tool it is written under. It \
            never recommends the tool it mentions — "Not for: money \
            balances (use account_balance)" under reward_points means \
            reward_points is wrong for a money balance, not that \
            account_balance is right for a points balance.
            """

    /// The per-request half: which tools are on offer this time, and the
    /// question. The tool list leads and the request closes, so the last
    /// thing the model reads before generating is what it was asked —
    /// the same order the single combined prompt had.
    private static func prompt(for query: String, candidates: [ToolDefinition]) -> String {
        let isShortlist = candidates.count < ToolCatalog.all.count
        let preamble = isShortlist
            ? "The list came from a similarity search, so it may hold nothing suitable."
            : "Every tool the app has is listed."

        let toolLines = candidates.enumerated()
            .map { index, tool in Self.entry(index + 1, for: tool) }
            .joined()

        // Closes on the instruction rather than the question, as the
        // reference prompt does. The rules live in the session's
        // instructions and were prefilled long ago; this last line is the
        // one the model reads immediately before generating, and recency
        // is worth ~20 tokens on a small model.
        return """
            User query: "\(query)"

            Available tools. \(preamble)
            \(toolLines)

            Work out in one sentence what this query is asking for and \
            whether any listed tool provides it, then select those tools \
            by name — or none.
            """
    }

    /// One numbered tool entry, in the reference implementation's shape:
    /// name and description, then parameters, then examples.
    ///
    ///     1. account_balance: Current balance for an account.
    ///        Parameters: which account — checking, savings, credit card
    ///        Examples: "bal?", "how much is in savings"
    ///        Not for: transfers or payments
    ///
    /// THE ENTRIES ARE NOT WHERE THE PROMPT IS TRIMMED. They were cut to
    /// two lines earlier the same day and put back: describing a
    /// candidate is the one thing this prompt is for, and a selection
    /// stage that cannot see what a tool takes or what asking for it
    /// looks like is being asked to choose blind. The budget came out of
    /// the static policy instead, which is prose about how to behave and
    /// compresses without losing a rule.
    ///
    /// `Not for:` is the one addition to the reference shape. It is the
    /// only disambiguation the prompt carries — what separates
    /// card_limits from "raise my limit", or account_number from "routing
    /// no" — and this catalog has near neighbours the reference's toy set
    /// does not.
    ///
    /// Examples stay capped at two. The full set overflowed the context
    /// window on a three-call request (the eval recorded
    /// `exceededContextWindowSize`, which in production means a request
    /// that silently stops being served on device). Two is enough to show
    /// the phrasing; the description carries the meaning.
    private static func entry(_ number: Int, for tool: ToolDefinition) -> String {
        let examples = ([tool.promptExample].compactMap { $0 } + tool.exampleQueries)
            .prefix(2)
            .map { "\"\($0)\"" }
            .joined(separator: ", ")

        return """

            \(number). \(tool.displayName): \(tool.description)
               Parameters: \(tool.argumentHint)
               Examples: \(examples)
               Not for: \(tool.notFor)
            """
    }
}
