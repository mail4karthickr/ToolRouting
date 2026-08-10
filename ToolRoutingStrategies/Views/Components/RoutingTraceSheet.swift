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
    let latency: Duration?

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
            if let latency {
                Text("End to end: \(latency.traceLabel)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
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
            // The model's chain of thought, generated before it chose
            // anything. Given top billing because it is the one place the
            // pipeline explains itself in its own words.
            VStack(alignment: .leading, spacing: 6) {
                TraceLabel("Thinking")
                Text(stage.reasoning)
                    .font(.subheadline)
                    .italic()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                    .textSelection(.enabled)
            }

            VStack(alignment: .leading, spacing: 6) {
                TraceLabel("Decision")
                switch stage.route {
                case .useTools:
                    Badge(text: "useTools", detail: "The shortlist answers this", tint: .green, icon: "iphone")
                case .sendToCloud:
                    Badge(text: "sendToCloud", detail: "No listed tool serves this", tint: .blue, icon: "cloud")
                }
            }

            if !stage.plannedCalls.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    TraceLabel("Plan, in execution order")
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

            // Plan vs. reality. Same list almost always; when it isn't,
            // the agent skipped or added a step, and that is the single
            // most useful thing this sheet can tell you.
            if stage.boundTools != stage.invocations.map(\.toolName) {
                Label(
                    "Planned: \(stage.boundTools.joined(separator: ", ")) — the agent did not run the plan exactly.",
                    systemImage: "arrow.triangle.branch"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }

            if stage.retriedForUnverifiedFigures {
                Label(
                    "The first draft showed a figure no tool returned. It was rejected and the answer regenerated from the tool output already in the session.",
                    systemImage: "checkmark.shield"
                )
                .font(.caption)
                .foregroundStyle(.orange)
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
