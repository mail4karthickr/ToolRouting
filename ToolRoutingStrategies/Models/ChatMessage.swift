import Foundation

// MARK: - Chat Message
//
// One entry in the conversation. Assistant entries are MUTABLE, which is
// the whole shape of streaming here: the turn is appended the moment the
// user sends, and then rewritten in place as the pipeline reports
// progress and the answer arrives token by token. There is no separate
// "thinking" row that gets swapped for an answer row — the bubble the
// user watches fill in is the same bubble that ends up holding the
// finished answer and its trace.

struct ChatMessage: Identifiable {
    enum Content {
        case user(String)
        case assistant(AssistantTurn)
        case error(String)
    }

    let id = UUID()
    var content: Content
}

// MARK: - The assistant's turn, in flight or finished

struct AssistantTurn {
    /// Where the pipeline is. Every value except `done` means more is
    /// coming, so the view derives "is this still running" from the stage
    /// rather than from a separate flag that could disagree with it.
    enum Stage {
        case retrieving
        case selecting
        case answering
        case rewriting
        case done

        /// Shown in the footer while the turn is in flight. Phrased as
        /// what is happening now, not as a percentage — the stages take
        /// wildly different amounts of time and a progress bar would
        /// misrepresent that.
        var label: String {
            switch self {
            case .retrieving: "Searching tools…"
            case .selecting: "Choosing tools…"
            case .answering: "Running tools…"
            case .rewriting: "Checking the figures…"
            case .done: ""
            }
        }
    }

    var stage: Stage = .retrieving

    /// The answer as far as it has been written. Assigned, never
    /// appended: partials are cumulative snapshots, and a rewrite after a
    /// failed verification clears this back to empty on purpose.
    var text = ""

    /// The finished run — the plan, the trace, everything the pipeline
    /// sheet reads. Nil until the turn completes, which is also what
    /// gates the tap affordance: there is nothing to show mid-stream.
    var result: RoutingResult?

    var timing = ResponseTiming()

    var isStreaming: Bool { stage != .done }
}
