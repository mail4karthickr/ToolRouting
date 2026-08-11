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
// Stage 1's recall is the SOFT ceiling. A tool missing from the
// shortlist used to be unrecoverable, but that was this file's policy
// rather than a property of the cascade: `calls` is [ToolName] and
// guided decoding spans the whole catalog, so Stage 2 can name a tool it
// was never shown, and on multi-intent queries it does — correctly. Such
// picks are now kept and recorded rather than rejected; see the
// candidate-set section below.
//
// Recall@5 in EmbeddingRouterTests still matters, and the MINIMUM there
// still matters more than the mean — a miss now costs a tool chosen
// without its description in front of the model, which is worse than one
// chosen with it, just far better than the request leaving the device.

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

    /// Called when the chat screen appears. Every stage builds whatever
    /// it keeps for the app's lifetime here — the two LLM stages each
    /// build their ONE session now, so no request ever pays for
    /// constructing one.
    func prewarm() {
        retriever.prewarm() // MiniLM weights + tool index
        selector.prewarm()  // base LLM weights + the selection session
        agent.prewarm()     // the agent session, with every tool bound
    }

    // MARK: Routing

    /// The `ToolRouter` entry point: run the cascade, report nothing.
    /// This is what the evals call, and it is the streaming path with the
    /// updates discarded rather than a second implementation — a
    /// measured path that isn't the shipped path measures nothing.
    func route(_ query: String) async throws -> RoutingResult {
        try await route(query, onUpdate: { _ in })
    }

    /// The same run, reporting where it is as it goes.
    ///
    /// `onUpdate` is non-escaping and called on this actor, so the UI can
    /// assign to its own state inside the handler with no hop and no
    /// window where the model has moved on but the screen hasn't.
    func route(_ query: String, onUpdate: (RoutingUpdate) -> Void) async throws -> RoutingResult {
        // Every stage is timed and recorded into `trace` as it completes,
        // so an early return carries the account of everything that ran
        // before it. The UI reads this to show what happened; nothing in
        // the routing decisions below depends on it.
        var trace = RoutingTrace()
        let clock = ContinuousClock()

        // Stage 1 — retrieval. Milliseconds, no generation.
        onUpdate(.retrieving)
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
        onUpdate(.selecting)
        let selectionStart = clock.now
        let plan = try await selector.select(query, from: candidateTools)
        let selectionDuration = clock.now - selectionStart
        // Read here, with no suspension between this and the call above,
        // so it cannot belong to a different request.
        let selectionUsage = selector.lastUsage

        // Records Stage 2 with whatever policy fired on it. Policy notes
        // are the bridge between the model's output and the result: a
        // plan that looked fine and still went to the cloud has its
        // reason here and nowhere else.
        func recordSelection(_ notes: [String]) {
            trace.selection = RoutingTrace.SelectionStage(
                candidates: candidateTools.map(\.displayName),
                reasoning: nil, // the model no longer writes one; see RoutingPlan
                route: plan.toolNames.contains(ToolName.none.displayName) ? .noMatch : .useTools,
                plannedCalls: plan.toolNames.map {
                    // No arguments: Stage 2 selects names and nothing
                    // else. What each tool is called with is decided in
                    // Stage 3, from the tool's own schema, and shows up
                    // in the execution card rather than here.
                    RoutingTrace.SelectionStage.PlannedCall(toolName: $0, arguments: nil)
                },
                policyNotes: notes,
                promptTokens: selectionUsage?.input,
                outputTokens: selectionUsage?.output,
                duration: selectionDuration
            )
        }

        // POLICY: if ANY sub-task falls outside the local tools, the
        // ENTIRE request goes to the cloud, which answers it with the full
        // original context rather than half a plan running locally.
        //
        // `none` is how the model says so, and it is honoured whether it
        // arrives alone or mixed in with real tools — a selection reading
        // "account_balance, and also nothing fits" contradicts itself,
        // and half a contradiction is not a safe thing to run.
        //
        // NO CANDIDATE-SET CHECK ANY MORE, and its absence is the point.
        // It used to sit here rejecting picks outside the shortlist,
        // because `calls` was [ToolName] — a schema spanning the whole
        // catalog — while the prompt showed only k tools, so the model
        // could name something it had never been shown. Stage 2's output
        // schema is now built from the shortlist itself
        // (LLMRouter.schema(for:)), so that pick is not rejected, it is
        // ungeneratable. The grammar and the prompt finally agree, and
        // Recall@5 bounds this pipeline for real rather than by policy.
        guard !plan.toolNames.contains(ToolName.none.displayName) else {
            recordSelection([LLMRouter.escalationNote(for: plan)])
            return RoutingResult(
                strategyName: strategyName,
                reasoning: LLMRouter.escalationNote(for: plan),
                calls: [RoutedCall(tool: ToolName.none, confidence: nil)],
                trace: trace
            )
        }

        // Each call carries its Stage-1 similarity as the confidence —
        // the hybrid's two stages visible in one result.
        let scoreByTool = Dictionary(shortlist.map { ($0.toolName, Double($0.score)) }, uniquingKeysWith: max)
        let routedCalls = LLMRouter.routedCalls(for: plan, query: query, scores: scoreByTool)

        let duplicates = plan.toolNames.count - routedCalls.count
        recordSelection(duplicates > 0
            ? ["Dropped \(duplicates) tool\(duplicates == 1 ? "" : "s") the model named twice."]
            : [])

        // Stage 3 — bind exactly these tools to an agent session and let
        // it answer. A failure here degrades to the routed plan without
        // an answer rather than losing the turn: routing did its job, and
        // showing which tools were chosen still beats an error.
        let uniqueCalls = routedCalls.map(\.tool)
        let boundTools = uniqueCalls.map(\.displayName).filter { $0 != ToolName.none.displayName }
        onUpdate(.answering)
        let executionStart = clock.now
        do {
            let answer = try await agent.answer(query, using: uniqueCalls, onUpdate: onUpdate)
            trace.execution = RoutingTrace.ExecutionStage(
                boundTools: boundTools,
                invocations: answer.invocations,
                answer: answer.text,
                retriedForUnverifiedFigures: answer.retriedForUnverifiedFigures,
                rejectedFigures: answer.rejectedFigures,
                rejectedDraft: answer.rejectedDraft,
                failure: nil,
                timeToFirstToken: answer.timeToFirstToken,
                promptTokens: answer.promptTokens,
                duration: clock.now - executionStart
            )
            return RoutingResult(
                strategyName: strategyName,
                reasoning: nil,
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
                rejectedFigures: [],
                rejectedDraft: nil,
                failure: (error as? LocalizedError)?.errorDescription ?? "\(error)",
                timeToFirstToken: nil,
                promptTokens: nil,
                duration: clock.now - executionStart
            )
            return RoutingResult(
                strategyName: strategyName,
                reasoning: "Agent failed: \(error)",
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

}
