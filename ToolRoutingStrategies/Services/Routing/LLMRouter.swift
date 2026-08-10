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

    // Property order matters: guided generation emits fields in declaration
    // order, so each field is decided with the previous ones already in
    // context. `reasoning` first as a chain-of-thought step, then the
    // escalation decision, then the calls — the model commits to CAN this
    // be served locally before it starts choosing tools.
    //
    // The escalation decision is its own field rather than a `none` entry
    // in `calls`. As a tool competing in a list it could be selected twice
    // (the eval saw exactly that: "none → none") or mixed with real tools,
    // and every such malformation had to be repaired downstream. As a
    // field it is unforgeable, and "is this servable at all?" stops being
    // a ranking question.
    //
    // It is an ENUM, not a Bool, and that distinction is load-bearing. A
    // Bool version of this field returned true for all 28 eval samples:
    // `needsCloud` generates as a bare `true`/`false` token carrying no
    // meaning, and its only definition lived in a @Guide the model never
    // sees — `includeSchemaInPrompt: false` keeps the schema (and every
    // description in it) out of the prompt. Named cases generate as the
    // words `useTools` / `sendToCloud`, which mean something on their own.
    // Anything the model must reason about belongs in the instructions or
    // in a case name, never only in a @Guide.
    //
    // ToolName cases carry their parameters as associated values, so each
    // selected call arrives fully parameterized — no argument parsing.
    @Generable
    struct RoutingPlan {
        @Guide(description: "One sentence: which tools answer the request, or why none of them can.")
        var reasoning: String

        @Guide(description: "useTools when the listed tools answer the request; sendToCloud when they cannot.")
        var route: Route

        @Guide(description: "The tools to call, in the order they must run, with their parameters taken from the request. Empty when route is sendToCloud.", .maximumCount(4))
        var calls: [ToolName]
    }

    @Generable
    enum Route {
        /// The listed tools answer the request — the normal case.
        case useTools
        /// Nothing listed can answer it; the cloud model takes the request.
        case sendToCloud
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

    // MARK: Prewarm

    func prewarm() {
        guard unavailabilityMessage == nil else { return }
        // Sessions are per-request (their instructions depend on the
        // query's shortlist), so instruction prefill can't be prewarmed.
        // Prewarming a blank session still pages the base model in — the
        // dominant cold-start cost.
        LanguageModelSession().prewarm()
    }

    // MARK: Routing (Sample 1 — LLM-only, whole catalog)

    /// The standalone strategy: no retrieval, every tool in the prompt.
    /// Policy is enforced here in code rather than trusted to the model,
    /// mirroring `HybridRouter` — minus the candidate-set check,
    /// which is vacuous when the candidate set IS the catalog.
    func route(_ query: String) async throws -> RoutingResult {
        let plan = try await select(query, from: ToolCatalog.all)

        // The model's own escalation decision, plus a belt-and-braces
        // check on the calls: `route` is the field it is supposed to use,
        // but ToolName.none still exists for display, so a plan that
        // smuggles it into `calls` is treated as escalation too. An empty
        // plan means the same thing — nothing to run locally.
        if plan.route == .sendToCloud || plan.calls.isEmpty || plan.calls.contains(where: \.isNone) {
            return RoutingResult(
                strategyName: strategyName,
                reasoning: plan.reasoning,
                calls: [RoutedCall(tool: ToolName.none, confidence: nil)]
            )
        }

        // Safety net: small on-device models sometimes repeat a call verbatim.
        var seen = Set<String>()
        let uniqueCalls = plan.calls.filter { seen.insert(String(describing: $0)).inserted }

        return RoutingResult(
            strategyName: strategyName,
            reasoning: plan.reasoning,
            // No similarity score exists on this path — the LLM is the
            // only stage, and it doesn't produce one.
            calls: uniqueCalls.map { RoutedCall(tool: $0, confidence: nil) }
        )
    }

    // MARK: Selection

    /// Filters and orders `candidates` into the call plan for `query` —
    /// or returns a plan of `.none` when none of them fits.
    ///
    /// A fresh session per request is what makes the routing dynamic:
    /// the candidate set is baked into the instructions, so a shortlist
    /// that changes per query cannot share a session. Nothing is cached
    /// across requests even on the whole-catalog path, which means the
    /// LLM-only baseline pays its full instruction prefill every time —
    /// that cost is part of what the hybrid exists to avoid, so hiding it
    /// behind a cache would flatter the wrong strategy.
    func select(_ query: String, from candidates: [ToolDefinition]) async throws -> RoutingPlan {
        let session = LanguageModelSession(instructions: makeInstructions(candidates: candidates))
        let response = try await session.respond(
            to: query,
            generating: RoutingPlan.self,
            // The prompt carries a one-line prose version of the output
            // shape instead. The real schema spans the WHOLE ToolName
            // enum (~7.2k characters of $defs, every tool in the
            // catalog), so injecting it would both dwarf the k tool
            // descriptions and contradict "select only from these
            // candidates". Guided decoding still enforces the shape.
            includeSchemaInPrompt: false,
            options: GenerationOptions(sampling: .greedy) // routing is classification; greedy makes it reproducible
        )
        return response.content
    }

    // MARK: Instructions (built per request, from the candidates only)

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
    private func makeInstructions(candidates: [ToolDefinition]) -> String {
        let isShortlist = candidates.count < ToolCatalog.all.count

        let toolLines = candidates.enumerated()
            .map { index, tool in Self.entry(index + 1, for: tool) }
            .joined()

        let preamble = isShortlist
            ? "The list came from a similarity search, so it may hold nothing suitable."
            : "Every tool the app has is listed."

        return """
            You rank tools for a banking assistant. The user's request comes \
            next; the available tools are listed below. \(preamble)

            First set `route`, one of exactly two values:

            • useTools — one or more of the tools below answer the request. \
            THIS IS THE NORMAL CASE: nearly every request that asks to see, \
            show, check, find or convert something is useTools. A question \
            about a named merchant, dispute, branch, card or account is a \
            lookup however casually it is worded — "how much did i spend at \
            uber", "whats happening with my amazon dispute" and "what time \
            does the Main St branch close" are all useTools.
            • sendToCloud — the request asks to DO something (freeze, block, \
            transfer, send, pay, cancel, increase, raise, lower, open, close, \
            change, apply), or wants something the tools don't cover. These \
            tools only READ data, so the verb decides, not the noun: choose \
            sendToCloud even when a listed tool shows the same thing \
            ("increase my withdrawal limit" is sendToCloud, NOT card_limits), \
            and choose it for the WHOLE request when ANY part of it qualifies, \
            even if another part is a lookup you could answer ("show my balance \
            and transfer $200 to savings" is sendToCloud, NOT account_balance). \
            Choose it too when you cannot tell what is being asked, or the \
            request could mean several different things and picking wrong would \
            show the customer the wrong account or amount — better answered off \
            device than guessed at. Terse is not ambiguous, though: "bal?" and \
            "pts balance" are perfectly clear.

            With sendToCloud, leave `calls` empty. With useTools, select the \
            FEWEST tools that fully answer the request — one for a plain \
            lookup, more when the request asks for several things, or when \
            one tool needs another's result to run. Use the same tool twice \
            only with different parameters. A "Not for:" note may name a tool \
            that isn't listed; that rules the listed tool out, it never lets \
            you select the named one.

            Answer EVERY part of the request. When one tool needs another's \
            result, select both, the source first, and name it in the second's \
            parameter: "find the nearest ATM" → get_location, then find_atm with \
            location "current location". Stopping after the first tool leaves \
            the request unanswered.

            Available tools:
            \(toolLines)

            Answer with `reasoning`, one sentence on your choice; then \
            `route`, either useTools or sendToCloud; then `calls`, the tools by \
            name in the order they must run, with each parameter taken from the \
            request — empty when route is sendToCloud.
            """
    }

    /// One numbered tool entry. `Examples` are the same texts the
    /// embedding index is built from, so both stages describe a tool by
    /// the same set of matching requests.
    ///
    /// Capped at two examples per tool. The full set overflowed the
    /// context window on a three-call request (the eval recorded
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
