import Foundation
import FoundationModels
import Observation

// MARK: - ViewModel
//
// Orchestrates the chat: appends the user's question, runs it through
// the active routing strategy, and appends the routing answer.

@MainActor
@Observable
final class ToolRoutingViewModel {
    var userPrompt = ""
    var messages: [ChatMessage] = []
    var isLoading = false

    // Swap this for the embedding/hybrid router samples —
    // nothing below this line changes.
    private let router: any ToolRouter = LLMRouter()

    var strategyName: String { router.strategyName }
    var unavailabilityMessage: String? { router.unavailabilityMessage }

    func prewarm() {
        router.prewarm()
    }

    // MARK: Routing

    func send() async {
        let trimmed = userPrompt.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !isLoading else { return }

        userPrompt = ""
        messages.append(ChatMessage(content: .user(trimmed)))

        // Production behavior: if the on-device router is unavailable,
        // the app should fall back to sending the whole request to the
        // backend rather than erroring. Modeled here as a single
        // send_to_backend call.
        if router.unavailabilityMessage != nil {
            messages.append(ChatMessage(content: .routing(
                Self.backendFallback(for: trimmed, reason: "On-device routing is unavailable; forwarding the request to the backend."),
                latency: nil
            )))
            return
        }

        isLoading = true
        defer { isLoading = false }

        let clock = ContinuousClock()
        let start = clock.now

        do {
            let result = try await router.route(trimmed)
            messages.append(ChatMessage(content: .routing(result, latency: clock.now - start)))
        } catch let error as LanguageModelSession.GenerationError {
            // Same production principle: a routing failure should degrade
            // to backend escalation, not a dead end for the user.
            messages.append(ChatMessage(content: .error(Self.friendlyMessage(for: error))))
            messages.append(ChatMessage(content: .routing(
                Self.backendFallback(for: trimmed, reason: "On-device routing failed; forwarding the request to the backend."),
                latency: nil
            )))
        } catch {
            messages.append(ChatMessage(content: .error(error.localizedDescription)))
        }
    }

    private static func backendFallback(for query: String, reason: String) -> RoutingResult {
        RoutingResult(
            strategyName: "Backend Fallback",
            reasoning: reason,
            calls: [RoutedCall(tool: .sendToBackend(request: query), confidence: nil)]
        )
    }

    private static func friendlyMessage(for error: LanguageModelSession.GenerationError) -> String {
        switch error {
        case .guardrailViolation:
            return "The on-device model declined to route this request."
        case .exceededContextWindowSize:
            return "The request is too long for the on-device model."
        case .unsupportedLanguageOrLocale:
            return "The on-device model doesn't support that language yet."
        default:
            return error.localizedDescription
        }
    }
}
