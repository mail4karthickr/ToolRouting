import Foundation
import FoundationModels
import Observation

// MARK: - ViewModel
//
// Orchestrates the chat: appends the user's question, runs it through
// the hybrid pipeline, and appends the answer with its trace.
//
// Every request goes through HybridRouter. MiniLMRouter and LLMRouter
// still exist as its two stages, and the evals still run them alone to
// measure what each contributes, but they are not user-facing choices:
// the embedding stage can't parameterize a call and the LLM stage alone
// pays the whole catalog in its prompt, so neither is a strategy anyone
// would pick for an actual question.

@MainActor
@Observable
final class ToolRoutingViewModel {
    var userPrompt = ""
    var messages: [ChatMessage] = []
    var isLoading = false

    /// Long-lived, so its warmed session and built index survive across
    /// requests.
    private let router = HybridRouter()

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
        // the app should fall back to answering the request with the
        // cloud model rather than erroring. Modeled here as a single
        // `none` call.
        if router.unavailabilityMessage != nil {
            messages.append(ChatMessage(content: .routing(
                Self.cloudFallback(reason: "On-device routing is unavailable; answering with the cloud model."),
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
            // Abstain: the router found no tool it trusts. POLICY,
            // decided here and not in the router: same outcome as an
            // explicit `none` — the cloud model answers the request.
            if result.calls.isEmpty {
                messages.append(ChatMessage(content: .routing(
                    Self.cloudFallback(reason: "No on-device tool matched confidently; answering with the cloud model."),
                    latency: clock.now - start
                )))
            } else {
                messages.append(ChatMessage(content: .routing(result, latency: clock.now - start)))
            }
        } catch let error as LanguageModelSession.GenerationError {
            // Same production principle: a routing failure should degrade
            // to the cloud model, not a dead end for the user.
            messages.append(ChatMessage(content: .error(Self.friendlyMessage(for: error))))
            messages.append(ChatMessage(content: .routing(
                Self.cloudFallback(reason: "On-device routing failed; answering with the cloud model."),
                latency: nil
            )))
        } catch {
            messages.append(ChatMessage(content: .error(error.localizedDescription)))
        }
    }

    private static func cloudFallback(reason: String) -> RoutingResult {
        RoutingResult(
            strategyName: "Cloud Fallback",
            reasoning: reason,
            calls: [RoutedCall(tool: ToolName.none, confidence: nil)]
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
