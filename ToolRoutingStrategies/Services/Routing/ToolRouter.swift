import Foundation

// MARK: - Router abstraction
//
// Every routing strategy (LLM, embedding, hybrid) implements this
// protocol, so the view model can swap strategies without changing
// anything else.

@MainActor
protocol ToolRouter {
    var strategyName: String { get }
    var unavailabilityMessage: String? { get }
    func prewarm()
    func route(_ query: String) async throws -> RoutingResult
}

extension ToolRouter {
    // Embedding routers are always available and need no warm-up.
    var unavailabilityMessage: String? { nil }
    func prewarm() {}
}
