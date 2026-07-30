import Foundation

// MARK: - Chat Message
//
// One entry in the conversation. Assistant answers carry the full
// routing result so the UI can render the selected tools (in order)
// and the router's reasoning.

struct ChatMessage: Identifiable {
    enum Content {
        case user(String)
        case routing(RoutingResult, latency: Duration?)
        case error(String)
    }

    let id = UUID()
    let content: Content
}
