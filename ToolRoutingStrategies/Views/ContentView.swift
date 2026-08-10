import SwiftUI

// MARK: - Content View (chat)

struct ContentView: View {
    @State private var viewModel = ToolRoutingViewModel()
    @State private var isShowingTools = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                messageList
                inputBar
            }
            .navigationTitle("Bank Assistant")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isShowingTools = true
                    } label: {
                        Image(systemName: "wrench.and.screwdriver")
                    }
                    .accessibilityLabel("Show app tools")
                }
            }
            .sheet(isPresented: $isShowingTools) {
                toolsSheet
            }
        }
        .task { viewModel.prewarm() }
    }

    // MARK: Messages

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    availabilityBanner

                    if viewModel.messages.isEmpty {
                        emptyState
                    }

                    ForEach(viewModel.messages) { message in
                        ChatMessageView(message: message)
                            .id(message.id)
                    }

                    if viewModel.isLoading {
                        thinkingIndicator
                    }
                }
                .padding()
            }
            .onChange(of: viewModel.messages.count) {
                if let last = viewModel.messages.last {
                    withAnimation {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var availabilityBanner: some View {
        if let message = viewModel.unavailabilityMessage {
            Label(message, systemImage: "icloud.and.arrow.up")
                .font(.subheadline)
                .foregroundStyle(.orange)
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(viewModel.strategyName, systemImage: "arrow.triangle.branch")
        } description: {
            Text("Ask a question and get an answer. Tap any answer to see the three stages behind it — what the embedding search retrieved, what the LLM selected and why, and what the tools returned.\n\nTry \"Find the nearest ATM\" or \"Show my balance and this week's transactions\".")
        }
    }

    private var thinkingIndicator: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text("Routing request…")
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: Input

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask about your accounts…", text: $viewModel.userPrompt, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)

            Button(action: submit) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title)
            }
            .disabled(
                viewModel.userPrompt.trimmingCharacters(in: .whitespaces).isEmpty
                    || viewModel.isLoading
            )
            .accessibilityLabel("Send")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func submit() {
        Task { await viewModel.send() }
    }

    // MARK: Tools sheet

    private var toolsSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(ToolCategory.allCases, id: \.self) { category in
                        let tools = ToolCatalog.all.filter { $0.category == category }
                        if !tools.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(category.rawValue)
                                    .font(.headline)
                                ForEach(tools) { tool in
                                    ToolRowView(tool: tool)
                                }
                            }
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("App Tools")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { isShowingTools = false }
                }
            }
        }
    }
}

#Preview {
    ContentView()
}
