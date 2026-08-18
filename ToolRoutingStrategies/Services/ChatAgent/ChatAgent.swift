import Foundation
import FoundationModels

@MainActor
final class ChatAgent {
    let strategyName = "Hybrid Router (MiniLM → LLM)"

    struct Config {
        var topK: Int = 5
    }

    private let retriever = MiniLMRouter()
    private let selector = LLMRouter()
    private let client: any BankAPIClient
    private let config = Config()

    private static let model = SystemLanguageModel(
        useCase: .general,
        guardrails: .permissiveContentTransformations
    )

    private var history: [Transcript.Entry] = []
    private static let historyEntryLimit = 12
    private(set) var sessionsBuilt = 0

    init(client: any BankAPIClient = MockBankAPIClient()) {
        self.client = client
    }

    // MARK: - Lifecycle

    var unavailabilityMessage: String? { selector.unavailabilityMessage }

    func prewarm() {
        retriever.prewarm()
        selector.prewarm()
        LanguageModelSession(model: Self.model).prewarm()
    }

    func clearHistory() {
        history.removeAll()
    }

    // MARK: - The turn

    func route(
        _ query: String,
        onUpdate: (RoutingUpdate) -> Void = { _ in }
    ) async throws -> RoutingResult {
        var trace = RoutingTrace()
        let clock = ContinuousClock()

        onUpdate(.retrieving)
        let retrievalStart = clock.now
        let retrieval = try await retriever.rank(query, topK: config.topK)
        let shortlist = retrieval.shortlist
        trace.retrieval = stage(from: retrieval, duration: clock.now - retrievalStart)

        guard !shortlist.isEmpty else {
            return RoutingResult(
                strategyName: strategyName,
                reasoning: "No tool cleared the similarity threshold; the LLM stage was skipped.",
                calls: [],
                trace: trace
            )
        }

        let candidateTools = shortlist.compactMap { ToolCatalog.byName[$0.toolName] }
        onUpdate(.selecting)
        let selectionStart = clock.now
        let plan: LLMRouter.RoutingPlan
        do {
            plan = try await selector.select(query, from: candidateTools)
        } catch where LLMRouter.isDecliningToRoute(error) {
            trace.selection = RoutingTrace.SelectionStage(
                candidates: candidateTools.map(\.displayName),
                reasoning: nil,
                route: .noMatch,
                plannedCalls: [],
                policyNotes: [
                    "The on-device model declined to route this request — a guardrail or refusal. Treated as an escalation, exactly like an explicit `none`, rather than surfaced as an error."
                ],
                promptTokens: nil,
                outputTokens: nil,
                duration: clock.now - selectionStart
            )
            return RoutingResult(
                strategyName: strategyName,
                reasoning: "The on-device model declined to route this request; answering with the cloud model.",
                calls: [RoutedCall(tool: ToolName.none, confidence: nil)],
                trace: trace
            )
        }
        let selectionDuration = clock.now - selectionStart
        let selectionUsage = selector.lastUsage

        func recordSelection(_ notes: [String]) {
            trace.selection = RoutingTrace.SelectionStage(
                candidates: candidateTools.map(\.displayName),
                reasoning: plan.reasoning.isEmpty ? nil : plan.reasoning,
                route: plan.toolNames.contains(ToolName.none.displayName) ? .noMatch : .useTools,
                plannedCalls: plan.toolNames.map {
                    RoutingTrace.SelectionStage.PlannedCall(toolName: $0, arguments: nil)
                },
                policyNotes: notes,
                promptTokens: selectionUsage?.input,
                outputTokens: selectionUsage?.output,
                duration: selectionDuration
            )
        }

        guard !plan.toolNames.contains(ToolName.none.displayName) else {
            recordSelection([LLMRouter.escalationNote(for: plan)])
            return RoutingResult(
                strategyName: strategyName,
                reasoning: [plan.reasoning, LLMRouter.escalationNote(for: plan)]
                    .filter { !$0.isEmpty }
                    .joined(separator: " · "),
                calls: [RoutedCall(tool: ToolName.none, confidence: nil)],
                trace: trace
            )
        }

        let scoreByTool = Dictionary(shortlist.map { ($0.toolName, Double($0.score)) }, uniquingKeysWith: max)
        let routedCalls = LLMRouter.routedCalls(for: plan, query: query, scores: scoreByTool)

        let duplicates = plan.toolNames.count - routedCalls.count
        recordSelection(duplicates > 0
            ? ["Dropped \(duplicates) tool\(duplicates == 1 ? "" : "s") the model named twice."]
            : [])

        let uniqueCalls = routedCalls.map(\.tool)
        let boundTools = uniqueCalls.map(\.displayName).filter { $0 != ToolName.none.displayName }
        onUpdate(.answering)
        let executionStart = clock.now
        do {
            let answer = try await answer(query, using: uniqueCalls, onUpdate: onUpdate)
            trace.execution = RoutingTrace.ExecutionStage(
                boundTools: boundTools,
                invocations: answer.invocations,
                answer: answer.text,
                failure: nil,
                timeToFirstToken: answer.timeToFirstToken,
                promptTokens: answer.promptTokens,
                duration: clock.now - executionStart
            )
            return RoutingResult(
                strategyName: strategyName,
                reasoning: plan.reasoning.isEmpty ? nil : plan.reasoning,
                calls: routedCalls,
                answer: answer.text,
                executedTools: answer.executedTools,
                trace: trace
            )
        } catch {
            trace.execution = RoutingTrace.ExecutionStage(
                boundTools: boundTools,
                invocations: [],
                answer: nil,
                failure: (error as? LocalizedError)?.errorDescription ?? "\(error)",
                timeToFirstToken: nil,
                promptTokens: nil,
                duration: clock.now - executionStart
            )
            return RoutingResult(
                strategyName: strategyName,
                reasoning: "Agent failed: \(error)",
                calls: routedCalls,
                trace: trace
            )
        }
    }

    private func stage(
        from retrieval: MiniLMRouter.Retrieval,
        duration: Duration
    ) -> RoutingTrace.RetrievalStage {
        let shortlisted = Set(retrieval.shortlist.map(\.toolName))
        return RoutingTrace.RetrievalStage(
            topK: config.topK,
            threshold: Double(retriever.similarityThreshold),
            ranked: retrieval.ranked.map {
                RoutingTrace.RetrievalStage.Candidate(
                    toolName: $0.toolName,
                    score: Double($0.score),
                    isShortlisted: shortlisted.contains($0.toolName)
                )
            },
            duration: duration
        )
    }

    // MARK: - Answering

    struct Answer {
        let text: String
        let executedTools: [String]
        let invocations: [RoutingTrace.ExecutionStage.Invocation]
        let transcript: Transcript
        let timeToFirstToken: Duration?
        let promptTokens: Int?
    }

    enum AgentError: LocalizedError {
        case noExecutableTools([String])
        case emptyReply(plan: [String], executed: [String])

        var errorDescription: String? {
            switch self {
            case .noExecutableTools(let names):
                "No executable tool for: \(names.joined(separator: ", "))."
            case .emptyReply(let plan, let executed):
                """
                Model returned an empty reply. Planned \(plan.joined(separator: ", ")); \
                called \(executed.isEmpty ? "nothing" : executed.joined(separator: ", ")).
                """
            }
        }
    }

    func answer(
        _ query: String,
        using plan: [ToolName],
        onUpdate: (RoutingUpdate) -> Void = { _ in }
    ) async throws -> Answer {
        let names = plan.map(\.displayName).filter { $0 != ToolName.none.displayName }
        let tools = names.compactMap { BankToolRegistry.tool(named: $0, client: client) }

        guard !tools.isEmpty else {
            throw AgentError.noExecutableTools(names)
        }

        let runnable = names.filter { BankToolRegistry.tool(named: $0, client: client) != nil }
        let session = makeSession(for: runnable, tools: tools)
        var answer = try await respond(in: session, to: query, onUpdate: onUpdate)

        var repairPrompt: String?
        let missing = runnable.filter { !answer.executedTools.contains($0) }
        if !missing.isEmpty {
            let prompt = AgentPrompt.repair(for: query, missing: missing)
            repairPrompt = prompt
            let repaired = try await respond(
                in: session,
                to: prompt,
                onUpdate: onUpdate,
                timeToFirstToken: answer.timeToFirstToken
            )
            answer = repaired.text.isEmpty ? answer : repaired
        }

        remember(session.transcript, discarding: repairPrompt)
        return answer
    }

    private func respond(
        in session: LanguageModelSession,
        to query: String,
        onUpdate: (RoutingUpdate) -> Void,
        timeToFirstToken carriedTimeToFirstToken: Duration? = nil
    ) async throws -> Answer {
        let clock = ContinuousClock()
        let start = clock.now
        var timeToFirstToken: Duration?
        var text = ""
        var promptTokens: Int?

        let stream = session.streamResponse(
            to: query,
            options: GenerationOptions(temperature: 0.3)
        )

        for try await snapshot in stream {
            promptTokens = snapshot.usage.input.totalTokenCount

            let partial = snapshot.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !partial.isEmpty else { continue }

            if timeToFirstToken == nil {
                timeToFirstToken = clock.now - start
            }
            text = partial
            onUpdate(.answerPartial(partial))
        }

        let invocations = Self.invocations(in: session.transcript)
        return Answer(
            text: text,
            executedTools: invocations.map(\.toolName),
            invocations: invocations,
            transcript: session.transcript,
            timeToFirstToken: carriedTimeToFirstToken ?? timeToFirstToken,
            promptTokens: promptTokens
        )
    }

    private func makeSession(for names: [String], tools: [any Tool]) -> LanguageModelSession {
        let instructions = Transcript.Instructions(
            segments: [.text(Transcript.TextSegment(content: AgentPrompt.system(for: names)))],
            toolDefinitions: tools.map { Transcript.ToolDefinition(tool: $0) }
        )
        sessionsBuilt += 1
        return LanguageModelSession(
            model: Self.model,
            tools: tools,
            transcript: Transcript(entries: [.instructions(instructions)] + history)
        )
    }

    private func remember(_ transcript: Transcript, discarding repairPrompt: String? = nil) {
        var kept: [Transcript.Entry] = []
        for entry in transcript {
            switch entry {
            case .prompt(let prompt):
                let text = prompt.segments
                    .compactMap { if case .text(let text) = $0 { text.content } else { nil } }
                    .joined(separator: " ")
                guard text != repairPrompt else {
                    if case .response = kept.last { kept.removeLast() }
                    continue
                }
                kept.append(entry)
            case .response:
                kept.append(entry)
            case .instructions, .toolCalls, .toolOutput:
                continue
            default:
                continue
            }
        }
        history += kept
        if history.count > Self.historyEntryLimit {
            history.removeFirst(history.count - Self.historyEntryLimit)
        }
    }

    // MARK: - Transcript

    private static func invocations(in transcript: Transcript) -> [RoutingTrace.ExecutionStage.Invocation] {
        var pendingOutputs: [String: [String]] = [:]
        for entry in transcript {
            guard case .toolOutput(let output) = entry else { continue }
            let text = output.segments
                .compactMap { segment -> String? in
                    guard case .text(let text) = segment else { return nil }
                    return text.content
                }
                .joined(separator: "\n")
            pendingOutputs[output.toolName, default: []].append(text)
        }

        var invocations: [RoutingTrace.ExecutionStage.Invocation] = []
        for entry in transcript {
            guard case .toolCalls(let calls) = entry else { continue }
            for call in calls {
                var output: String?
                if pendingOutputs[call.toolName]?.isEmpty == false {
                    output = pendingOutputs[call.toolName]?.removeFirst()
                }
                invocations.append(
                    RoutingTrace.ExecutionStage.Invocation(
                        toolName: call.toolName,
                        arguments: Self.describe(call.arguments),
                        output: output
                    )
                )
            }
        }
        return invocations
    }

    private static func describe(_ arguments: GeneratedContent) -> String? {
        let text = String(describing: arguments)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: " ")
        return text.isEmpty || text == "{}" ? nil : text
    }
}
