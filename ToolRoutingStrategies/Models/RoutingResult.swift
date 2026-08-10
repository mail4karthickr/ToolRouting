import Foundation

// MARK: - Routing result types
//
// Strategy-neutral types shared by the routing strategies:
//   1. MiniLMRouter (MLX)   — embedding-only routing
//   2. HybridRouter   — MiniLM retrieval (Stage 1) → LLMRouter
//                             selection (Stage 2) → agent execution
//                             (Stage 3, not built yet)
//
// The tool's parameters travel as associated values on ToolName.
// `reasoning` is optional because pure embedding routers classify but
// cannot generate. `confidence` is optional because the LLM router
// doesn't produce a similarity score.

struct RoutedCall: Identifiable {
    let id = UUID()
    let tool: ToolName
    let confidence: Double?

    var argument: String? { tool.argumentSummary }
}

struct RoutingResult {
    let strategyName: String
    let reasoning: String?
    let calls: [RoutedCall]

    /// Stage 3's composed reply, once the agent has run the plan. Nil
    /// when routing stopped at selection — a strategy that only routes,
    /// an escalation to the cloud, or an agent failure that degraded to
    /// showing the plan alone.
    var answer: String?

    /// Tools the agent actually invoked, in order. Usually identical to
    /// `calls`; where it differs, the agent skipped or added a step, and
    /// the UI shows the plan while this records what really ran.
    var executedTools: [String] = []

    /// Per-stage account of how this result was produced. Empty when the
    /// pipeline never ran (an availability fallback); partially filled
    /// when it short-circuited.
    var trace = RoutingTrace()

    init(
        strategyName: String,
        reasoning: String?,
        calls: [RoutedCall],
        answer: String? = nil,
        executedTools: [String] = [],
        trace: RoutingTrace = RoutingTrace()
    ) {
        self.strategyName = strategyName
        self.reasoning = reasoning
        self.calls = calls
        self.answer = answer
        self.executedTools = executedTools
        self.trace = trace
    }
}
