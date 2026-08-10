import Foundation

// MARK: - Hybrid router (the article's two-stage cascade, plus the agent)
//
// Owns the pipeline; the stages stay single-purpose:
//
//   Stage 1  MiniLMRouter.retrieve — embedding similarity narrows the
//            full catalog to a top-k shortlist in milliseconds.
//   Stage 2  LLMRouter.select — the LLM, seeing ONLY those k tools,
//            filters, orders, and parameterizes the calls — or answers
//            `none` when no candidate fits.
//   Policy   Enforced here in code, never trusted to the model:
//            `none` collapse, candidate-set validation, dedupe.
//   Stage 3  ToolExecutionAgent — binds ONLY the selected tools to a
//            session, which calls them against BankAPIClient and writes
//            the answer the user reads.
//
// `none` is what makes this hybrid in the deployment sense too: a plan
// of tools runs entirely on device, while `none` hands the request to
// the CLOUD model. On-device wherever the local tools reach; cloud only
// where they don't.
//
// Why cascade at all? Each stage covers the other's blind spot:
//   • The embedding-only eval measured routing accuracy 0.500 — every
//     failure was escalation, chaining, or multi-intent, all generation
//     problems.
//   • LLM accuracy degrades as distractor tools pile into the prompt.
// Stage 1's recall is the hard ceiling: a tool missing from the
// shortlist is unrecoverable downstream. It is measured on its own as
// Recall@5 in EmbeddingRouterTests — read the MINIMUM there, not the
// mean, since one query that lost a tool is one plan that cannot run.

@MainActor
final class HybridRouter: ToolRouter {
    let strategyName = "Hybrid Router (MiniLM → LLM)"

    struct Config {
        /// Shortlist size handed to the LLM. The article's sweet spot is
        /// k = 3–7.
        ///
        /// k = 5 buys one spare slot on the hardest requests: the
        /// retrieval eval's four-tool samples need four of the five back,
        /// so at k = 4 they would demand a perfect shortlist to be
        /// answerable at all. The cost is one more tool description in
        /// every Stage-2 prompt — a distractor on the majority of
        /// requests, which need one tool. If the hybrid's end-to-end
        /// number falls while Recall@5 holds, that trade is why.
        var topK: Int = 5
    }

    /// Stage 1. The full router type is reused, but only its `retrieve`
    /// (shortlist) API — its argmax `route()` is the embedding-only sample.
    private let retriever = MiniLMRouter()
    /// Stage 2.
    private let selector = LLMRouter()
    /// Stage 3 — runs the selected tools and composes the answer.
    private let agent = ToolExecutionAgent()
    private let config = Config()

    var unavailabilityMessage: String? { selector.unavailabilityMessage }

    func prewarm() {
        retriever.prewarm() // MiniLM weights + tool index
        selector.prewarm()  // base LLM weights
    }

    // MARK: Routing

    func route(_ query: String) async throws -> RoutingResult {
        // Every stage is timed and recorded into `trace` as it completes,
        // so an early return carries the account of everything that ran
        // before it. The UI reads this to show what happened; nothing in
        // the routing decisions below depends on it.
        var trace = RoutingTrace()
        let clock = ContinuousClock()

        // Stage 1 — retrieval. Milliseconds, no generation.
        let retrievalStart = clock.now
        let retrieval = try await retriever.rank(query, topK: config.topK)
        let shortlist = retrieval.shortlist
        trace.retrieval = stage(from: retrieval, duration: clock.now - retrievalStart)

        // Abstention door #1 (cheap): nothing cleared the similarity
        // threshold, so the LLM never runs. Empty calls = abstain; the
        // caller's policy (ToolRoutingViewModel) sends it to the cloud.
        guard !shortlist.isEmpty else {
            return RoutingResult(
                strategyName: strategyName,
                reasoning: "No tool cleared the similarity threshold; the LLM stage was skipped.",
                calls: [],
                trace: trace
            )
        }

        // Stage 2 — LLM selection over ONLY the shortlist. Retrieval
        // returns names; the selector wants the definitions whose text
        // goes in the prompt.
        let candidateTools = shortlist.compactMap { ToolCatalog.byName[$0.toolName] }
        let selectionStart = clock.now
        let plan = try await selector.select(query, from: candidateTools)
        let selectionDuration = clock.now - selectionStart

        // Records Stage 2 with whatever policy fired on it. Policy notes
        // are the bridge between the model's output and the result: a
        // plan that looked fine and still went to the cloud has its
        // reason here and nowhere else.
        func recordSelection(_ notes: [String]) {
            trace.selection = RoutingTrace.SelectionStage(
                candidates: candidateTools.map(\.displayName),
                reasoning: plan.reasoning,
                route: plan.route == .sendToCloud ? .sendToCloud : .useTools,
                plannedCalls: plan.calls.map {
                    RoutingTrace.SelectionStage.PlannedCall(
                        toolName: $0.displayName,
                        arguments: $0.argumentSummary
                    )
                },
                policyNotes: notes,
                duration: selectionDuration
            )
        }

        // POLICY: if ANY sub-task falls outside the local tools, the
        // ENTIRE request goes to the cloud, which answers it with the full
        // original context rather than half a plan running locally.
        // `route` is the model's own decision field; the other two
        // checks catch a plan that expressed the same thing malformed —
        // ToolName.none smuggled into calls, or no calls at all.
        if plan.route == .sendToCloud || plan.calls.isEmpty || plan.calls.contains(where: \.isNone) {
            recordSelection([Self.escalationNote(for: plan)])
            return RoutingResult(
                strategyName: strategyName,
                reasoning: plan.reasoning,
                calls: [RoutedCall(tool: ToolName.none, confidence: nil)],
                trace: trace
            )
        }

        // Registry validation against the CANDIDATE SET (the article's
        // "validate before execution"): @Generable constrains calls to
        // real tools, but the schema spans the whole catalog while the
        // Stage-2 session only ever saw k descriptions. A pick outside
        // the shortlist is a selection the model couldn't have grounded,
        // so treat it as `none` rather than execute a guess.
        let candidates = Set(shortlist.map(\.toolName))
        let ungrounded = plan.calls.map(\.displayName).filter { !candidates.contains($0) }
        guard ungrounded.isEmpty else {
            recordSelection([
                "Rejected: \(ungrounded.joined(separator: ", ")) — not in the retrieved candidate set, so the model couldn't have grounded the pick. Sent to the cloud instead of executing a guess."
            ])
            return RoutingResult(
                strategyName: strategyName,
                reasoning: "The model selected a tool outside the retrieved candidates; routing to the cloud instead of executing an ungrounded pick.",
                calls: [RoutedCall(tool: ToolName.none, confidence: nil)],
                trace: trace
            )
        }

        // Safety net: small on-device models sometimes repeat a call verbatim.
        var seen = Set<String>()
        let uniqueCalls = plan.calls.filter { seen.insert(String(describing: $0)).inserted }
        let duplicates = plan.calls.count - uniqueCalls.count
        recordSelection(duplicates > 0
            ? ["Dropped \(duplicates) duplicate call\(duplicates == 1 ? "" : "s") the model emitted verbatim."]
            : [])

        // Each call carries its Stage-1 similarity as the confidence —
        // the hybrid's two stages visible in one result.
        let scoreByTool = Dictionary(shortlist.map { ($0.toolName, Double($0.score)) }, uniquingKeysWith: max)
        let routedCalls = uniqueCalls.map {
            RoutedCall(tool: $0, confidence: scoreByTool[$0.displayName])
        }

        // Stage 3 — bind exactly these tools to an agent session and let
        // it answer. A failure here degrades to the routed plan without
        // an answer rather than losing the turn: routing did its job, and
        // showing which tools were chosen still beats an error.
        let boundTools = uniqueCalls.map(\.displayName).filter { $0 != ToolName.none.displayName }
        let executionStart = clock.now
        do {
            let answer = try await agent.answer(query, using: uniqueCalls)
            trace.execution = RoutingTrace.ExecutionStage(
                boundTools: boundTools,
                invocations: answer.invocations,
                answer: answer.text,
                retriedForUnverifiedFigures: answer.retriedForUnverifiedFigures,
                failure: nil,
                duration: clock.now - executionStart
            )
            return RoutingResult(
                strategyName: strategyName,
                reasoning: plan.reasoning,
                calls: routedCalls,
                answer: answer.text,
                executedTools: answer.executedTools,
                trace: trace
            )
        } catch {
            // Still degrade to the plan — routing did its job and showing
            // the chosen tools beats an error — but record WHY. Swallowing
            // this made an agent failure look identical to a router that
            // simply produced no answer, which cost a diagnostic run.
            trace.execution = RoutingTrace.ExecutionStage(
                boundTools: boundTools,
                invocations: [],
                answer: nil,
                retriedForUnverifiedFigures: false,
                failure: (error as? LocalizedError)?.errorDescription ?? "\(error)",
                duration: clock.now - executionStart
            )
            return RoutingResult(
                strategyName: strategyName,
                reasoning: "\(plan.reasoning) · Agent failed: \(error)",
                calls: routedCalls,
                trace: trace
            )
        }
    }

    // MARK: Trace

    private func stage(
        from retrieval: MiniLMRouter.Retrieval,
        duration: Duration
    ) -> RoutingTrace.RetrievalStage {
        let shortlisted = Set(retrieval.shortlist.map(\.toolName))
        return RoutingTrace.RetrievalStage(
            topK: config.topK,
            threshold: Double(retriever.similarityThreshold),
            ranked: retrieval.ranked.map {
                RoutingTrace.RetrievalStage.Candidate(
                    toolName: $0.toolName,
                    score: Double($0.score),
                    isShortlisted: shortlisted.contains($0.toolName)
                )
            },
            duration: duration
        )
    }

    /// Which of the three escalation conditions actually fired. They mean
    /// different things: the first is the model deciding, the other two
    /// are it producing a plan that contradicts its own `useTools`.
    private static func escalationNote(for plan: LLMRouter.RoutingPlan) -> String {
        if plan.route == .sendToCloud {
            return "The model chose sendToCloud: nothing in the shortlist serves this request."
        }
        if plan.calls.isEmpty {
            return "The model chose useTools but selected no tools; an empty plan has nothing to run, so it goes to the cloud."
        }
        return "The model chose useTools but smuggled `none` into the calls; treated as escalation."
    }
}
