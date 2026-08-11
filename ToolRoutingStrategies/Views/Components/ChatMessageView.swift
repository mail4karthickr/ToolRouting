import SwiftUI

// MARK: - Chat Message
//
// Renders one conversation entry: a trailing bubble for the user's
// question, a leading bubble carrying the assistant's turn, or an error
// card.
//
// The assistant bubble shows the ANSWER and nothing else. Everything
// about how it was reached — the shortlist, the tool calls and their raw
// results — lives one tap away in the pipeline sheet. Routing is the
// subject of this app, but it is still the explanation of the answer,
// not the answer.
//
// The same view covers the whole turn, from empty to finished, and
// changes character once: before the first token it is a bare status
// line, after it a card holding a reply. Its footer tracks the same
// arc — which stage is running and how long the first token took, then
// the summary and the tap affordance. One row, because the two are the
// same information at different points in time: how long this is
// taking, and what it cost.

struct ChatMessageView: View {
    let message: ChatMessage

    @State private var isShowingTrace = false

    var body: some View {
        switch message.content {
        case .user(let text):
            HStack {
                Spacer(minLength: 48)
                Text(text)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.tint, in: RoundedRectangle(cornerRadius: 18))
            }

        case .assistant(let turn):
            answerBubble(for: turn)

        case .error(let text):
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.subheadline)
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    // MARK: Assistant

    /// The answer sits in a card; the status that precedes it does not.
    ///
    /// The card is what marks a REPLY — something to read, keep, and tap
    /// for the pipeline behind it. "Searching tools…" is none of those:
    /// it is a few words that exist for a second or two and are then
    /// replaced, and giving them a card promises a substance they don't
    /// have and leaves an empty box sitting on screen while the model
    /// works.
    ///
    /// The card therefore appears on the first token, at the same moment
    /// the status label goes away — one thing turning into the other,
    /// rather than a container that was there all along being filled in.
    private func answerBubble(for turn: AssistantTurn) -> some View {
        // Nothing written yet and still running: this is a status line,
        // not an answer.
        let isStatusOnly = turn.isStreaming && turn.text.isEmpty

        return HStack {
            VStack(alignment: .leading, spacing: 10) {
                answerText(for: turn)
                if !isStatusOnly {
                    Divider()
                }
                footer(for: turn)
            }
            .padding(isStatusOnly ? 0 : 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isStatusOnly ? AnyShapeStyle(.clear) : AnyShapeStyle(.regularMaterial),
                in: RoundedRectangle(cornerRadius: 18)
            )
            .contentShape(RoundedRectangle(cornerRadius: 18))
            // Only once there is a run to show. Mid-stream there is no
            // trace yet, and a tap that opens an empty sheet is worse
            // than one that does nothing.
            .onTapGesture { isShowingTrace = turn.result != nil }
            .accessibilityAddTraits(turn.result == nil ? [] : .isButton)
            .accessibilityHint("Shows how this answer was produced")

            Spacer(minLength: 24)
        }
        .sheet(isPresented: $isShowingTrace) {
            if let result = turn.result {
                RoutingTraceSheet(result: result, timing: turn.timing)
            }
        }
    }

    /// What the bubble says. The text as far as it has been written while
    /// streaming, then Stage 3's finished reply. When there is no reply at
    /// all, the honest version of what happened, since a blank bubble
    /// reads as a bug and the routing outcome is still information.
    @ViewBuilder
    private func answerText(for turn: AssistantTurn) -> some View {
        if !turn.text.isEmpty {
            // The caret is part of the same string so it sits on the last
            // line's baseline and moves with the final word, rather than
            // being a separate view that has to be laid out against
            // wrapping text.
            Text(turn.isStreaming ? "\(turn.text) ▍" : turn.text)
                .font(.body)
        } else if let result = turn.result {
            Text(Self.fallbackText(for: result))
                .font(.body)
                .foregroundStyle(.secondary)
        }
        // Otherwise: in flight with nothing written yet. The footer is
        // already saying which stage is running, so an empty body here is
        // the correct amount of noise.
    }

    private static func fallbackText(for result: RoutingResult) -> String {
        if result.calls.contains(where: { $0.tool.isNone }) || result.calls.isEmpty {
            return "No on-device tool covers this one — it goes to the cloud model."
        }

        let names = result.calls.map(\.tool.displayName).joined(separator: ", ")
        return "Routed to \(names), but no answer came back. Tap to see where it stopped."
    }

    // MARK: Footer

    @ViewBuilder
    private func footer(for turn: AssistantTurn) -> some View {
        if turn.isStreaming {
            HStack(spacing: 8) {
                // The stage name carries the motion itself, so there is
                // no spinner beside it. Two indicators of the same fact,
                // animating at different rates, is noise.
                Text(turn.stage.label)
                    .shimmering()
                Spacer(minLength: 4)
                // Shown the instant it is known rather than held back for
                // the summary: while the rest of the answer is still
                // arriving, the time to the first character is the only
                // finished measurement there is.
                if let first = turn.timing.timeToFirstToken {
                    Text("first token \(first.traceLabel)")
                        .monospacedDigit()
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
            // Deliberately a summary rather than a bare "Details": the
            // tool count and the two timings are what is worth knowing
            // without opening anything.
            HStack(spacing: 6) {
                Image(systemName: "list.bullet.indent")
                Text(Self.summary(for: turn))
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private static func summary(for turn: AssistantTurn) -> String {
        var parts: [String] = []

        if let result = turn.result {
            let executed = result.executedTools.count
            if executed > 0 {
                parts.append("\(executed) tool\(executed == 1 ? "" : "s")")
            } else if result.calls.contains(where: { $0.tool.isNone }) || result.calls.isEmpty {
                parts.append("cloud")
            } else {
                parts.append("\(result.calls.count) planned")
            }
        }

        if let timing = turn.timing.label {
            parts.append(timing)
        }
        return parts.joined(separator: " · ")
    }
}
