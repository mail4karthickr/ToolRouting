import SwiftUI

// MARK: - Content View (chat)

struct ContentView: View {
    @State private var viewModel = ToolRoutingViewModel()
    @State private var isShowingTools = false

    /// Owned explicitly rather than left to whatever the tap happened to
    /// focus, so the field can be put back into focus after a send —
    /// clearing the text is not the same as keeping the caret, and
    /// without this the keyboard drops between questions.
    @FocusState private var isInputFocused: Bool

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

    // SCROLL POSITION IS DECLARED, NOT DRIVEN. The earlier version chased
    // it with `scrollTo(last, anchor: .bottom)` on every change, which is
    // where the gap above the first question came from: asking for the
    // last bubble's BOTTOM to sit at the container's bottom, in a
    // conversation far too short to fill the screen, is a request to push
    // the content down, and it was honoured.
    //
    // The two anchors below say the same thing the scrollTo was trying to
    // say, but they distinguish the two cases it could not:
    //
    //   .alignment    where content sits when it does NOT fill the view —
    //                 the top, so a one-question chat starts under the
    //                 title like every message after it
    //   .sizeChanges  where the view stays as content GROWS — the bottom,
    //                 so a streaming answer scrolls itself into view
    //
    // That also removes the ScrollViewReader, both onChange handlers, and
    // the per-token scroll call: following the stream is now the scroll
    // view's own behaviour rather than something recomputed on every
    // snapshot.
    //
    // VStack, NOT LazyVStack, and that is a requirement of the anchors
    // rather than a preference. Holding the bottom across a size change
    // means knowing the total content height; a lazy stack deliberately
    // does not know it, and revises its estimate as rows materialise. The
    // two together form a loop — the anchor corrects the offset, the
    // correction brings a row into range, materialising it changes the
    // height, the anchor corrects again — which shows up as a view that
    // creeps downward with nobody touching it. A conversation is a few
    // dozen short rows; measuring all of them costs nothing and makes the
    // height exact.
    private var messageList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                availabilityBanner

                ForEach(viewModel.messages) { message in
                    ChatMessageView(message: message)
                        .id(message.id)
                        // Rises from below on the way in, which is where
                        // the input bar is — the bubble reads as the thing
                        // that was just typed, moving to where it now
                        // lives.
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .topLeading)
            // Scoped to the count so it fires on send and on the answer's
            // arrival, and NOT on every streamed token: the turn's content
            // changes constantly while its identity does not, and
            // animating that would make the text shimmer as it is written.
            .animation(.snappy(duration: 0.28), value: viewModel.messages.count)
        }
        .defaultScrollAnchor(.top, for: .alignment)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        // A conversation shorter than the screen shouldn't be draggable at
        // all; without this it rubber-bands against nothing.
        .scrollBounceBehavior(.basedOnSize)
        // Out of the scroll flow deliberately: as a child of the stack,
        // ContentUnavailableView expands to fill the scroll view, so it
        // would set the content height for the whole empty conversation.
        // An overlay has no say in the content's layout.
        .overlay {
            if viewModel.messages.isEmpty {
                emptyState
                    // It sits on top of the scroll view, so left
                    // interactive it would be the thing every tap in the
                    // message area hits.
                    .allowsHitTesting(false)
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

    // MARK: Input

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask about your accounts…", text: $viewModel.userPrompt, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .focused($isInputFocused)
                .submitLabel(.send)
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

    /// Empties the field HERE, synchronously, before the work starts.
    ///
    /// Clearing it inside `send` left it full until the Task actually got
    /// scheduled, so a fast tap-and-look — or a `.onSubmit` that fires
    /// while the keyboard is still animating — showed the question
    /// sitting in the field after it had been asked, which reads as a
    /// send that didn't take. The view owns the binding, so the view
    /// clears it.
    private func submit() {
        // Guarded before clearing, not after. The send BUTTON is disabled
        // while a turn is running, but the keyboard's return key is not,
        // and clearing first would throw away a question that was never
        // going to be sent.
        let question = viewModel.userPrompt.trimmingCharacters(in: .whitespaces)
        guard !question.isEmpty, !viewModel.isLoading else { return }

        viewModel.userPrompt = ""
        // Held, not dropped. A chat is a sequence of questions, and
        // `.onSubmit` on a vertical TextField resigns first responder on
        // its way out — so without this the keyboard dismisses itself
        // after every send and the next question needs a tap first.
        isInputFocused = true
        Task { await viewModel.send(question) }
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
