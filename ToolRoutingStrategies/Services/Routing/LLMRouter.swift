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
        let plan = try await select(query, from: ToolCatalog.all)

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
            // The model no longer writes an explanation; a selection is
            // described by the tools in it.
            reasoning: nil,
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

        let names = try response.content.value([String].self, forProperty: Self.toolsProperty)
        return RoutingPlan(toolNames: names)
    }

    // MARK: Output schema (built per request, from the candidates only)

    private static let toolsProperty = "tools"

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
    /// CUT TO THE IRREDUCIBLE, 2026-08-11, from ~458 tokens to ~165. The
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

            Each request gives you the user's query and a list of tools. \
            Every tool fetches one kind of information about the user's \
            money — a balance, a list of transactions, a branch, a limit..etc \
            Your only job is to decide which of those tools hold the \
            information the query is asking for.

            Answer with the names of the tools that answer it, or with \
            `none` if no listed tool does. Names only — you are not asked \
            for arguments, and not asked what order they run in.

            These tools only READ. Any request to DO something — transfer, \
            send, pay, freeze, block, cancel, open, close, raise, increase, \
            change — is answered by `none` even when a listed tool shows \
            the same figure, and if ANY part of a request is such an \
            action then the answer for the WHOLE request is `none`. \
            Everything else is a lookup, however casually worded; terse is \
            not ambiguous.

            Otherwise pick the fewest tools that fully answer the query, \
            and include a tool whose result another one needs: "find the \
            nearest ATM" needs get_location as well as find_atm.

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

            Select the tools that hold the information this query asks \
            for by name, or none if no tool is suitable.
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
