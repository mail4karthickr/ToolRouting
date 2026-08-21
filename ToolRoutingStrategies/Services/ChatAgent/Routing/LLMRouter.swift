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
        let named = plan.toolNames
            .filter { $0 != ToolName.none.displayName && seen.insert($0).inserted }
        // Completed before it is executed. A prerequisite the router left
        // out is not a smaller plan, it is a broken one — branch_hours
        // without find_nearest_branch gets an ID it was never given. The
        // dependency is declared on the tool; this is where it is applied.
        return ToolCatalog.closure(over: named)
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

    /// WHICH of the two declines it was, and whatever the framework said
    /// about it.
    ///
    /// `isDecliningToRoute` treats them identically because the routing
    /// decision is the same either way — the request goes to the cloud.
    /// The CAUSES are not: a guardrail violation is the safety filter
    /// firing on content, a refusal is the model declining the request
    /// itself. The trace said "a guardrail or refusal" for both, and on
    /// 2026-08-19 that ambiguity cost an afternoon — the answer turned out
    /// to be `refusal — May contain sensitive content` on two lookups the
    /// account holder is entitled to, which is a prompt problem and not a
    /// filter problem. Worth one line to never guess again.
    nonisolated static func declineReason(_ error: any Error) -> String? {
        guard let error = error as? LanguageModelError else { return nil }
        switch error {
        case .guardrailViolation(let violation):
            return "guardrail violation — \(violation.debugDescription)"
        case .refusal(let refusal):
            return "refusal — \(refusal.debugDescription)"
        default:
            return nil
        }
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
                    // NOTHING HERE MENTIONS calculator, AND THAT IS
                    // DELIBERATE — two attempts did, and both made it
                    // worse. Naming it as a tool the reasoning should
                    // reach for got it selected and `search_transactions`
                    // dropped: the reasoning said it needed "a date range
                    // to filter transactions and a sum", then named no
                    // tool to filter transactions. Removing the mention
                    // got it omitted instead, and a total came back as a
                    // list of figures.
                    //
                    // WHAT IS LEFT IS AN OPEN PROBLEM, not a solution.
                    // MEASURED on spending_chain_qa: calculator is
                    // retrieved for every spending prompt, at rank 1 to 3,
                    // and this step selects it on four of six — declining
                    // it on "how much did i spnd at walmart last mnth"
                    // where it sat at RANK 1. Position is not the lever
                    // and neither is wording. The two candidate fixes are
                    // binding calculator at execution as a fallback, and
                    // making this property enumerate what the query asks
                    // for rather than describe it in prose, so a total has
                    // a slot it cannot skip.
                    description: "Step by step and briefly: name each separate piece of information the query needs, then for each piece name which tool(s) actually provide it — not just the first one that sounds related. A piece with no tool that fully provides it means the WHOLE request is `none`.",
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
