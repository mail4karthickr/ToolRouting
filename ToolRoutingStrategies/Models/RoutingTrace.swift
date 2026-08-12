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
            /// The model found nothing in the shortlist that serves the
            /// request. Where it goes next is this app's policy, decided
            /// in HybridRouter — the model is not asked.
            case noMatch
        }

        struct PlannedCall: Identifiable {
            let id = UUID()
            let toolName: String
            let arguments: String?
        }

        /// The k tool names whose descriptions went into the prompt —
        /// the only tools this stage could possibly have picked.
        let candidates: [String]
        /// The model's own account of the choice, when it gives one.
        ///
        /// Nil since `RoutingPlan.reasoning` was dropped for latency — the
        /// sentence was most of what this stage generated. The stage still
        /// explains itself, just in facts rather than prose: what was in
        /// the prompt, what came out, and what policy did to it. Kept as
        /// an optional rather than deleted because restoring the field is
        /// one `git revert` away and this is the socket it plugs into.
        let reasoning: String?
        let route: Route
        let plannedCalls: [PlannedCall]
        /// Policy applied in code AFTER the model answered — dedupe, the
        /// candidate-set check, the `none` collapse. Empty on a clean
        /// plan; when non-empty it explains a result the model's own
        /// output doesn't account for.
        let policyNotes: [String]
        /// The prompt's cost and the plan's, separately. The prompt is
        /// the k tool descriptions; the output is `reasoning`, `route`
        /// and `calls`, in that order — and `reasoning` is a whole
        /// sentence against a word and a short list, so it is most of the
        /// second number. Anyone weighing whether to keep the model's
        /// chain of thought is weighing THIS, and should read it before
        /// deciding rather than after.
        let promptTokens: Int?
        let outputTokens: Int?
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
        /// Why no answer came back, when one didn't.
        let failure: String?
        /// Time from the agent's generation starting to its first
        /// character — so it INCLUDES the tool round trips, which is the
        /// point: the model cannot write a figure it has not fetched yet.
        /// Against `duration` it splits the stage into "waiting on tools"
        /// and "writing", the two costs that behave completely differently
        /// when the plan grows.
        ///
        /// Distinct from `ResponseTiming.timeToFirstToken`, which is
        /// measured from the user's tap and so also carries Stages 1 and 2.
        let timeToFirstToken: Duration?
        /// What the turn's prompt cost. The agent's session has every tool
        /// bound to it — it has to, being long-lived — so this is the
        /// number that proves only the ROUTED ones were put in front of the
        /// model. It should scale with the plan, never with the catalog.
        let promptTokens: Int?
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
