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
