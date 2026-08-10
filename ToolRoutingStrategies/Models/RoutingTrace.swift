import Foundation

// MARK: - Pipeline trace
//
// What each stage of the hybrid ACTUALLY did, recorded as it runs.
//
// `RoutingResult` is the outcome — the plan and the answer. This is the
// account of how that outcome was reached, and it exists because the
// interesting failures are invisible in the outcome alone: a tool that
// missed the shortlist by 0.02, a model that reasoned correctly and then
// selected something else, an agent that called a tool routing never
// planned. Each of those looks identical from the outside ("wrong
// answer") and completely different here.
//
// Stages are optional because the pipeline short-circuits: retrieval can
// abstain before the LLM runs, and selection can escalate to the cloud
// before the agent runs. A nil stage means "never ran", which is itself
// a thing worth showing.

struct RoutingTrace {
    var retrieval: RetrievalStage?
    var selection: SelectionStage?
    var execution: ExecutionStage?

    /// True when nothing was recorded — a cloud fallback taken before the
    /// pipeline started, so there is no pipeline to show.
    var isEmpty: Bool {
        retrieval == nil && selection == nil && execution == nil
    }
}

// MARK: - Stage 1: embedding retrieval

extension RoutingTrace {
    struct RetrievalStage {
        struct Candidate: Identifiable {
            let toolName: String
            let score: Double
            /// False when the tool scored below the threshold or fell
            /// outside top-k — it was scored, but the LLM never saw it.
            let isShortlisted: Bool

            var id: String { toolName }
        }

        let topK: Int
        let threshold: Double
        /// EVERY tool in the index, ranked by similarity. The near misses
        /// matter as much as the hits: Stage 1's recall is the pipeline's
        /// hard ceiling, and a tool that scored 0.44 against a 0.45
        /// threshold is a threshold problem, not a model problem.
        let ranked: [Candidate]
        let duration: Duration

        var shortlist: [Candidate] { ranked.filter(\.isShortlisted) }
        var rejected: [Candidate] { ranked.filter { !$0.isShortlisted } }
    }
}

// MARK: - Stage 2: LLM selection

extension RoutingTrace {
    struct SelectionStage {
        enum Route: String {
            case useTools
            case sendToCloud
        }

        struct PlannedCall: Identifiable {
            let id = UUID()
            let toolName: String
            let arguments: String?
        }

        /// The k tool names whose descriptions went into the prompt —
        /// the only tools this stage could possibly have picked.
        let candidates: [String]
        /// The model's own one-sentence chain of thought. Generated
        /// BEFORE `route` and `calls` (declaration order in RoutingPlan),
        /// so it is the reasoning that led to them, not a rationalization
        /// written afterwards.
        let reasoning: String
        let route: Route
        let plannedCalls: [PlannedCall]
        /// Policy applied in code AFTER the model answered — dedupe, the
        /// candidate-set check, the `none` collapse. Empty on a clean
        /// plan; when non-empty it explains a result the model's own
        /// output doesn't account for.
        let policyNotes: [String]
        let duration: Duration
    }
}

// MARK: - Stage 3: agent execution

extension RoutingTrace {
    struct ExecutionStage {
        struct Invocation: Identifiable {
            let id = UUID()
            let toolName: String
            /// The arguments the AGENT chose, which are re-derived from
            /// the tool's own schema and can differ from the ones Stage 2
            /// planned — that difference is the last mile the agent owns.
            let arguments: String?
            let output: String?
        }

        /// The tools bound to the agent's session — the plan, filtered to
        /// those with an implementation.
        let boundTools: [String]
        /// What the model actually called, in order. Compare against
        /// `boundTools`: a skipped tool or an extra call lives here.
        let invocations: [Invocation]
        let answer: String?
        /// The verifier rejected the first draft (a figure with no source
        /// in any tool output) and the agent answered again.
        let retriedForUnverifiedFigures: Bool
        /// Why no answer came back, when one didn't.
        let failure: String?
        let duration: Duration
    }
}

// MARK: - Formatting

extension Duration {
    /// Compact stage timing: "412ms", "1.4s".
    var traceLabel: String {
        formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow))
    }
}
