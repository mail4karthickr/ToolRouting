import SwiftUI

// MARK: - Chat Message
//
// Renders one conversation entry: a trailing bubble for the user's
// question, the routing answer card for the assistant, or an error card.

struct ChatMessageView: View {
    let message: ChatMessage

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
            RoutingResultView(result: result, latency: latency)

        case .error(let text):
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.subheadline)
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}
