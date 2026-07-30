import Foundation

// MARK: - Routing result types
//
// Strategy-neutral types shared by all four routing samples:
//   1. LLMRouter          — LLM-based routing
//   2. MiniLMRouter (MLX) — embedding routing
//   3. NLEmbeddingRouter  — embedding routing
//   4. HybridRouter       — MiniLM retrieval → LLM ranking
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
