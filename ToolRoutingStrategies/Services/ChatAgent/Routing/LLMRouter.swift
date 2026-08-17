import Foundation
import FoundationModels

@MainActor
final class LLMRouter {
    private let model = SystemLanguageModel(
        useCase: .general,
        guardrails: .permissiveContentTransformations
    )

    private var session: LanguageModelSession?
    private var baseline = Transcript()
    private(set) var sessionsBuilt = 0
    private(set) var lastUsage: TokenUsage?

    struct RoutingPlan {
        let reasoning: String
        let toolNames: [String]

        var isAbstention: Bool {
            toolNames.allSatisfy { $0 == ToolName.none.displayName }
        }
    }

    struct TokenUsage {
        let input: Int
        let output: Int
    }

    // MARK: - Availability

    var unavailabilityMessage: String? {
        switch model.availability {
        case .available:
            return nil
        case .unavailable(.deviceNotEligible):
            return "This device doesn't support Apple Intelligence. Requests will be handled by the cloud model."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Apple Intelligence is turned off. Requests will be handled by the cloud model."
        case .unavailable(.modelNotReady):
            return "The on-device model is still downloading. Requests will be handled by the cloud model."
        case .unavailable:
            return "The on-device model is unavailable. Requests will be handled by the cloud model."
        }
    }

    // MARK: - Prewarm

    func prewarm() {
        guard unavailabilityMessage == nil else {
            return
        }
        warmSession().prewarm()
    }

    // MARK: - Selection

    /// `reasoning` is always part of the schema: the model works out what the
    /// query asks for before it names a tool, and that ordering is what makes
    /// the selection accurate. A guardrail trip is therefore not retried
    /// without it — a pick made blind is worth less than an escalation, and
    /// the caller already treats a thrown refusal as a route to the cloud.
    func select(_ query: String, from candidates: [ToolDefinition]) async throws -> RoutingPlan {
        let session = warmSession()
        session.transcript = baseline

        let response = try await session.respond(
            to: RouterPrompt.request(for: query, candidates: candidates),
            schema: try Self.schema(for: candidates),
            includeSchemaInPrompt: false,
            options: GenerationOptions(sampling: .greedy)
        )

        lastUsage = TokenUsage(
            input: response.usage.input.totalTokenCount,
            output: response.usage.output.totalTokenCount
        )

        return RoutingPlan(
            reasoning: try response.content.value(String.self, forProperty: Self.reasoningProperty),
            toolNames: try response.content.value([String].self, forProperty: Self.toolsProperty)
        )
    }

    @discardableResult
    private func warmSession() -> LanguageModelSession {
        if let session { return session }
        let session = LanguageModelSession(model: model, instructions: RouterPrompt.system)
        baseline = session.transcript
        self.session = session
        sessionsBuilt += 1
        return session
    }

    // MARK: - Plan interpretation

    static func routedCalls(
        for plan: RoutingPlan,
        query: String,
        scores: [String: Double]
    ) -> [RoutedCall] {
        var seen = Set<String>()
        return plan.toolNames
            .filter { $0 != ToolName.none.displayName && seen.insert($0).inserted }
            .compactMap { name in
                ToolName.withDefaultArguments(named: name, query: query)
                    .map { RoutedCall(tool: $0, confidence: scores[name]) }
            }
    }

    static func escalationNote(for plan: RoutingPlan) -> String {
        if plan.isAbstention {
            return "The model selected `none`: nothing in the shortlist answers this request."
        }
        return "The model selected `none` alongside \(plan.toolNames.filter { $0 != ToolName.none.displayName }.joined(separator: ", ")), which contradicts itself; the whole request goes to the cloud rather than executing half of it."
    }

    nonisolated static func isDecliningToRoute(_ error: any Error) -> Bool {
        guard let error = error as? LanguageModelError else { return false }
        switch error {
        case .guardrailViolation, .refusal:
            return true
        default:
            return false
        }
    }

    // MARK: - Query heuristics

    nonisolated static func namesAPlace(in query: String) -> Bool {
        let lowercased = query.lowercased()
        if Self.areaWords.contains(where: { lowercased.contains($0) }) { return true }

        let words = query.split(whereSeparator: \.isWhitespace)
        if words.contains(where: { word in
            let bare = word.trimmingCharacters(in: CharacterSet(charactersIn: ".,?!;:()"))
            return bare.count == 5 && bare.allSatisfy(\.isNumber)
        }) {
            return true
        }

        for match in query.matches(of: /\b(?:in|near|around|close to|by)\s+(?:the\s+)?([A-Z][\w'’-]+(?:\s+[A-Z][\w'’-]+)*)/) {
            let named = String(match.output.1).lowercased()
            if Self.notPlaces.contains(where: { named.contains($0) }) { continue }
            return true
        }
        return false
    }

    nonisolated static func asksForAnAction(in query: String) -> Bool {
        let words = query
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && $0 != "'" })
            .map(String.init)
        guard let first = words.first else { return false }

        if actionVerbs.contains(first) { return true }
        if first == "set", words.count > 1, words[1] == "up" { return true }

        for (index, word) in words.enumerated() where index > 0 {
            let previous = words[index - 1]
            guard actionIntroducers.contains(previous) else { continue }
            if actionVerbs.contains(word) { return true }
            if word == "set", index + 1 < words.count, words[index + 1] == "up" { return true }
        }
        return false
    }

    private static let areaWords = ["downtown", "uptown", "midtown", "city centre", "city center"]

    private static let notPlaces = [
        "branch", "atm", "bank", "cash machine",
        "january", "february", "march", "april", "may", "june", "july",
        "august", "september", "october", "november", "december",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"
    ]

    private static let actionVerbs: Set<String> = [
        "freeze", "block", "unblock", "transfer", "send", "wire", "pay",
        "cancel", "stop", "dispute", "report", "replace", "order",
        "increase", "raise", "lower", "decrease", "open", "close",
        "change", "update", "apply", "activate", "deactivate", "schedule"
    ]

    private static let actionIntroducers: Set<String> = [
        "and", "then", "also", "please", "to", "now", "you"
    ]

    // MARK: - Output schema

    private static let toolsProperty = "tools"
    private static let reasoningProperty = "reasoning"

    private static func schema(for candidates: [ToolDefinition]) throws -> GenerationSchema {
        let choices = candidates.map(\.displayName) + [ToolName.none.displayName]

        let toolName = DynamicGenerationSchema(
            name: "ToolName",
            description: "One of the listed tools, or none.",
            anyOf: choices
        )
        // Property order is the point: guided generation fills them in the
        // order given, so the reasoning is already in context by the time the
        // tool names are decoded. Reversed, it would be a rationalisation of a
        // choice already made.
        let plan = DynamicGenerationSchema(
            name: "ToolSelection",
            properties: [
                DynamicGenerationSchema.Property(
                    name: reasoningProperty,
                    description: "One short sentence: what the query is asking for, and whether any listed tool provides it. If no listed tool provides it — or covers only part of it — say so, and answer none for the whole request.",
                    schema: DynamicGenerationSchema(type: String.self)
                ),
                DynamicGenerationSchema.Property(
                    name: toolsProperty,
                    description: "The tools needed for the query, or a single entry of none.",
                    schema: DynamicGenerationSchema(
                        arrayOf: DynamicGenerationSchema(referenceTo: "ToolName"),
                        minimumElements: 1,
                        maximumElements: 4
                    )
                )
            ]
        )
        return try GenerationSchema(root: plan, dependencies: [toolName])
    }
}
