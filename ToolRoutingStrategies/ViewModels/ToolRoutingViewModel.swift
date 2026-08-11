import Foundation
import FoundationModels
import Observation

// MARK: - ViewModel
//
// Orchestrates the chat: appends the user's question, runs it through
// the hybrid pipeline, and rewrites the assistant's turn in place as the
// pipeline reports progress and the answer streams in.
//
// Every request goes through HybridRouter. MiniLMRouter and LLMRouter
// still exist as its two stages, and the evals still run them alone to
// measure what each contributes, but they are not user-facing choices:
// the embedding stage can't parameterize a call and the LLM stage alone
// pays the whole catalog in its prompt, so neither is a strategy anyone
// would pick for an actual question.
//
// TIMING IS MEASURED HERE, from the send, and not inside the router.
// The router can only see its own stages; the number that matters is the
// one that starts when the user's finger leaves the button. Anything
// this class does before calling `route` is part of the wait too, and
// measuring from in here is the only way that stays true.

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

    /// Takes the question rather than reading `userPrompt`, because the
    /// view clears that field the instant the user taps send — see
    /// `ContentView.submit`. By the time this runs, `userPrompt` is
    /// already empty and only the value passed in is still the question.
    func send(_ question: String) async {
        let trimmed = question.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !isLoading else { return }

        messages.append(ChatMessage(content: .user(trimmed)))

        // Production behavior: if the on-device router is unavailable,
        // the app should fall back to answering the request with the
        // cloud model rather than erroring. Modeled here as a single
        // `none` call, finished on arrival — nothing ran, so there is no
        // timing to report and no stream to watch.
        if router.unavailabilityMessage != nil {
            messages.append(ChatMessage(content: .assistant(AssistantTurn(
                stage: .done,
                result: Self.cloudFallback(reason: "On-device routing is unavailable; answering with the cloud model.")
            ))))
            return
        }

        isLoading = true
        defer { isLoading = false }

        let clock = ContinuousClock()
        let start = clock.now

        // The bubble goes up empty and is filled in place. `send` is
        // guarded by `isLoading`, so this index stays valid for the whole
        // run: no other turn can be appended underneath it.
        let index = messages.count
        messages.append(ChatMessage(content: .assistant(AssistantTurn())))

        do {
            let result = try await router.route(trimmed) { update in
                apply(update, at: index, since: start, on: clock)
            }

            // Abstain: the router found no tool it trusts. POLICY,
            // decided here and not in the router: same outcome as an
            // explicit `none` — the cloud model answers the request.
            let answered = result.calls.isEmpty
                ? Self.cloudFallback(reason: "No on-device tool matched confidently; answering with the cloud model.")
                : result

            update(at: index) {
                $0.stage = .done
                $0.result = answered
                // The streamed text and the final text are the same
                // string; assigning the authoritative one anyway keeps a
                // degraded run (agent failed, no answer) from leaving a
                // half-written draft on screen.
                $0.text = answered.answer ?? ""
                $0.timing.total = clock.now - start
            }
        } catch let error as LanguageModelSession.GenerationError {
            // Same production principle: a routing failure should degrade
            // to the cloud model, not a dead end for the user. The
            // in-flight bubble becomes the error, so a turn never ends
            // still claiming to be running.
            messages[index].content = .error(Self.friendlyMessage(for: error))
            messages.append(ChatMessage(content: .assistant(AssistantTurn(
                stage: .done,
                result: Self.cloudFallback(reason: "On-device routing failed; answering with the cloud model.")
            ))))
        } catch {
            messages[index].content = .error(error.localizedDescription)
        }
    }

    // MARK: Streaming

    /// Folds one progress report into the turn on screen.
    private func apply(
        _ progress: RoutingUpdate,
        at index: Int,
        since start: ContinuousClock.Instant,
        on clock: ContinuousClock
    ) {
        switch progress {
        case .retrieving:
            update(at: index) { $0.stage = .retrieving }
        case .selecting:
            update(at: index) { $0.stage = .selecting }
        case .answering:
            update(at: index) { $0.stage = .answering }
        case .answerPartial(let text):
            update(at: index) {
                // First character on screen — the number streaming exists
                // to improve. Recorded on the way past rather than
                // reconstructed later, because by the time the answer is
                // finished this moment is unrecoverable.
                if $0.timing.timeToFirstToken == nil {
                    $0.timing.timeToFirstToken = clock.now - start
                }
                $0.stage = .answering
                $0.text = text
            }
        case .answerRewriting:
            // The draft was wrong and is being retracted. Clearing the
            // text is the point: leaving it would let a figure the
            // verifier rejected sit on screen while its replacement is
            // written. TTFT is left alone — the user did see a first
            // token, and pretending otherwise would flatter the number.
            update(at: index) {
                $0.stage = .rewriting
                $0.text = ""
            }
        }
    }

    private func update(at index: Int, _ change: (inout AssistantTurn) -> Void) {
        guard messages.indices.contains(index),
              case .assistant(var turn) = messages[index].content
        else { return }
        change(&turn)
        messages[index].content = .assistant(turn)
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
