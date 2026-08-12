import SwiftUI

// MARK: - Log viewer
//
// The log's whole purpose is to be read after something went wrong, and
// on a device that means it has to be reachable without Xcode attached.
// Three affordances, which is all this needs to be:
//
//   read    the tail of the current file, newest line at the bottom
//   filter  a `grep` over it — "stage1", "#7", "FAILED"
//   share   the file itself, out to Mail/Files/AirDrop
//
// The file is also visible in Files ▸ On My iPhone ▸ ToolRoutingStrategies
// (the app target sets UIFileSharingEnabled), so this is the convenient
// path rather than the only one.

struct LogSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// Loaded on appear and on demand, never observed: a log that
    /// re-rendered on every line would be unreadable while a request is
    /// running, which is exactly when it is open.
    @State private var text = ""
    @State private var filter = ""
    @State private var isConfirmingClear = false

    private var lines: [String] {
        let all = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard !filter.isEmpty else { return all }
        return all.filter { $0.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Self.tint(for: line))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            // Opens on the newest line, which is the one that matters
            // after a failure.
            .defaultScrollAnchor(.bottom)
            .searchable(text: $filter, prompt: "Filter — stage1, #7, FAILED")
            .navigationTitle("Log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    ShareLink(item: AppLog.fileURL) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Share the log file")

                    Button {
                        text = AppLog.tail()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Reload")

                    Button(role: .destructive) {
                        isConfirmingClear = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel("Clear the log")
                }
            }
            .confirmationDialog(
                "Clear the log?",
                isPresented: $isConfirmingClear,
                titleVisibility: .visible
            ) {
                Button("Clear", role: .destructive) {
                    AppLog.clear()
                    text = AppLog.tail()
                }
            } message: {
                Text("Deletes the current file and every archive, so the next run starts from nothing.")
            }
        }
        .task { text = AppLog.tail() }
    }

    /// Levels are one character in the file, so the line is matched on its
    /// own text — enough to make failures findable while scrolling.
    private static func tint(for line: String) -> Color {
        if line.contains(" E [") || line.contains(" C [") { return .red }
        if line.contains(" W [") { return .orange }
        if line.contains(" I [") { return .primary }
        return .secondary
    }
}

#Preview {
    LogSheet()
}
