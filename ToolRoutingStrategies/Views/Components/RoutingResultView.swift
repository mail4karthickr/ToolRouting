import SwiftUI

// MARK: - Result Card

struct RoutingResultView: View {
    let result: RoutingResult
    let latency: Duration?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                SectionHeader(
                    title: result.calls.count == 1 ? "Routing Decision" : "Execution Plan",
                    icon: "checkmark.seal.fill"
                )
                Spacer()
                if let latency {
                    Text(latency.formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                }
            }

            ForEach(Array(result.calls.enumerated()), id: \.element.id) { index, call in
                ToolCallRowView(step: index + 1, call: call)
            }

            if let reasoning = result.reasoning {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Reasoning")
                        .font(.caption.uppercaseSmallCaps())
                        .foregroundStyle(.secondary)
                    Text(reasoning)
                        .font(.subheadline)
                }
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}
