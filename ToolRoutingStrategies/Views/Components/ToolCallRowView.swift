import SwiftUI

// MARK: - Tool Call Row

struct ToolCallRowView: View {
    let step: Int
    let call: RoutedCall

    private var matchedTool: ToolDefinition? {
        ToolCatalog.byName[call.tool.displayName]
    }

    var body: some View {
        HStack(spacing: 14) {
            // Execution order — always shown so the sequence is explicit.
            Text("\(step)")
                .font(.headline.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(.quaternary, in: Circle())

            if let def = matchedTool {
                Image(systemName: def.icon)
                    .font(.title2)
                    .foregroundStyle(def.color)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(def.displayName)
                            .font(.headline)
                        Text("IN-APP")
                            .font(.caption2.bold())
                            .foregroundStyle(.green)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.green.opacity(0.15), in: Capsule())
                        if let confidence = call.confidence {
                            Text(confidence.formatted(.number.precision(.fractionLength(2))))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                    if let argument = call.argument {
                        Label(argument, systemImage: "arrow.right.circle")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                // Escalation: this sub-task goes to the backend.
                Image(systemName: "icloud.and.arrow.up")
                    .font(.title2)
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text("send_to_backend")
                            .font(.headline)
                        Text("BACKEND")
                            .font(.caption2.bold())
                            .foregroundStyle(.blue)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.blue.opacity(0.15), in: Capsule())
                    }
                    if let argument = call.argument {
                        Label(argument, systemImage: "arrow.right.circle")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
