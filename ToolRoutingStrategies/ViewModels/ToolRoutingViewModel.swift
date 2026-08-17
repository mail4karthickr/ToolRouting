import Foundation
import FoundationModels
import Observation

// MARK: - ViewModel
//
// Orchestrates the chat: appends the user's question, runs it through
// the hybrid pipeline, and rewrites the assistant's turn in place as the
// pipeline reports progress and the answer streams in.
//
// Every request goes through ChatAgent. MiniLMRouter and LLMRouter still
// exist as its two routing stages, and the evals run them alone to
// measure what each contributes, but they are not user-facing choices.
//
// TIMING IS MEASURED HERE, from the send, and not inside the agent.
// The agent can only see its own stages; the number that matters is the
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
    private let router = ChatAgent()

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

            // The end-to-end number, measured from the send rather than
            // from inside the router — everything this class does before
            // `route` is part of the user's wait too.

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
        } catch let error as LanguageModelError {
            // NOT EVERY FAILURE IS AN ESCALATION, and the difference is
            // the point. Exactly two — a guardrail trip and a refusal —
            // mean "the on-device path will not serve this", and those
            // never reach here: HybridRouter turns them into a cloud
            // fallback, because declining is a routing answer rather than
            // a routing failure.
            //
            // What reaches here is the genuinely broken, and sending it
            // to the cloud would be wrong. A context overflow in
            // particular is a CLIENT problem — the request outgrew a
            // 4,096-token window — and forwarding it off-device turns a
            // fixable local condition into an unnecessary round trip
            // (and, for a request that was too long precisely because it
            // carried a lot of the user's data, an unnecessary one to
            // make). The user is told, and nothing leaves the device.
            messages[index].content = .error(Self.friendlyMessage(for: error))
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

    /// What to tell the user about a failure that stays on the device.
    ///
    /// Every case here is one the cloud is NOT the answer to, so each
    /// message says what happened and, where there is one, what the user
    /// can do about it. `guardrailViolation` and `refusal` are absent on
    /// purpose: HybridRouter escalates those before they get this far.
    private static func friendlyMessage(for error: LanguageModelError) -> String {
        switch error {
        case .contextSizeExceeded:
            return "That request is too long for the on-device model. Try asking for less at once."
        case .unsupportedLanguageOrLocale:
            return "The on-device model doesn't support that language yet."
        case .rateLimited:
            return "The on-device model is busy right now. Try again in a moment."
        case .timeout:
            return "The on-device model took too long to answer. Try again."
        case .guardrailViolation, .refusal:
            // Unreachable in the hybrid pipeline; kept exhaustive so a
            // future caller that skips the router still reads sensibly.
            return "The on-device model declined to handle this request."
        default:
            return error.localizedDescription
        }
    }
}
