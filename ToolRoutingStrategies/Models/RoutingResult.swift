import Foundation

// MARK: - Routing result types
//
// Strategy-neutral types shared by the routing strategies:
//   1. MiniLMRouter (MLX)   — embedding-only routing
//   2. HybridOrchestrator   — MiniLM retrieval (Stage 1) → LLMRouter
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
}
