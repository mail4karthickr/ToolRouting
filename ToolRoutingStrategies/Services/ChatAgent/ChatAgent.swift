import Foundation
import FoundationModels

// MARK: - ChatAgent
//
// One question in, one answer out. Three stages, in order:
//
//   Stage 1  MiniLMRouter.rank    — embedding similarity narrows the full
//                                   catalog to a top-k shortlist.
//   Stage 2  LLMRouter.select     — the LLM, seeing ONLY those k tools,
//                                   picks the ones the query needs, or
//                                   `none`.
//   Policy   Enforced here in code, never trusted to the model: `none`
//            collapse, action requests, named places, dedupe.
//   Stage 3  answer(_:using:)     — binds ONLY the selected tools to a
//                                   session, runs them, and writes the
//                                   sentence the user reads.
//
// `none` is the escalation signal: a plan of tools runs entirely on
// device, while `none` hands the request to the cloud model.
//
// The agent keeps the CONVERSATION across turns and rebuilds the SESSION
// every turn. A session's tools are fixed at `init` and the routed plan
// changes every turn, so binding wins: what the model can call is exactly
// what routing selected, and history rides along in the transcript.

@MainActor
final class ChatAgent {
    let strategyName = "Hybrid Router (MiniLM → LLM)"

    struct Config {
        /// Shortlist size handed to the LLM. k = 5 buys one spare slot on
        /// the four-tool samples; the cost is one more tool description in
        /// every Stage-2 prompt.
        var topK: Int = 5
    }

    /// Stage 1.
    private let retriever = MiniLMRouter()
    /// Stage 2.
    private let selector = LLMRouter()
    private let client: any BankAPIClient
    private let config = Config()

    /// The same permissive-guardrail model Stage 2 selects with. Both
    /// stages or neither: relaxing only the first would move the silence
    /// one stage later, with the tool output already fetched.
    private static let model = SystemLanguageModel(
        useCase: .general,
        guardrails: .permissiveContentTransformations
    )

    /// The conversation so far, as `.prompt` and `.response` entries only.
    /// Tool calls and outputs are dropped on purpose — carrying them would
    /// put last turn's figures back in context to be restated as fresh.
    private var history: [Transcript.Entry] = []

    /// Six exchanges. A cap, not a memory policy: the window is ~4,096
    /// tokens shared with the instructions, the tool schemas, and this
    /// turn's output.
    private static let historyEntryLimit = 12

    /// One session per request, by design. The counter is the tripwire
    /// that would catch someone making it persistent again.
    private(set) var sessionsBuilt = 0

    init(client: any BankAPIClient = MockBankAPIClient()) {
        self.client = client
    }

    // MARK: - Lifecycle

    var unavailabilityMessage: String? { selector.unavailabilityMessage }

    /// Called when the chat screen appears. Every stage builds whatever it
    /// keeps for the app's lifetime here, so no request pays for it.
    ///
    /// Stage 3 has nothing to prewarm beyond the weights: its instructions
    /// name the routed tools, which aren't known until Stage 2 has run.
    func prewarm() {
        retriever.prewarm() // MiniLM weights + tool index
        selector.prewarm()  // base LLM weights + the selection session
        LanguageModelSession(model: Self.model).prewarm()
    }

    /// Forgets the conversation. For a "new chat" affordance, and for
    /// tests that need a clean agent without building a new one.
    func clearHistory() {
        history.removeAll()
    }

    // MARK: - The turn

    /// Run the pipeline, report nothing. This is what the evals call, and
    /// it is the streaming path with the updates discarded rather than a
    /// second implementation.
    func route(_ query: String) async throws -> RoutingResult {
        try await route(query, onUpdate: { _ in })
    }

    /// The same run, reporting where it is as it goes.
    ///
    /// `onUpdate` is non-escaping and called on this actor, so the UI can
    /// assign to its own state inside the handler with no hop.
    func route(_ query: String, onUpdate: (RoutingUpdate) -> Void) async throws -> RoutingResult {
        // Every stage is recorded into `trace` as it completes, so an early
        // return still carries the account of everything that ran before it.
        var trace = RoutingTrace()
        let clock = ContinuousClock()

        // Stage 1 — retrieval. Milliseconds, no generation. The only stage
        // that can fail outright (no index, or weights never downloaded),
        // and it throws to the view model.
        onUpdate(.retrieving)
        let retrievalStart = clock.now
        let retrieval = try await retriever.rank(query, topK: config.topK)
        let shortlist = retrieval.shortlist
        trace.retrieval = stage(from: retrieval, duration: clock.now - retrievalStart)

        // Abstention door #1 (cheap): nothing cleared the similarity
        // threshold, so the LLM never runs.
        guard !shortlist.isEmpty else {
            return RoutingResult(
                strategyName: strategyName,
                reasoning: "No tool cleared the similarity threshold; the LLM stage was skipped.",
                calls: [],
                trace: trace
            )
        }

        // Stage 2 — LLM selection over ONLY the shortlist. Retrieval
        // returns names; the selector wants the definitions whose text goes
        // in the prompt.
        let candidateTools = shortlist.compactMap { ToolCatalog.byName[$0.toolName] }
        onUpdate(.selecting)
        let selectionStart = clock.now
        let plan: LLMRouter.RoutingPlan
        do {
            plan = try await selector.select(query, from: candidateTools)
        } catch where LLMRouter.isDecliningToRoute(error) {
            // A guardrail trip or refusal is the model declining to route
            // at all — the same outcome as `none`, so it is handled here
            // rather than thrown. No token usage recorded: `lastUsage`
            // still holds the previous request's numbers when a call throws.
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
        // Read with no suspension between this and the call above, so it
        // cannot belong to a different request.
        let selectionUsage = selector.lastUsage

        // Records Stage 2 with whatever policy fired on it. Policy notes
        // are the bridge between the model's output and the result: a plan
        // that looked fine and still went to the cloud has its reason here.
        func recordSelection(_ notes: [String]) {
            trace.selection = RoutingTrace.SelectionStage(
                candidates: candidateTools.map(\.displayName),
                reasoning: plan.reasoning.isEmpty ? nil : plan.reasoning,
                route: plan.toolNames.contains(ToolName.none.displayName) ? .noMatch : .useTools,
                plannedCalls: plan.toolNames.map {
                    // No arguments: Stage 2 selects names and nothing else.
                    RoutingTrace.SelectionStage.PlannedCall(toolName: $0, arguments: nil)
                },
                policyNotes: notes,
                promptTokens: selectionUsage?.input,
                outputTokens: selectionUsage?.output,
                duration: selectionDuration
            )
        }

        // POLICY: if ANY sub-task falls outside the local tools, the ENTIRE
        // request goes to the cloud, which answers it with the full original
        // context rather than half a plan running locally. `none` is how the
        // model says so, honoured whether it arrives alone or mixed in with
        // real tools — half a contradiction is not a safe thing to run.
        guard !plan.toolNames.contains(ToolName.none.displayName) else {
            recordSelection([LLMRouter.escalationNote(for: plan)])
            return RoutingResult(
                strategyName: strategyName,
                // Both halves: what the model said, then what policy did
                // with it.
                reasoning: [plan.reasoning, LLMRouter.escalationNote(for: plan)]
                    .filter { !$0.isEmpty }
                    .joined(separator: " · "),
                calls: [RoutedCall(tool: ToolName.none, confidence: nil)],
                trace: trace
            )
        }

        // POLICY: an action is not something these tools can do, whatever
        // else the request also asks for. Every tool READS, so a request
        // that mixes an action with a lookup goes to the cloud ENTIRE —
        // serving the half that works tells the customer the other half
        // happened. Stage 2 states this rule too, but drops it when a
        // second intent stands next to the action, so it is enforced here
        // on the wording. After Stage 2, so the trace still records what
        // the model would have chosen.
        if LLMRouter.asksForAnAction(in: query) {
            let note = """
                The request asks for something to be DONE, and every tool here only reads. \
                A request that mixes an action with a lookup goes to the cloud whole rather \
                than half-served — answering the part that works would tell the customer the \
                rest of it happened.
                """
            recordSelection([note])
            return RoutingResult(
                strategyName: strategyName,
                reasoning: [plan.reasoning, note].filter { !$0.isEmpty }.joined(separator: " · "),
                calls: [RoutedCall(tool: ToolName.none, confidence: nil)],
                trace: trace
            )
        }

        // POLICY: a place the user NAMES has no way into the location
        // chain. find_nearest_atm and find_nearest_branch take COORDINATES
        // and get_location yields only the user's own, so nothing turns
        // "Chicago" into a latitude and adding steps cannot give it one.
        // All-or-nothing like the action rule, and narrow by construction:
        // it runs only when the plan holds a location tool.
        if plan.toolNames.contains(where: Self.locationTools.contains),
           LLMRouter.namesAPlace(in: query) {
            let note = """
                The question asks about a place it names rather than where the user is, and \
                the location tools only reach the user's own coordinates — nothing turns a \
                named place into a latitude. The whole request goes to the cloud rather \
                than answering it from the wrong location.
                """
            recordSelection([note])
            return RoutingResult(
                strategyName: strategyName,
                reasoning: [plan.reasoning, note].filter { !$0.isEmpty }.joined(separator: " · "),
                calls: [RoutedCall(tool: ToolName.none, confidence: nil)],
                trace: trace
            )
        }

        // Each call carries its Stage-1 similarity as the confidence.
        let scoreByTool = Dictionary(shortlist.map { ($0.toolName, Double($0.score)) }, uniquingKeysWith: max)
        let routedCalls = LLMRouter.routedCalls(for: plan, query: query, scores: scoreByTool)

        let duplicates = plan.toolNames.count - routedCalls.count
        recordSelection(duplicates > 0
            ? ["Dropped \(duplicates) tool\(duplicates == 1 ? "" : "s") the model named twice."]
            : [])

        // Stage 3. A failure here degrades to the routed plan without an
        // answer rather than losing the turn: routing did its job, and
        // showing which tools were chosen still beats an error.
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
            // Degrade to the plan, but record WHY: swallowing it made a
            // Stage-3 failure look identical to a turn that produced no
            // answer.
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

    /// The tools that only ever speak about where the user is standing.
    /// `get_location` is included because it is the only source of
    /// coordinates: a plan holding it is a plan about the user's position.
    private static let locationTools: Set<String> = [
        ToolName.getLocation.displayName,
        ToolName.findNearestATM(latitude: 0, longitude: 0).displayName,
        ToolName.findNearestBranch(latitude: 0, longitude: 0).displayName
    ]

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

    // MARK: - Stage 3: answering

    struct Answer {
        let text: String
        /// Tools the model actually invoked, in order. Differs from the
        /// routed plan when the agent skips or adds a step.
        let executedTools: [String]
        /// Those same calls with their arguments and raw results, for the
        /// UI's pipeline view.
        let invocations: [RoutingTrace.ExecutionStage.Invocation]
        /// The full session transcript, so a trajectory evaluation can
        /// grade the calls rather than re-running a copy of this method.
        let transcript: Transcript
        /// How long THIS generation took to produce its first character,
        /// tool calls included. Nil if it never produced one.
        let timeToFirstToken: Duration?
        /// Input tokens the turn cost. The direct measurement of the
        /// O(plan) claim: it should track the routed plan, not the catalog.
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

    /// Runs `plan` against `query` and returns the composed answer.
    ///
    /// The plan decides WHICH tools exist for this turn — they are the only
    /// ones bound to the session — and the model decides how to call them,
    /// re-deriving every argument from each tool's own schema. Stage 2
    /// selects; Stage 3 parameterises and orders.
    ///
    /// `onUpdate` defaults to a no-op so the evals, which want the finished
    /// text and nothing else, get the same code path the app streams from.
    func answer(
        _ query: String,
        using plan: [ToolName],
        onUpdate: (RoutingUpdate) -> Void = { _ in }
    ) async throws -> Answer {
        let names = plan.map(\.displayName).filter { $0 != ToolName.none.displayName }

        // The routed plan, resolved to live tools. THIS LIST IS THE
        // SESSION'S ENTIRE TOOLBOX — anything absent cannot be called,
        // however plausible it looks to the model.
        let tools = names.compactMap { BankToolRegistry.tool(named: $0, client: client) }

        // A plan naming only tools with no implementation cannot be run.
        // Better to surface that than to hand the model an empty toolbox.
        guard !tools.isEmpty else {
            throw AgentError.noExecutableTools(names)
        }

        let runnable = names.filter { BankToolRegistry.tool(named: $0, client: client) != nil }
        let session = makeSession(for: runnable, tools: tools)
        var answer = try await respond(in: session, to: query, onUpdate: onUpdate)

        // ROUTING SAID THESE TOOLS; ONE OF THEM NEVER RAN. The instructions
        // say "call all of them" and the plan is the whole toolbox, so a
        // routed tool missing from the transcript is a defect. Name what
        // was skipped and ask again, ONCE — on the same session, so the
        // first pass's calls are still in context and this adds the missing
        // figures rather than restarting.
        var repairPrompt: String?
        let missing = runnable.filter { !answer.executedTools.contains($0) }
        if !missing.isEmpty {
            let prompt = Self.retryPrompt(for: query, missing: missing)
            repairPrompt = prompt
            let repaired = try await respond(
                in: session,
                to: prompt,
                onUpdate: onUpdate,
                // The turn's user-visible latency was set by the first
                // generation; overwriting it would make a repaired turn
                // look faster than the one it repaired.
                timeToFirstToken: answer.timeToFirstToken
            )
            // A repair with nothing to say does not get to delete a real
            // answer. The first reply was incomplete; empty is worse.
            answer = repaired.text.isEmpty ? answer : repaired
        }

        remember(session.transcript, discarding: repairPrompt)
        return answer
    }

    /// One generation, delivered as it is produced.
    ///
    /// Streaming because of where the time goes: the tools have to run
    /// before the model can write a single grounded figure, so awaiting the
    /// whole reply hides the answer until after the part that was fast.
    /// Partials are for the eye only — the caller works from the final text.
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
            // Not greedy, unlike routing: this is prose, and greedy decoding
            // makes it stilted and repetitive.
            options: GenerationOptions(temperature: 0.3)
        )

        for try await snapshot in stream {
            // Read every time rather than once at the end: the stream can
            // finish on a snapshot whose text is unchanged, and the last
            // usage figure is the one that counts the whole turn.
            promptTokens = snapshot.usage.input.totalTokenCount

            // Snapshots are CUMULATIVE — each is the whole reply so far, not
            // the newest fragment. Trimmed on the way out so the finished
            // text is identical to what was last displayed.
            let partial = snapshot.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !partial.isEmpty else { continue }

            // Everything before this instant is tool execution: the model
            // cannot write a grounded figure until the calls come back.
            if timeToFirstToken == nil {
                timeToFirstToken = clock.now - start
            }
            text = partial
            onUpdate(.answerPartial(partial))
        }

        // THE WHOLE TRANSCRIPT, not this generation's share of it. On a
        // repaired turn the first pass's calls are in here too, and the
        // reply rests on both.
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

    /// A session bound to EXACTLY the routed tools, and nothing else.
    ///
    /// ONE PER REQUEST, forced by the framework: a session's `tools` are
    /// fixed at `init` while the plan changes every request, and when they
    /// conflict, binding wins. Narrowing only the transcript's
    /// `toolDefinitions` controls what the model is SHOWN, not what it can
    /// CALL — a turn that planned `pending_payments` once dispatched
    /// `search_transactions`, a tool it had never been shown.
    ///
    /// Instructions are built by hand rather than passed to
    /// `init(tools:instructions:)` because the transcript initialiser is
    /// the one that accepts history, and it takes the whole transcript —
    /// instructions entry included.
    private func makeSession(for names: [String], tools: [any Tool]) -> LanguageModelSession {
        let instructions = Transcript.Instructions(
            segments: [.text(Transcript.TextSegment(content: Self.instructions(for: names)))],
            toolDefinitions: tools.map { Transcript.ToolDefinition(tool: $0) }
        )
        sessionsBuilt += 1
        return LanguageModelSession(
            model: Self.model,
            tools: tools,
            transcript: Transcript(entries: [.instructions(instructions)] + history)
        )
    }

    /// Keeps what the user and the assistant SAID, discards how it was
    /// found out.
    ///
    /// `discarding` is the repair prompt, when one was sent. The repair is
    /// not part of the conversation: the customer asked one question and
    /// received one answer, so carrying the agent's own plumbing forward
    /// would put it in the context of every later turn — and leave the
    /// superseded half-answer sitting there as the reply to it.
    private func remember(_ transcript: Transcript, discarding repairPrompt: String? = nil) {
        var kept: [Transcript.Entry] = []
        for entry in transcript {
            switch entry {
            case .prompt(let prompt):
                let text = prompt.segments
                    .compactMap { if case .text(let text) = $0 { text.content } else { nil } }
                    .joined(separator: " ")
                guard text != repairPrompt else {
                    // Drop the answer this replaced along with it: it is the
                    // incomplete one, superseded by what comes next.
                    if case .response = kept.last { kept.removeLast() }
                    continue
                }
                kept.append(entry)
            case .response:
                kept.append(entry)
            case .instructions, .toolCalls, .toolOutput:
                // Instructions are rebuilt per turn from that turn's plan.
                // Calls and outputs are dropped on purpose — see `history`.
                continue
            default:
                // `.reasoning` and anything the framework adds later. If a
                // future entry kind is worth carrying, decide that
                // deliberately rather than inheriting it here.
                continue
            }
        }
        history += kept
        if history.count > Self.historyEntryLimit {
            history.removeFirst(history.count - Self.historyEntryLimit)
        }
    }

    /// What to say when a routed tool never ran.
    ///
    /// NAMES THE TOOL AND RESTATES THE QUESTION. Naming it is what makes
    /// this different from asking again — the model believes it is finished,
    /// so "you did not answer fully" invites a rewording of the same reply.
    /// The question comes with it because the answer has to cover ALL of it.
    private static func retryPrompt(for query: String, missing: [String]) -> String {
        let names = ToolOutput.list(missing)
        let verb = missing.count == 1 ? "tool you have not called yet is" : "tools you have not called yet are"
        return """
            The \(verb) \(names). Call \(missing.count == 1 ? "it" : "them") now, then reply \
            ONCE with the complete answer to the original question — "\(query)" — covering \
            every part of it, including the parts you have already answered. Use the figures \
            the tools returned and nothing else.
            """
    }

    // MARK: - Instructions

    /// O(plan), not O(catalog): the tools describe themselves through their
    /// own schemas, so these instructions only say how to behave, never
    /// what exists.
    ///
    /// CALLING and REPLYING are kept separate on purpose. "Use the ones
    /// that help" read as permission to skip a call, and a skipped call is
    /// indistinguishable from a model error in the trajectory evaluation.
    /// "Call all of them, omit from the reply" keeps the guard against an
    /// over-broad plan while leaving the trajectory deterministic.
    private static func instructions(for names: [String]) -> String {
        """
        You are a banking assistant answering the user's question with the \
        tools you have been given. Call them to get real values — never \
        guess a balance, a number, or a date, and never mention the tools, \
        the app, or that you called anything.

        Internal reference codes are part of that: a branch ID like \
        BR-4417 is how one tool talks to another, not something a \
        customer asked for. Use it to make the next call, then leave it \
        out — say "the Main St Branch", never "Main St Branch (BR-4417)".

        The tools were retrieved for this question already: \
        \(names.joined(separator: ", ")). Call all of them. When one needs \
        another's result, call that one first and pass its answer along. \
        If a result does not answer what was asked, leave it out of your \
        REPLY rather than working it in — routing errs on the side of \
        offering one tool too many. Skipping the call is not the fix; \
        omitting the result from the answer is.

        THAT APPLIES TO PART OF A RESULT TOO. When the question names ONE \
        thing and the tool returns several, answer with the one and leave \
        the rest out: "my credit card number" gets the credit card, not \
        the debit card that came back with it, and "when does my rent \
        payment go out" gets the rent, not the gym membership sitting \
        beside it in the schedule. When the question names nothing in \
        particular — "what fees did I pay", "my card limits" — it is \
        asking for all of them, and all of them is the answer.

        Call each tool ONCE. When it takes a parameter that covers \
        everything asked for — "all" rather than one account at a time — \
        use that instead of calling the same tool again with a different \
        value. MEASURED: "what's my account balance" produced three \
        separate account_balance calls where one with "all" returns the \
        same three figures, tripling the wait before a word appears.

        Never work out a total, a difference, or a percentage, and never \
        report a figure you arrived at yourself — only figures a tool \
        returned. Never write "totalling", "in total", "altogether" or \
        "that comes to" about figures you added up yourself: MEASURED, a \
        reply summarised three scheduled payments as "totaling \
        $2,345.89", a number no tool returned and one that cannot exist, \
        because one of the three is a statement balance rather than an \
        amount. List the figures instead — that is what the customer \
        asked for. If the question compares two amounts, whether one \
        covers another, give BOTH figures and say which is larger rather \
        than reporting what is left over. A number you calculated is \
        indistinguishable to the reader from one the bank returned, and \
        this is someone's money.

        Answer in one or two short sentences, in plain language, using the \
        exact figures the tools return — a sentence longer when the \
        question has several parts, because every part still needs its \
        own figures. If a tool comes back empty, say so plainly rather \
        than filling the gap.

        Write ONE PARAGRAPH of ordinary, COMPLETE sentences. Every clause \
        needs its verb: "the charge was $82.19 and your balance is \
        $1,204.87", never "The charge at Amazon $82.19 and the credit \
        card balance $1,204.87" — brevity is not worth a sentence a \
        person would not say. No bullet points, no headings, no blank \
        lines, no rows separated by dashes or dots, and do not carry a \
        tool's punctuation across into your reply. The figures are the \
        tool's; the sentence is yours.

        Talk TO the customer about THEIR money, in the present tense: \
        "your monthly service fee is $12.00", not "the monthly service \
        fee was $12.00". MEASURED: three replies in one batch were marked \
        down for reading as a data readout, and the difference every time \
        was one word — "the" where "your" belonged.

        When the answer differs by case — weekdays against Saturday, one \
        account against another — give EACH case, not just the first one \
        you read. "Open until 5 pm on weekdays" silently drops the \
        Saturday hours the same tool returned, and a customer planning a \
        Saturday visit is the one asking.

        NEVER ANNOUNCE WHAT YOU ARE ABOUT TO SHOW. "Here are your recent \
        transactions, pending payments, and scheduled payments." is not \
        an answer — it names the three things asked for and gives none of \
        them. If you name something the customer asked about, its figures \
        belong in that same sentence.
        """
    }

    // MARK: - Transcript

    /// Every tool call the model made, in order, paired with the result
    /// that came back.
    ///
    /// Calls and outputs are separate transcript entries, so they are
    /// matched by name in arrival order. A call with no output (the run was
    /// cut short) still appears, with `output` nil.
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

    /// A tool call's arguments as one readable line. `GeneratedContent`
    /// prints as pretty JSON; the view wants a single row.
    private static func describe(_ arguments: GeneratedContent) -> String? {
        let text = String(describing: arguments)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: " ")
        return text.isEmpty || text == "{}" ? nil : text
    }
}
