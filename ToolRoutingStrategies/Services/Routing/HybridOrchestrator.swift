import Foundation

// MARK: - Hybrid orchestrator (the article's two-stage cascade)
//
// Owns the pipeline; the stages stay single-purpose:
//
//   Stage 1  MiniLMRouter.retrieve — embedding similarity narrows the
//            full catalog to a top-k shortlist in milliseconds.
//   Stage 2  LLMRouter.select — the LLM, seeing ONLY those k tools,
//            selects, orders, and parameterizes the calls (or escalates).
//   Policy   Enforced here in code, never trusted to the model:
//            backend collapse, candidate-set validation, dedupe.
//   Stage 3  (not built yet) hand the ordered calls to the agent /
//            BankAPIClient for execution. Routing stops at selection
//            for now.
//
// Why cascade at all? Each stage covers the other's blind spot:
//   • The embedding-only eval measured routing accuracy 0.500 — every
//     failure was escalation, chaining, or multi-intent, all generation
//     problems.
//   • LLM accuracy degrades as distractor tools pile into the prompt.
// Stage 1's recall is the hard ceiling (measured Recall@4 = 1.000): a
// tool missing from the shortlist is unrecoverable downstream.

@MainActor
final class HybridOrchestrator: ToolRouter {
    let strategyName = "Hybrid Router (MiniLM → LLM)"

    struct Config {
        /// Shortlist size handed to the LLM. The article's sweet spot is
        /// k = 3–7; k = 4 is validated by Recall@4 = 1.000 on the
        /// retrieval eval (no routing plan needs more than 3 distinct
        /// tools). Raise only with recall evidence.
        var topK: Int = 4
    }

    /// Stage 1. The full router type is reused, but only its `retrieve`
    /// (shortlist) API — its argmax `route()` is the embedding-only sample.
    private let retriever = MiniLMRouter()
    /// Stage 2.
    private let selector = LLMRouter()
    private let config = Config()

    var unavailabilityMessage: String? { selector.unavailabilityMessage }

    func prewarm() {
        retriever.prewarm() // MiniLM weights + tool index
        selector.prewarm()  // base LLM weights
    }

    // MARK: Routing

    func route(_ query: String) async throws -> RoutingResult {
        // Stage 1 — retrieval. Milliseconds, no generation.
        let shortlist = try await retriever.retrieve(query, topK: config.topK)

        // Abstention door #1 (cheap): nothing cleared the similarity
        // threshold, so the LLM never runs. Empty calls = abstain; the
        // caller's policy (ToolRoutingViewModel) escalates to the backend.
        guard !shortlist.isEmpty else {
            return RoutingResult(
                strategyName: strategyName,
                reasoning: "No tool cleared the similarity threshold; the LLM stage was skipped.",
                calls: []
            )
        }

        // Stage 2 — LLM selection over ONLY the shortlist.
        let plan = try await selector.select(query, from: shortlist)

        // POLICY: if ANY sub-task needs the backend, the ENTIRE request
        // goes there so the server-side assistant sees full context.
        if plan.calls.contains(where: \.isSendToBackend) {
            return RoutingResult(
                strategyName: strategyName,
                reasoning: plan.reasoning,
                calls: [RoutedCall(tool: .sendToBackend(request: query), confidence: nil)]
            )
        }

        // Registry validation against the CANDIDATE SET (the article's
        // "validate before execution"): @Generable constrains calls to
        // real tools, but the schema spans the whole catalog while the
        // Stage-2 session only ever saw k descriptions. A pick outside
        // the shortlist is a selection the model couldn't have grounded,
        // so escalate the request rather than execute a guess.
        let candidates = Set(shortlist.map(\.toolName))
        guard plan.calls.allSatisfy({ candidates.contains($0.displayName) }) else {
            return RoutingResult(
                strategyName: strategyName,
                reasoning: "The model selected a tool outside the retrieved candidates; escalating instead of executing an ungrounded pick.",
                calls: [RoutedCall(tool: .sendToBackend(request: query), confidence: nil)]
            )
        }

        // Safety net: small on-device models sometimes repeat a call verbatim.
        var seen = Set<String>()
        let uniqueCalls = plan.calls.filter { seen.insert(String(describing: $0)).inserted }

        // Each call carries its Stage-1 similarity as the confidence —
        // the hybrid's two stages visible in one result.
        let scoreByTool = Dictionary(shortlist.map { ($0.toolName, Double($0.score)) }, uniquingKeysWith: max)

        // Stage 3 (future): execute `uniqueCalls` in order via the agent
        // and compose the final answer. For now the routed plan IS the
        // result.
        return RoutingResult(
            strategyName: strategyName,
            reasoning: plan.reasoning,
            calls: uniqueCalls.map {
                RoutedCall(tool: $0, confidence: scoreByTool[$0.displayName])
            }
        )
    }
}
