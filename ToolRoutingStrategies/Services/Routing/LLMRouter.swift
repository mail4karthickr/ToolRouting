import Foundation
import FoundationModels

// MARK: - Sample 1: LLM-based routing
//
// The LLM acts purely as the ROUTER: it receives the user query plus all
// tool descriptions and produces a structured output naming which tool(s)
// the query needs — it never executes them. Execution of the selected
// tools (via BankAPIClient) is a separate, later step.

@MainActor
final class LLMRouter: ToolRouter {
    let strategyName = "On-Device LLM Router"

    private let model = SystemLanguageModel.default

    /// The single long-lived session, reused across requests. Its KV
    /// cache is retained, so the instructions and schema are processed
    /// exactly once — each new request only pays for its own tokens.
    /// As a bonus, the accumulated transcript gives the router
    /// conversational context ("and what about savings?").
    /// Rotated (recreated) only when the transcript overflows the
    /// context window or a guardrail violation poisons the session.
    private var session: LanguageModelSession?

    // MARK: Generable output (private to this strategy)

    // Property order matters: guided generation emits fields in declaration
    // order, so `reasoning` comes first to give the model a chain-of-thought
    // step *before* it commits to the tool calls.
    // ToolName cases carry their parameters as associated values, so each
    // selected call arrives fully parameterized — no argument parsing.
    @Generable
    struct RoutingPlan {
        @Guide(description: "One-sentence explanation of which tool(s) or backend escalation the request needs and why")
        var reasoning: String

        @Guide(description: "The tools needed to satisfy the request, in execution order, each with its parameters extracted from the request. Use sendToBackend if a step requires an action or anything no local tool covers. Use one call for simple requests; only add more when the request genuinely asks for multiple things.", .minimumCount(1), .maximumCount(4))
        var calls: [ToolName]
    }

    // MARK: Availability

    var unavailabilityMessage: String? {
        switch model.availability {
        case .available:
            return nil
        case .unavailable(.deviceNotEligible):
            return "This device doesn't support Apple Intelligence. Requests will be handled by the backend."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Apple Intelligence is turned off. Requests will be handled by the backend."
        case .unavailable(.modelNotReady):
            return "The on-device model is still downloading. Requests will be handled by the backend."
        case .unavailable:
            return "The on-device model is unavailable. Requests will be handled by the backend."
        }
    }

    // MARK: Instructions

    /// Instructions are generated from the tool definitions so the prompt
    /// can never drift out of sync with the UI. Today's date is injected
    /// because the on-device model doesn't know it, and date-relative
    /// filters like "this week" need it.
    private func makeInstructions() -> String {
        // Tools are listed under category headers so the model can narrow
        // to a capability area before picking the specific tool — a
        // lightweight form of hierarchical routing.
        let toolLines = ToolCategory.allCases
            .compactMap { category -> String? in
                let tools = ToolCatalog.all.filter { $0.category == category }
                guard !tools.isEmpty else { return nil }

                let lines = tools.map { tool in
                    var line = "• \(tool.displayName) — \(tool.description) Do NOT use for \(tool.notFor). Argument: \(tool.argumentHint)."
                    if let example = tool.promptExample {
                        line += " Example: \"\(example)\" → \(tool.displayName)."
                    }
                    return line
                }

                return "\(category.rawValue):\n" + lines.joined(separator: "\n")
            }
            .joined(separator: "\n\n")

        let today = Date.now.formatted(.iso8601.year().month().day())

        return """
            You are the on-device routing layer of a banking assistant. Given a user \
            request, decide whether it can be served entirely by app tools, or must \
            go to the backend. Extract each argument directly from the request.

            App tools are read-only GET operations the app executes directly against \
            the bank's APIs, so they always return current data. Route a sub-task to \
            an app tool whenever it clearly matches that tool's purpose.

            A sub-task requires the backend when it:
            • performs an action or changes anything — transfers, payments, blocking or \
            freezing cards, raising disputes, changing settings, opening or closing accounts
            • asks about bank products or services no app tool covers (loan offers, \
            interest rates, application status)
            • asks for human support or raises a complaint
            • does not clearly match any app tool

            Prefer app tools: every read-only lookup listed below is served \
            in-app. Only choose send_to_backend when a part of the request \
            genuinely has no matching app tool — never just because the request \
            has multiple parts. The VERB decides, not the noun: showing, \
            checking, or viewing anything is an app tool; doing or changing \
            anything is the backend. Checking a limit is card_limits; raising \
            it is backend. Checking a dispute's status is dispute_status; \
            raising one is backend. Viewing scheduled or pending payments is \
            scheduled_payments or pending_payments; making or canceling one is \
            backend. Currency conversion questions are NOT actions: serve them \
            with convert_currency. Example: "What's my credit score and do I \
            have any pending payments?" → credit_score + pending_payments (two \
            app tool calls, no backend).

            IMPORTANT: If ANY part of the request requires the backend, route the ENTIRE \
            request as a single send_to_backend call with the full original request as \
            the argument — even if other parts could have been served by app tools. \
            Only produce app tool calls when EVERY sub-task is served by app tools.

            Most requests need exactly one call; use multiple app tool calls only when \
            the request genuinely contains multiple lookups, in the order they should \
            run. When the user asks for the same lookup over multiple periods or items \
            (e.g. statements for two months), emit one call per period or item. Write \
            arguments as plain text, and never emit two calls with the same tool and \
            argument.

            Some plans are multi-step chains where a later tool needs an earlier \
            tool's result. Emit the calls in dependency order and set the dependent \
            parameter to a short placeholder naming the source. Examples: "find the \
            nearest ATM" → 1. get_location, 2. find_atm with location "current \
            location"; "my savings balance in euros" → 1. account_balance for \
            savings, 2. convert_currency with amount "from account_balance" and \
            target "EUR". When the user already provides the value (a place name, \
            an amount), skip the lookup step and pass it directly.

            Today's date is \(today). Resolve relative dates like "this week" against it.

            App tools:
            \(toolLines)

            Respond with a RoutingPlan matching this schema:
            \(Self.routingPlanSchemaJSON)
            """
    }

    // The schema is baked into the instructions (instead of being injected
    // with the first prompt) so prewarm() covers its prefill cost too —
    // otherwise the FIRST request pays several hundred schema tokens.
    // Serialized from the real schema, so it can never drift.
    private static let routingPlanSchemaJSON: String = {
        guard
            let data = try? JSONEncoder().encode(RoutingPlan.generationSchema),
            let json = String(data: data, encoding: .utf8)
        else { return "" }
        return json
    }()

    // MARK: Routing

    private func activeSession() -> LanguageModelSession {
        if let session { return session }
        let fresh = LanguageModelSession(instructions: makeInstructions())
        fresh.prewarm()
        session = fresh
        return fresh
    }

    /// Creates the shared session ahead of the first request, hiding the
    /// model-load and instruction-prefill latency.
    func prewarm() {
        guard unavailabilityMessage == nil else { return }
        _ = activeSession()
    }

    func route(_ query: String) async throws -> RoutingResult {
        do {
            return try await respond(to: query)
        } catch let error as LanguageModelSession.GenerationError {
            if case .exceededContextWindowSize = error {
                // The accumulated transcript no longer fits the context
                // window — rotate to a fresh session and retry once.
                session = nil
                return try await respond(to: query)
            }
            if case .guardrailViolation = error {
                // A refused session can keep refusing follow-ups; rotate
                // so the next request starts clean, then surface the error.
                session = nil
            }
            throw error
        }
    }

    private func respond(to query: String) async throws -> RoutingResult {
        let session = activeSession()

        let response = try await session.respond(
            to: query,
            generating: RoutingPlan.self,
            includeSchemaInPrompt: false, // the schema lives in the instructions, prefilled by prewarm()
            options: GenerationOptions(sampling: .greedy) // routing is classification; greedy makes it reproducible
        )

        let plan = response.content

        // POLICY (enforced in code, not trusted to the model): GET-only
        // requests are served in-app; if ANY sub-task needs the backend,
        // the ENTIRE request goes to the backend so the server-side
        // assistant sees full context. The model detects; code decides.
        if plan.calls.contains(where: \.isSendToBackend) {
            return RoutingResult(
                strategyName: strategyName,
                reasoning: plan.reasoning,
                calls: [RoutedCall(tool: .sendToBackend(request: query), confidence: nil)]
            )
        }

        // Safety net: small on-device models sometimes repeat a call verbatim.
        // Instructions discourage it, but dedupe deterministically here too.
        var seen = Set<String>()
        let uniqueCalls = plan.calls.filter { seen.insert(String(describing: $0)).inserted }

        return RoutingResult(
            strategyName: strategyName,
            reasoning: plan.reasoning,
            calls: uniqueCalls.map {
                RoutedCall(tool: $0, confidence: nil)
            }
        )
    }
}
