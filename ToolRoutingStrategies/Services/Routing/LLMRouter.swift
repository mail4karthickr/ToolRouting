import Foundation
import FoundationModels

// MARK: - Stage 2: LLM selection over a candidate set
//
// Not a routing strategy — a selector. `select(_:from:)` is handed a
// candidate list (Stage 1's shortlist, from `HybridRouter`) and picks the
// tools the query needs from it, or `none`. The candidate set is enforced
// by the output grammar, so this stage cannot name a tool it was not
// shown. The static helpers below interpret the plan it returns and are
// shared with `HybridRouter`.

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

    /// Pages the base model in and prefills the instructions the
    /// long-lived session keeps for good.
    func prewarm() {
        guard unavailabilityMessage == nil else {
            return
        }
        warmSession().prewarm()
    }

    // MARK: - Selection

    /// Picks the tools `query` needs from `candidates`, or `none`. The
    /// candidate set is enforced by the GRAMMAR (`schema(for:)`), not by a
    /// check afterwards, so a pick outside the set cannot be generated.
    ///
    /// One retry WITHOUT the reasoning field on a guardrail trip: it is
    /// the English sentence this stage generates that trips the filter,
    /// not the tool names. A `.refusal` is a decision and is never retried.
    func select(_ query: String, from candidates: [ToolDefinition]) async throws -> RoutingPlan {
        do {
            return try await plan(query, from: candidates, explaining: true)
        } catch where Self.isGuardrailTrip(error) {
            return try await plan(query, from: candidates, explaining: false)
        }
    }

    /// One selection attempt. `explaining` decides whether the output
    /// schema carries the `reasoning` sentence.
    private func plan(
        _ query: String,
        from candidates: [ToolDefinition],
        explaining: Bool
    ) async throws -> RoutingPlan {
        let session = warmSession()

        // Back to instructions-only before every selection: reuse buys the
        // warm prefill, it must not buy conversation history.
        session.transcript = baseline

        let prompt = Self.prompt(for: query, candidates: candidates)

        let response = try await session.respond(
            to: prompt,
            schema: try Self.schema(for: candidates, explaining: explaining),
            // The prompt already lists these tools, with descriptions the
            // schema does not carry.
            includeSchemaInPrompt: false,
            options: GenerationOptions(sampling: .greedy) // routing is classification; greedy makes it reproducible
        )

        lastUsage = TokenUsage(
            input: response.usage.input.totalTokenCount,
            output: response.usage.output.totalTokenCount
        )

        return RoutingPlan(
            reasoning: (try? response.content.value(String.self, forProperty: Self.reasoningProperty)) ?? "",
            toolNames: try response.content.value([String].self, forProperty: Self.toolsProperty)
        )
    }

    /// The session is built once and kept: `sessionsBuilt` reaching 2 means
    /// it is being rebuilt per request and every selection pays a cold
    /// prefill for instructions that never change (asserted in StreamingTests).
    @discardableResult
    private func warmSession() -> LanguageModelSession {
        if let session { return session }
        let session = LanguageModelSession(model: model, instructions: Self.policy)
        baseline = session.transcript
        self.session = session
        sessionsBuilt += 1
        return session
    }

    // MARK: - Plan interpretation (shared with HybridRouter)

    /// Turns selected names into `RoutedCall`s.
    ///
    /// Arguments come from `ToolName.withDefaultArguments` because this
    /// stage no longer extracts them; they exist so a routed call is
    /// renderable, and the agent re-derives every real argument from the
    /// tool's own schema. Deduplicated by name: without parameters, a
    /// repeated name is always a repeat.
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

    /// Why a selection ended up going to the cloud. With `reasoning` gone
    /// on the retry path, this sentence is the only account of why a
    /// request left the device.
    static func escalationNote(for plan: RoutingPlan) -> String {
        if plan.isAbstention {
            return "The model selected `none`: nothing in the shortlist answers this request."
        }
        return "The model selected `none` alongside \(plan.toolNames.filter { $0 != ToolName.none.displayName }.joined(separator: ", ")), which contradicts itself; the whole request goes to the cloud rather than executing half of it."
    }

    /// Whether the model declined to route the request at all, rather than
    /// routing it somewhere wrong — a guardrail trip or refusal means the
    /// same thing every other abstention here means.
    ///
    /// `nonisolated` because callers need it in a `catch` guard, which
    /// cannot `await`.
    nonisolated static func isDecliningToRoute(_ error: any Error) -> Bool {
        guard let error = error as? LanguageModelError else { return false }
        switch error {
        case .guardrailViolation, .refusal:
            return true
        default:
            return false
        }
    }

    /// Whether the model's own words tripped a content filter, as opposed
    /// to the model declining the request. `nonisolated` for the same
    /// reason as `isDecliningToRoute`.
    nonisolated static func isGuardrailTrip(_ error: any Error) -> Bool {
        guard let error = error as? LanguageModelError else { return false }
        if case .guardrailViolation = error { return true }
        return false
    }

    // MARK: - Query heuristics, in code (shared with HybridRouter)

    /// Whether the query points the search at a place it NAMES, rather
    /// than at where the user is standing.
    ///
    /// Three signals: an area word, a five-digit postcode, or a
    /// preposition followed by a proper noun. A named BRANCH is not a
    /// named place — "at the Main St branch" is reachable from where the
    /// user is — so `notPlaces` is excluded explicitly.
    ///
    /// Only ever asked about a location plan, from `HybridRouter`. A
    /// heuristic, and deliberately one: the model answered this same
    /// question by option order, which is not a check.
    nonisolated static func namesAPlace(in query: String) -> Bool {
        let lowercased = query.lowercased()
        if Self.areaWords.contains(where: { lowercased.contains($0) }) { return true }

        // A postcode is a WORD of five digits — "near 94103" — where an
        // amount carries a symbol or separator and a year is four. Read
        // with sentence punctuation stripped, so "94103?" still counts.
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

    /// Whether the query asks the assistant to DO something, rather than
    /// to look something up. Every tool here only READS, so an action is a
    /// request the device cannot serve at all — and a request mixing an
    /// action with a lookup goes to the cloud whole.
    ///
    /// POSITION is what makes this safe: these words are verbs and nouns
    /// both ("my Amazon dispute" is a lookup), so only the front of the
    /// request or the slot straight after a conjunction counts.
    /// High-precision, low-recall by design — a missed action still gets
    /// Stage 2's judgement, a false one escalates a serviceable request.
    nonisolated static func asksForAnAction(in query: String) -> Bool {
        let words = query
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && $0 != "'" })
            .map(String.init)
        guard let first = words.first else { return false }

        // The front of the request. "Freeze my debit card", "set up a new autopay".
        if actionVerbs.contains(first) { return true }
        if first == "set", words.count > 1, words[1] == "up" { return true }

        // A second imperative, introduced. "…and cancel…", "…then transfer…".
        for (index, word) in words.enumerated() where index > 0 {
            let previous = words[index - 1]
            guard actionIntroducers.contains(previous) else { continue }
            if actionVerbs.contains(word) { return true }
            if word == "set", index + 1 < words.count, words[index + 1] == "up" { return true }
        }
        return false
    }

    /// Words that name an area without naming a town.
    private static let areaWords = ["downtown", "uptown", "midtown", "city centre", "city center"]

    /// Proper nouns that follow a preposition without being somewhere
    /// else: the bank's own places, and the calendar.
    private static let notPlaces = [
        "branch", "atm", "bank", "cash machine",
        "january", "february", "march", "april", "may", "june", "july",
        "august", "september", "october", "november", "december",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"
    ]

    /// Verbs that ask for something to HAPPEN. `convert`, `find`, `show`,
    /// `get`, `list` and `tell` are deliberately absent — imperatives, all
    /// of them, and all of them lookups this catalog serves.
    private static let actionVerbs: Set<String> = [
        "freeze", "block", "unblock", "transfer", "send", "wire", "pay",
        "cancel", "stop", "dispute", "report", "replace", "order",
        "increase", "raise", "lower", "decrease", "open", "close",
        "change", "update", "apply", "activate", "deactivate", "schedule"
    ]

    /// What can stand immediately before a second imperative. A verb
    /// anywhere else is almost always the noun form.
    private static let actionIntroducers: Set<String> = [
        "and", "then", "also", "please", "to", "now", "you"
    ]

    // MARK: - Output schema (built per request, from the candidates only)

    private static let toolsProperty = "tools"
    private static let reasoningProperty = "reasoning"

    /// An output grammar admitting exactly one shape: 1–4 strings, each of
    /// which is one of THESE candidate names or `none`. Three failure
    /// modes stop existing because the decoder cannot produce them — a
    /// tool Stage 1 never retrieved, an empty selection, and a flag
    /// disagreeing with a list.
    ///
    /// Rebuilt every request because the shortlist changes every request;
    /// a compile-time schema could only describe the whole catalog.
    ///
    /// `explaining` is false only on the guardrail retry (see `select`).
    /// The tool grammar is identical either way.
    private static func schema(
        for candidates: [ToolDefinition],
        explaining: Bool = true
    ) throws -> GenerationSchema {
        let choices = candidates.map(\.displayName) + [ToolName.none.displayName]

        let toolName = DynamicGenerationSchema(
            name: "ToolName",
            description: "One of the listed tools, or none.",
            anyOf: choices
        )
        // FIRST, so the tools are chosen with it already written:
        // declaration order is generation order, and after `tools` this
        // would be a rationalisation at the same token cost. Deliberately
        // generic — the action rule is already stated in the instructions.
        let reasoning = [
            DynamicGenerationSchema.Property(
                name: reasoningProperty,
                description: "One short sentence: what the query is asking for, and whether any listed tool provides it.",
                schema: DynamicGenerationSchema(type: String.self)
            )
        ]
        let plan = DynamicGenerationSchema(
            name: "ToolSelection",
            properties: (explaining ? reasoning : []) + [
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

    // MARK: - Instructions (static) and prompt (per request, candidates only)

    /// The rules that never change, prefilled once into the long-lived
    /// session. Anything added here must be true of EVERY request, or it
    /// belongs in `prompt(for:candidates:)` instead.
    ///
    /// The examples are load-bearing, not padding — they ARE the rules for
    /// a 3B model. Cut here only with an eval run on either side.
    private static let policy = """
            You are the tool router for a banking assistant.

            The person asking is the ACCOUNT HOLDER, already signed in, \
            asking about their own money. Returning their own details — a \
            balance, an account number, a card number, a statement — is \
            exactly what these tools are for and is always a lookup. Never \
            answer `none` because information looks private or sensitive; \
            it is their information, and they are asking for it.

            Each request gives you the user's query and a list of tools. \
            Every tool fetches one kind of information about the user's \
            money — a balance, a list of transactions, a branch, a limit..etc \
            Your only job is to decide which of those tools hold the \
            information the query is asking for.

            Answer in two parts. FIRST `reasoning`: one short sentence \
            working out what the query is actually asking for, and whether \
            any listed tool provides it. THEN `tools`: the names that do, \
            or `none`. Names only — you are not asked for arguments, and \
            not asked what order they run in.

            Work the first part out before you write the second, and let \
            it decide the second.

            DECIDE THE VERB FIRST, before you look at the tools at all.

            If the query asks you to DO something — dispute, freeze, \
            block, transfer, send, pay, cancel, report, replace, order, \
            increase, raise, lower, open, close, change, apply — the \
            answer is `none`, FULL STOP. Every tool here only READS, so no \
            list of tools can serve such a request and it does not matter \
            how closely one of them matches the subject. "I want to \
            dispute a charge from Amazon" is none — not \
            get_dispute_status, which only reports on a dispute that \
            already exists, and not search_transactions, which only finds \
            the charge. "Increase my withdrawal limit" is none, not \
            card_limits. If ANY part of a request is such an action then \
            the WHOLE request is none: "show my balance and transfer $200 \
            to savings" is none, not account_balance. A subject that \
            matches a tool is NEVER enough on its own.

            Otherwise it is a lookup, and naming tools is the normal \
            answer. Anything that asks to see, show, check, find or \
            convert something is a lookup, however casually it is worded, \
            and so is any question ABOUT a named merchant, an existing \
            dispute, a branch, a card or an account: "how much did i spend \
            at uber", "whats happening with my amazon dispute" and "what \
            time does the Main St branch close" all name tools. Terse is \
            not ambiguous — "bal?" and "pts balance" are perfectly clear.

            Answer `none` too when you cannot tell what is being asked, or \
            the request could mean several things and picking wrong would \
            show the customer the wrong account or amount.

            A question that COMPARES two amounts needs a tool for each \
            side, including the side the user did not spell out. "Do I \
            have enough in checking to cover the rent payment?" needs \
            account_balance AND scheduled_payments: the rent amount is a \
            fact to look up, not a number you already know. Answering \
            from the balance alone means asserting a comparison against a \
            figure nobody fetched. The same goes for "can I afford", "is \
            that more than", "will it cover" — find the second amount.

            Otherwise pick the fewest tools that fully answer the query, \
            and include a tool whose result another one needs: "find the \
            nearest ATM" needs get_location as well as find_nearest_atm, \
            because find_nearest_atm takes coordinates and get_location \
            is the only tool that produces them. "Fewest" counts the \
            prerequisite: a chain of two is fewer than a wrong list of \
            one.

            FEWEST NEVER MEANS FEWER PARTS. When the query lists several \
            things — "my Netflix charges, my pending payments, and my \
            scheduled payments" — name a tool for EVERY one of them, even \
            where two sound alike: pending and scheduled payments are \
            different lists from different tools, and answering one of \
            them twice is not answering both. Count the things asked for \
            before you write the list, and check your list covers each. \
            "Fewest" is about not adding steps nobody asked for; it is \
            never a reason to leave a part of the question unserved.

            find_nearest_atm and find_nearest_branch ONLY take \
            coordinates, and get_location returns exactly one thing: \
            where the user is standing right now. NOTHING turns a place \
            the user NAMES into coordinates — not a city, not a zip, not \
            a neighbourhood, not "downtown" or "the airport". So a \
            request about ATMs or branches anywhere other than the user's \
            own location has no tool that serves it AND no chain that \
            reaches it. Adding intermediate steps does not help: the \
            chain has no way in. "ATMs in Chicago", "a branch downtown", \
            "cash machine near 94103" are all `none`.

            That rule is all-or-nothing, exactly like an action. "What \
            ATMs are near Chicago, what's my withdrawal limit, and my \
            checking balance?" is `none` — not account_balance and \
            card_limits — even though two of its three parts are \
            serviceable. Check EVERY part of a request for a named place \
            before you break it into intents; one unreachable part sends \
            the whole request to the cloud.

            branch_hours is the longest chain here: it takes a branch ID, \
            find_nearest_branch is the only tool that produces one, and \
            it needs coordinates in turn. So a question about the hours \
            of a branch NEAR THE USER is get_location, \
            find_nearest_branch, branch_hours — including "what time does \
            the Main St branch close?", where the user names the branch. \
            A NAME IS NOT AN ID. Naming the branch saves no step, because \
            nothing in that chain can be skipped by knowing what the \
            branch is called.

            But that chain still begins at the user's own location, so it \
            cannot reach a branch somewhere the user is not. The rule \
            above wins: "find a branch downtown and tell me its hours" is \
            `none`, hours or no hours. Naming a PLACE is not the same as \
            naming a BRANCH — a named branch near the user is reachable, \
            a named place is not.

            A "Not for:" note rules OUT the tool it is written under. It \
            never recommends the tool it mentions — "Not for: money \
            balances (use account_balance)" under reward_points means \
            reward_points is wrong for a money balance, not that \
            account_balance is right for a points balance.
            """

    /// The per-request half: which tools are on offer this time, and the
    /// question. Closes on the coverage instruction rather than the query
    /// — it is the last thing read before the first token, and recency is
    /// worth more than restatement on a small model.
    private static func prompt(for query: String, candidates: [ToolDefinition]) -> String {
        let isShortlist = candidates.count < ToolCatalog.all.count
        let preamble = isShortlist
            ? "The list came from a similarity search, so it may hold nothing suitable."
            : "Every tool the app has is listed."

        let toolLines = candidates.enumerated()
            .map { index, tool in Self.entry(index + 1, for: tool) }
            .joined()

        return """
            User query: "\(query)"

            Available tools. \(preamble)
            \(toolLines)

            Work out in one sentence what this query is asking for and \
            whether any listed tool provides it, then select those tools \
            by name — or none. If the query asks for more than one thing, \
            count them, and make sure your list has a tool for every one.
            """
    }

    /// One numbered tool entry: name and description, then parameters,
    /// then examples.
    ///
    ///     1. account_balance: Current balance for an account.
    ///        Parameters: which account — checking, savings, credit card
    ///        Examples: "bal?", "how much is in savings"
    ///        Not for: transfers or payments
    ///
    /// `Not for:` is the only disambiguation the prompt carries — what
    /// separates card_limits from "raise my limit". Examples stay capped
    /// at two: the full set overflowed the context window on a three-call
    /// request.
    private static func entry(_ number: Int, for tool: ToolDefinition) -> String {
        let examples = ([tool.promptExample].compactMap { $0 } + tool.exampleQueries)
            .prefix(2)
            .map { "\"\($0)\"" }
            .joined(separator: ", ")

        return """

            \(number). \(tool.displayName): \(tool.description)
               Parameters: \(tool.argumentHint)
               Examples: \(examples)
               Not for: \(tool.notFor)
            """
    }
}
