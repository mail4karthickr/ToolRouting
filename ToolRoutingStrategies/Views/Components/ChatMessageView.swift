import SwiftUI

// MARK: - Chat Message
//
// Renders one conversation entry: a trailing bubble for the user's
// question, a leading bubble carrying the assistant's answer, or an
// error card.
//
// The assistant bubble shows the ANSWER and nothing else. Everything
// about how it was reached — the shortlist, the model's reasoning, the
// tool calls and their raw results — lives one tap away in the pipeline
// sheet. Routing is the subject of this app, but it is still the
// explanation of the answer, not the answer.

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

        case .routing(let result, let latency):
            answerBubble(for: result, latency: latency)

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

    private func answerBubble(for result: RoutingResult, latency: Duration?) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 10) {
                Text(Self.answerText(for: result))
                    .font(.body)
                    .foregroundStyle(result.answer == nil ? .secondary : .primary)

                Divider()

                // The affordance. Deliberately a summary rather than a
                // bare "Details": the tool count and latency are the two
                // things worth knowing without opening anything.
                HStack(spacing: 6) {
                    Image(systemName: "list.bullet.indent")
                    Text(Self.summary(for: result, latency: latency))
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            .contentShape(RoundedRectangle(cornerRadius: 18))
            .onTapGesture { isShowingTrace = true }
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Shows how this answer was produced")

            Spacer(minLength: 24)
        }
        .sheet(isPresented: $isShowingTrace) {
            RoutingTraceSheet(result: result, latency: latency)
        }
    }

    /// What the bubble says. Stage 3's reply when there is one; otherwise
    /// the honest version of what happened, since a blank bubble reads as
    /// a bug and the routing outcome is still information.
    private static func answerText(for result: RoutingResult) -> String {
        if let answer = result.answer, !answer.isEmpty { return answer }

        if result.calls.contains(where: { $0.tool.isNone }) || result.calls.isEmpty {
            return "No on-device tool covers this one — it goes to the cloud model."
        }

        let names = result.calls.map(\.tool.displayName).joined(separator: ", ")
        return "Routed to \(names), but no answer came back. Tap to see where it stopped."
    }

    private static func summary(for result: RoutingResult, latency: Duration?) -> String {
        var parts: [String] = []

        let executed = result.executedTools.count
        if executed > 0 {
            parts.append("\(executed) tool\(executed == 1 ? "" : "s")")
        } else if result.calls.contains(where: { $0.tool.isNone }) || result.calls.isEmpty {
            parts.append("cloud")
        } else {
            parts.append("\(result.calls.count) planned")
        }

        if let latency {
            parts.append(latency.traceLabel)
        }
        return parts.joined(separator: " · ")
    }
}
