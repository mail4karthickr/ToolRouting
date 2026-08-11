import SwiftUI

// MARK: - Pipeline sheet
//
// The whole run, stage by stage, for one answer:
//
//   1. Retrieval  — every tool scored, the shortlist marked, the losers
//                   kept (a near miss is the most useful row on screen)
//   2. Selection  — the model's reasoning, its route decision, the plan,
//                   and any policy this app applied on top of it
//   3. Execution  — the tools that actually ran, their arguments, their
//                   raw output, and the answer composed from them
//
// A stage that never ran gets a card saying so and why. That is not an
// empty state: short-circuiting IS the behavior — retrieval abstains
// before the LLM costs anything, selection escalates before the agent
// does — and hiding it would make the cheap path look like a bug.

struct RoutingTraceSheet: View {
    let result: RoutingResult
    let timing: ResponseTiming

    @Environment(\.dismiss) private var dismiss

    private var trace: RoutingTrace { result.trace }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header

                    if trace.isEmpty {
                        noPipelineCard
                    } else {
                        retrievalCard
                        selectionCard
                        executionCard
                    }
                }
                .padding()
            }
            .navigationTitle("How this was answered")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(result.strategyName)
                .font(.headline)

            // Measured from the send, so both numbers include the stages
            // below plus whatever the app did around them. The per-stage
            // times will not add up to `total` and are not meant to —
            // that gap is the app's own overhead, and hiding it by
            // reporting only the sum of the stages would be flattering.
            HStack(spacing: 10) {
                if let first = timing.timeToFirstToken {
                    TimingChip(title: "First token", value: first.traceLabel)
                }
                if let total = timing.total {
                    TimingChip(title: "End to end", value: total.traceLabel)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var noPipelineCard: some View {
        StageCard(number: nil, title: "No pipeline ran", subtitle: nil, duration: nil) {
            Text(result.reasoning ?? "This answer did not go through the on-device pipeline.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Stage 1

    @ViewBuilder
    private var retrievalCard: some View {
        if let retrieval = trace.retrieval {
            StageCard(
                number: 1,
                title: "Retrieval",
                subtitle: "MiniLM embedding search over all \(retrieval.ranked.count) tools",
                duration: retrieval.duration
            ) {
                RetrievalStageView(stage: retrieval)
            }
        }
    }

    // MARK: Stage 2

    @ViewBuilder
    private var selectionCard: some View {
        if let selection = trace.selection {
            StageCard(
                number: 2,
                title: "Selection",
                subtitle: "On-device LLM, shown only the \(selection.candidates.count) shortlisted tools",
                duration: selection.duration
            ) {
                SelectionStageView(stage: selection)
            }
        } else {
            SkippedStageCard(
                number: 2,
                title: "Selection",
                reason: "Nothing cleared the similarity threshold, so the LLM never ran — the cheap stage rejected the request on its own."
            )
        }
    }

    // MARK: Stage 3

    @ViewBuilder
    private var executionCard: some View {
        if let execution = trace.execution {
            StageCard(
                number: 3,
                title: "Execution",
                subtitle: "Agent session bound to \(execution.boundTools.count) tool\(execution.boundTools.count == 1 ? "" : "s")",
                duration: execution.duration
            ) {
                ExecutionStageView(stage: execution)
            }
        } else {
            SkippedStageCard(
                number: 3,
                title: "Execution",
                reason: trace.selection == nil
                    ? "No plan reached the agent."
                    : "The request went to the cloud model, so no on-device tool was run."
            )
        }
    }
}

// MARK: - Stage 1 body

private struct RetrievalStageView: View {
    let stage: RoutingTrace.RetrievalStage

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("top-k \(stage.topK) · threshold \(stage.threshold, format: .number.precision(.fractionLength(2)))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            if stage.shortlist.isEmpty {
                Text("No tool cleared the threshold.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                TraceLabel("Shortlisted — passed to the LLM")
                ForEach(stage.shortlist) { candidate in
                    CandidateRow(candidate: candidate, threshold: stage.threshold)
                }
            }

            if !stage.rejected.isEmpty {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(stage.rejected) { candidate in
                            CandidateRow(candidate: candidate, threshold: stage.threshold)
                        }
                    }
                    .padding(.top, 8)
                } label: {
                    Text("Also scored (\(stage.rejected.count))")
                        .font(.caption.uppercaseSmallCaps())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// One tool's similarity score. The bar is there so a near miss reads as
/// a near miss at a glance — the number alone doesn't.
private struct CandidateRow: View {
    let candidate: RoutingTrace.RetrievalStage.Candidate
    let threshold: Double

    private var tint: Color {
        if candidate.isShortlisted { return .green }
        return candidate.score >= threshold - 0.05 ? .orange : .secondary
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(candidate.toolName)
                .font(.subheadline.monospaced())
                .foregroundStyle(candidate.isShortlisted ? .primary : .secondary)
                .lineLimit(1)

            Spacer(minLength: 8)

            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(tint)
                    .frame(width: 56 * max(0, min(1, candidate.score)))
            }
            .frame(width: 56, height: 5)

            Text(candidate.score, format: .number.precision(.fractionLength(2)))
                .font(.caption.monospacedDigit())
                .foregroundStyle(tint)
                .frame(width: 34, alignment: .trailing)
        }
    }
}

// MARK: - Stage 2 body

private struct SelectionStageView: View {
    let stage: RoutingTrace.SelectionStage

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Prompt vs. plan. The two halves of this stage's cost have
            // nothing to do with each other: the first shrinks by showing
            // fewer tools, the second by asking for less writing.
            if stage.promptTokens != nil || stage.outputTokens != nil {
                HStack(spacing: 10) {
                    if let prompt = stage.promptTokens {
                        TimingChip(title: "Prompt", value: "\(prompt) tok")
                    }
                    if let output = stage.outputTokens {
                        TimingChip(title: "Plan written", value: "\(output) tok")
                    }
                }
            }

            // The model's chain of thought, when it writes one. It no
            // longer does — the sentence was most of this stage's output
            // tokens and was dropped for latency — so the card now
            // explains itself with the decision, the plan and the policy
            // below instead of in the model's own words.
            if let reasoning = stage.reasoning {
                VStack(alignment: .leading, spacing: 6) {
                    TraceLabel("Thinking")
                    Text(reasoning)
                        .font(.subheadline)
                        .italic()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                        .textSelection(.enabled)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                TraceLabel("Decision")
                switch stage.route {
                case .useTools:
                    Badge(text: "useTools", detail: "The shortlist answers this", tint: .green, icon: "iphone")
                case .noMatch:
                    // Two facts, deliberately separated: what the MODEL
                    // said, and what this app then did about it. The
                    // model only reports that nothing fits; the cloud is
                    // this app's answer to that, not the model's.
                    Badge(text: "noMatch", detail: "Nothing in the shortlist fits — the app sends it to the cloud", tint: .blue, icon: "cloud")
                }
            }

            if !stage.plannedCalls.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    // "Selected", not "in execution order". Stage 2 picks
                    // WHICH tools; the order they run in is Stage 3's, and
                    // the numbering here is just a list index.
                    TraceLabel("Selected tools")
                    ForEach(Array(stage.plannedCalls.enumerated()), id: \.element.id) { index, call in
                        StepRow(step: index + 1, title: call.toolName, detail: call.arguments)
                    }
                }
            }

            if !stage.policyNotes.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    TraceLabel("Policy applied in code")
                    ForEach(stage.policyNotes, id: \.self) { note in
                        Label(note, systemImage: "shield.lefthalf.filled")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }

            DisclosureGroup {
                Text(stage.candidates.joined(separator: "\n"))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
            } label: {
                Text("Tools in the prompt (\(stage.candidates.count))")
                    .font(.caption.uppercaseSmallCaps())
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Stage 3 body

private struct ExecutionStageView: View {
    let stage: RoutingTrace.ExecutionStage

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Splits the stage in two. Everything before the first
            // character is tool work — the model cannot write a figure it
            // has not fetched — and everything after is generation. When
            // this stage is slow, which half it was in decides whether to
            // look at the API client or at the plan's size.
            //
            // ONLY when one generation ran. `timeToFirstToken` belongs to
            // the generation that produced the answer, so after a retry it
            // is the SECOND one's, while `duration` still covers both —
            // subtracting them would file the whole rejected draft under
            // "writing" and quietly understate what the retry cost.
            if let first = stage.timeToFirstToken, !stage.retriedForUnverifiedFigures {
                HStack(spacing: 10) {
                    TimingChip(title: "Tools, then first token", value: first.traceLabel)
                    TimingChip(title: "Writing", value: (stage.duration - first).traceLabel)
                }
            } else if stage.retriedForUnverifiedFigures {
                HStack(spacing: 10) {
                    TimingChip(title: "Generations", value: "2")
                    if let first = stage.timeToFirstToken {
                        TimingChip(title: "Retry's first token", value: first.traceLabel)
                    }
                }
            }

            if stage.invocations.isEmpty {
                Text("The agent called no tools.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    TraceLabel("Tool calls, as they ran")
                    ForEach(Array(stage.invocations.enumerated()), id: \.element.id) { index, call in
                        InvocationRow(step: index + 1, invocation: call)
                    }
                }
            }

            // Plan vs. reality — compared as SETS, not sequences. Stage 2
            // selects which tools are needed and says nothing about
            // order, so a different order is the agent doing its job, not
            // a discrepancy. What still matters is a selected tool that
            // never ran, or a call nobody selected.
            if Set(stage.boundTools) != Set(stage.invocations.map(\.toolName)) {
                Label(
                    "Selected: \(stage.boundTools.joined(separator: ", ")) — the agent did not run exactly these.",
                    systemImage: "arrow.triangle.branch"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }

            if stage.retriedForUnverifiedFigures {
                VStack(alignment: .leading, spacing: 6) {
                    Label(
                        stage.rejectedFigures.isEmpty
                            ? "The first draft showed a figure no tool returned. It was rejected and the answer written again with the tools withdrawn."
                            : "Rejected \(stage.rejectedFigures.joined(separator: ", ")) — no tool returned \(stage.rejectedFigures.count == 1 ? "it" : "them"). The answer was written again with the tools withdrawn, so only figures already above could be used.",
                        systemImage: "checkmark.shield"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)

                    // The draft itself, because the figure alone rarely
                    // explains the mistake — a stutter, a rounding, and a
                    // fabrication all show up as one stray number here and
                    // need completely different fixes.
                    if let draft = stage.rejectedDraft {
                        Text(draft)
                            .font(.caption.italic())
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                            .textSelection(.enabled)
                    }
                }
            }

            if let failure = stage.failure {
                VStack(alignment: .leading, spacing: 6) {
                    TraceLabel("Failed")
                    Text(failure)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }

            if let answer = stage.answer {
                VStack(alignment: .leading, spacing: 6) {
                    TraceLabel("Answer")
                    Text(answer)
                        .font(.subheadline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                        .textSelection(.enabled)
                }
            }
        }
    }
}

private struct InvocationRow: View {
    let step: Int
    let invocation: RoutingTrace.ExecutionStage.Invocation

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            StepBadge(step: step)

            VStack(alignment: .leading, spacing: 4) {
                Text(invocation.toolName)
                    .font(.subheadline.monospaced().bold())

                if let arguments = invocation.arguments {
                    Text(arguments)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                // The raw string the tool handed back — the ground truth
                // every figure in the answer has to trace to.
                Text(invocation.output ?? "no output returned")
                    .font(.caption.monospaced())
                    .foregroundStyle(invocation.output == nil ? .orange : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                    .textSelection(.enabled)
            }
        }
    }
}

// MARK: - Shared pieces

private struct StageCard<Content: View>: View {
    let number: Int?
    let title: String
    let subtitle: String?
    let duration: Duration?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if let number {
                    StepBadge(step: number)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if let duration {
                    Text(duration.traceLabel)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                }
            }

            Divider()
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct SkippedStageCard: View {
    let number: Int
    let title: String
    let reason: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            StepBadge(step: number, isMuted: true)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(title) — skipped")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct StepBadge: View {
    let step: Int
    var isMuted = false

    var body: some View {
        Text("\(step)")
            .font(.footnote.monospacedDigit().bold())
            .foregroundStyle(isMuted ? .secondary : .primary)
            .frame(width: 22, height: 22)
            .background(.quaternary, in: Circle())
    }
}

/// A planned call. The icon and colour come from the catalog definition,
/// so a tool looks the same here as it does in the app's tool list; a
/// name with no definition is `none`, the escalation marker.
private struct StepRow: View {
    let step: Int
    let title: String
    let detail: String?

    private var definition: ToolDefinition? { ToolCatalog.byName[title] }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            StepBadge(step: step)

            Image(systemName: definition?.icon ?? "cloud")
                .font(.subheadline)
                .foregroundStyle(definition?.color ?? .blue)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.monospaced().bold())
                if let detail {
                    Text(detail)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// A labelled duration. Labelled because there are now several of them
/// on this screen and a bare "1.4s" next to another bare "1.4s" is worse
/// than no number at all.
private struct TimingChip: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.caption2.uppercaseSmallCaps())
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospacedDigit().bold())
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct TraceLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption.uppercaseSmallCaps())
            .foregroundStyle(.secondary)
    }
}

private struct Badge: View {
    let text: String
    let detail: String
    let tint: Color
    let icon: String

    var body: some View {
        HStack(spacing: 8) {
            Label(text, systemImage: icon)
                .font(.caption.monospaced().bold())
                .foregroundStyle(tint)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(tint.opacity(0.15), in: Capsule())
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
