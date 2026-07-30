import SwiftUI

// MARK: - Tool Row

struct ToolRowView: View {
    let tool: ToolDefinition

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: tool.icon)
                .font(.title3)
                .foregroundStyle(tool.color)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(tool.displayName)
                    .font(.subheadline.bold())
                Text(tool.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}
