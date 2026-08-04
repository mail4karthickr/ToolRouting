import Foundation
import FoundationModels

// MARK: - Stage 2: LLM selection over the Stage-1 shortlist
//
// The LLM is the hybrid's RANKING stage, never a standalone router: it
// only ever sees the top-k tools that Stage 1 (MiniLM retrieval)
// surfaced for the current query, plus the explicit backend escalation
// option. Given that shortlist it does what similarity search can't:
// verb reasoning (lookup vs. action), multi-intent decomposition,
// dependency ordering, and parameter extraction.
//
// Keeping the candidate set small is the load-bearing design decision:
// LLM routing accuracy degrades as distractor tools pile into the
// instructions (attention dilution; ~20-tool practical ceiling), and on
// a ~3B model every schema costs context-window budget. With O(k)
// instructions per request, prompt size stays flat as the catalog grows.

@MainActor
final class LLMRouter {
    private let model = SystemLanguageModel.default

    // MARK: Generable output

    // Property order matters: guided generation emits fields in declaration
    // order, so `reasoning` comes first to give the model a chain-of-thought
    // step *before* it commits to the tool calls.
    // ToolName cases carry their parameters as associated values, so each
    // selected call arrives fully parameterized — no argument parsing.
    @Generable
    struct RoutingPlan {
        @Guide(description: "One-sentence explanation of which tool(s) or backend escalation the request needs and why")
        var reasoning: String

        @Guide(description: "The tools needed to satisfy the request, in execution order, each with its parameters extracted from the request. Use sendToBackend if a step requires an action or anything the listed tools don't cover. Use one call for simple requests; only add more when the request genuinely asks for multiple things.", .minimumCount(1), .maximumCount(4))
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

    // MARK: Prewarm

    func prewarm() {
        guard unavailabilityMessage == nil else { return }
        // Sessions are per-request (their instructions depend on the
        // query's shortlist), so instruction prefill can't be prewarmed.
        // Prewarming a blank session still pages the base model in — the
        // dominant cold-start cost.
        LanguageModelSession().prewarm()
    }

    // MARK: Selection

    /// Picks the tool call plan for `query` from the Stage-1 shortlist.
    /// A fresh session per request is what makes the routing dynamic:
    /// the candidate set is baked into the instructions, and with O(k)
    /// instructions there is no transcript worth carrying over, so no
    /// session rotation logic is needed either.
    func select(_ query: String, from candidates: [MiniLMRouter.RetrievedTool]) async throws -> RoutingPlan {
        let session = LanguageModelSession(instructions: makeInstructions(candidates: candidates))
        let response = try await session.respond(
            to: query,
            generating: RoutingPlan.self,
            includeSchemaInPrompt: false, // the schema lives in the instructions
            options: GenerationOptions(sampling: .greedy) // routing is classification; greedy makes it reproducible
        )
        return response.content
    }

    // MARK: Instructions (per request — only the shortlisted tools)

    /// Tool lines are generated from the catalog definitions so the
    /// prompt can never drift out of sync with the UI. Today's date is
    /// injected because the on-device model doesn't know it, and
    /// date-relative filters like "this week" need it.
    private func makeInstructions(candidates: [MiniLMRouter.RetrievedTool]) -> String {
        let toolLines = candidates
            .compactMap { ToolCatalog.byName[$0.toolName] }
            .map { tool in
                var line = "• \(tool.displayName) — \(tool.description) Not for: \(tool.notFor). Argument: \(tool.argumentHint)."
                if let example = tool.promptExample {
                    line += " Example: \"\(example)\" → \(tool.displayName)."
                }
                return line
            }
            .joined(separator: "\n")

        let today = Date.now.formatted(.iso8601.year().month().day())

        return """
            You are the on-device routing layer of a banking assistant. Decide which \
            app tools serve the user's request, extracting each argument directly \
            from the request. App tools are read-only lookups the app runs against \
            the bank's APIs; every lookup listed below is served in-app.

            A similarity search preselected the candidate tools below for this \
            request. Select ONLY from these candidates — no other app tool exists \
            for this request.

            Only sendToBackend handles the rest:
            • actions — anything that changes anything: transfers, payments, \
            blocking or freezing cards, raising disputes or limits, changing \
            settings, opening or closing accounts
            • anything the candidate tools below don't cover
            • human support or complaints

            The VERB decides, not the noun: showing, checking, or viewing anything \
            is a lookup; doing or changing anything is the backend. Checking a \
            limit, a dispute's status, or upcoming payments are lookups; raising \
            a limit, opening a dispute, or canceling a payment are backend. \
            Currency conversion QUESTIONS are lookups, served by convert_currency.

            IMPORTANT: If ANY part of the request requires the backend, route the \
            ENTIRE request as a single sendToBackend call with the full original \
            request as the argument. Otherwise serve EVERY part with app tools — \
            never escalate merely because a request has multiple parts.

            Most requests need exactly one call; use multiple only when the request \
            genuinely asks multiple things — one call per lookup, in execution \
            order, and one per period or item when the same lookup repeats (e.g. \
            statements for two months). Never emit two calls with the same tool \
            and argument.

            When a later tool needs an earlier tool's result, emit the calls in \
            dependency order with a placeholder argument naming the source: "find \
            the nearest ATM" → 1. get_location, 2. find_atm with location "current \
            location"; "my savings balance in euros" → 1. account_balance, \
            2. convert_currency with amount "from account_balance". When the user \
            already names the place or amount, skip the lookup and pass it directly.

            Today's date is \(today). Resolve relative dates like "this week" against it.

            Candidate tools:
            \(toolLines)

            Respond with a RoutingPlan matching this schema:
            \(Self.routingPlanSchemaJSON)
            """
    }

    // Serialized from the real schema, so it can never drift.
    private static let routingPlanSchemaJSON: String = {
        guard
            let data = try? JSONEncoder().encode(RoutingPlan.generationSchema),
            let json = String(data: data, encoding: .utf8)
        else { return "" }
        return json
    }()
}
