import Foundation
import FoundationModels

// MARK: - Stage 3: the agent that answers
//
// Routing decided WHICH tools a request needs. This runs them and turns
// their output into the sentence the user reads:
//
//   Stage 1  MiniLM retrieval  →  top-k shortlist
//   Stage 2  LLM selection     →  an ordered plan, or `none`
//   Stage 3  THIS              →  bind those tools, answer the question
//
// The load-bearing decision is that the agent's session is given ONLY
// the tools the plan named. That is the entire payoff of the two routing
// stages. A session holding all 20 tools would put every schema in the
// prompt and leave the model to rediscover, mid-answer, what routing
// already worked out; with two tools bound it has almost nothing to get
// wrong, and the prompt stays O(plan) rather than O(catalog).
//
// Note the plan is not replayed mechanically: the model still decides
// the order and fills in every argument. That is deliberate — only the
// model can fill `find_nearest_atm(latitude:longitude:)` with the
// coordinates `get_location` just returned. Routing narrows the field;
// the agent does the last mile.
//
// Those arguments being numbers is what makes the ordering hold. When
// this took a `location: String` the model could satisfy it with the
// literal "current location" and never call get_location at all, which
// is what it did on eval sample 7 (2026-08-12). A latitude it has not
// been given is not something guided decoding can fabricate its way
// past.
//
// WHICH tools run is not its decision, though. The instructions tell it
// to call all of them, so a tool that routing selected and the
// transcript never shows is a defect, not a judgment call.

// SESSION LIFETIME. One session, built when the chat screen appears and
// reused for every request after that — not one per turn. A session's
// tools and instructions are fixed at `init`, so keeping it means binding
// every tool up front and steering per request some other way. That other
// way is the transcript: on iOS 27 a session's transcript is mutable, and
// its first entry is the instructions, which carry BOTH the instruction
// text and the tool definitions the model is shown. Rewriting that one
// entry before each turn sets the instructions and narrows the visible
// tools to the routed plan, on a session that never gets rebuilt.
//
// So there are two different tool lists, and the distinction is the whole
// trick:
//
//   bound at init   the routed plan, and nothing else
//   in the prompt   the same list, because they are the same list
//
// THEY MUST BE THE SAME LIST. For a few hours on 2026-08-11 they weren't:
// the session bound all twenty tools so it could be long-lived, and only
// the transcript's instructions entry was narrowed to the plan. That
// controls what the model SEES, not what it can CALL, and the eval caught
// it immediately — a turn that planned `pending_payments` dispatched
// `search_transactions`, a tool it had never been shown.
//
// So the plan binds execution now, and the session is rebuilt per
// request because `tools` is fixed at `init` and the plan is not. The
// O(plan) property the routing stages exist to buy falls out of that
// rather than being maintained separately; `promptTokens` in
// StreamingTests is still the tripwire if it ever stops holding.

@MainActor
final class ToolExecutionAgent {
    private let client: any BankAPIClient

    /// How many sessions this agent has built — one per request, by
    /// design. Kept because it is the counter that would catch someone
    /// making this persistent again without reading why it isn't.
    private(set) var sessionsBuilt = 0

    /// The conversation so far, as `.prompt` and `.response` entries only.
    ///
    /// THE CONVERSATION IS CARRIED; THE TOOLBOX IS NOT. Each turn seeds a
    /// new session with this history and binds ONLY that turn's routed
    /// tools, so "what about last month?" has context while the tools
    /// available never accumulate — a question that routed to
    /// account_balance three turns ago does not leave account_balance
    /// callable now. Those are separate things, and conflating them is
    /// what a single long-lived session would do.
    ///
    /// TOOL CALLS AND OUTPUTS ARE DELIBERATELY DROPPED. Carrying them
    /// would put last turn's figures back in context where the model can
    /// reuse them as though they were fresh. A balance from four questions
    /// ago is exactly the kind of stale fact this app must not restate.
    /// The assistant's own replies come along, so the thread still reads
    /// as a conversation.
    private var history: [Transcript.Entry] = []

    /// How many past entries to carry — prompts and responses, so this is
    /// six exchanges. A cap rather than a choice about memory: the window
    /// is ~4,096 tokens shared with the instructions, the tool schemas and
    /// this turn's own output, and an unbounded thread would eventually
    /// take the whole budget and start failing turns that used to work.
    private static let historyEntryLimit = 12

    init(client: any BankAPIClient = MockBankAPIClient()) {
        self.client = client
    }

    // MARK: Session

    /// A session bound to EXACTLY the routed tools, and nothing else.
    ///
    /// ONE PER REQUEST, and that is forced by the framework: a session's
    /// `tools` are fixed at `init`, while the plan changes every request.
    /// The two cannot both be satisfied by a long-lived session, and when
    /// they conflict, binding wins.
    ///
    /// MEASURED, 2026-08-11, on the wrong side of that trade. This agent
    /// briefly kept ONE session with all twenty tools bound, narrowing
    /// only the `toolDefinitions` in the transcript's instructions entry.
    /// That controls what the model is SHOWN; it does not control what it
    /// can CALL. Eval sample 6 ("how much did i spend at uber") planned
    /// `pending_payments`, then dispatched `search_transactions` — a tool
    /// it had never been shown — and happened to answer correctly, which
    /// masked the bad plan in every place except the eval.
    ///
    /// So the routed plan now BINDS execution. An unrouted tool is not
    /// merely unlisted, it is absent, and a call to it has nowhere to go.
    /// Same shape of guarantee as Stage 2's per-request output schema:
    /// each stage can only reach what the stage before it handed over.
    ///
    /// The cost of rebuilding this per request is small, and smaller than
    /// it looks: these instructions name the routed tools, so they differ
    /// every turn and a persistent session was never reusing their
    /// prefill. It saved allocating an object and building twenty
    /// `Transcript.ToolDefinition`s, most of them unused. The model
    /// weights — the part that actually costs seconds — are paged in
    /// process-wide by `prewarm()` and stay warm across sessions.
    private func makeSession(for names: [String], tools: [any Tool]) -> LanguageModelSession {
        // EXACTLY the routed tools. `compute` used to be appended here on
        // every request, on the reasoning that whether an answer needs
        // arithmetic is only knowable after the figures come back. True,
        // but it made the tool unroutable: no selection could withhold
        // it, so it was in reach for all 60 samples whether or not the
        // question involved arithmetic.
        //
        // MEASURED, 2026-08-12, on the failing-sample run: `compute`
        // appeared in 9 of 20 trajectories and was the source of every
        // invented headline figure — a $5,435.90 "balance" on a question
        // whose account_balance call never happened, $4,190.12 of "June
        // spending" for a request that only wanted the statement, an
        // $11,665.54 all-accounts total standing in for the checking
        // balance. The figures were not even stable between runs. The
        // pattern was always the same: arithmetic nobody asked for,
        // reported IN PLACE OF the figure that was asked for.
        //
        // The tools already return the derived values worth having —
        // search_transactions returns its own total precisely so a small
        // model is never left adding a column up. What is gone with this
        // is genuine cross-tool arithmetic ("does checking cover rent"),
        // which now has to be answered by stating both figures.
        let bound = tools

        // Instructions are built by hand rather than passed to
        // `init(tools:instructions:)` because the transcript initialiser
        // is the one that accepts history, and it takes the whole
        // transcript — instructions entry included. The definitions here
        // are exactly the bound tools, which is the invariant the whole
        // change is for: what the model SEES and what it can CALL are one
        // list, built once, from the plan.
        let instructions = Transcript.Instructions(
            segments: [.text(Transcript.TextSegment(content: Self.instructions(for: names)))],
            toolDefinitions: bound.map { Transcript.ToolDefinition(tool: $0) }
        )
        let session = LanguageModelSession(
            tools: bound,
            transcript: Transcript(entries: [.instructions(instructions)] + history)
        )
        sessionsBuilt += 1
        // BOUND is the list the model can dispatch to; anything else it
        // names has nowhere to go. Logged with the carried history size
        // because the two together are this session's whole context.
        Log.stage3.debug("""
            session #\(sessionsBuilt) bound \(bound.map(\.name)), \
            \(history.count) history entr\(history.count == 1 ? "y" : "ies")
            """)
        return session
    }

    /// Called when the chat screen appears. Pages the model in — the
    /// dominant cold-start cost, and process-wide, so it benefits every
    /// per-request session built afterwards.
    ///
    /// Nothing about THIS turn can be prewarmed: the instructions name
    /// the routed tools and the tools are the routed tools, and neither
    /// is known until Stage 2 has run.
    func prewarm() {
        LanguageModelSession().prewarm()
    }

    /// Keeps what the user and the assistant SAID, discards how it was
    /// found out.
    ///
    /// Called after a turn succeeds, from the session that produced the
    /// answer.
    private func remember(_ transcript: Transcript) {
        history += transcript.filter { entry in
            switch entry {
            case .prompt, .response:
                return true
            case .instructions, .toolCalls, .toolOutput:
                // Instructions are rebuilt per turn from that turn's plan.
                // Calls and outputs are dropped on purpose — see `history`.
                return false
            default:
                // `.reasoning` and anything the framework adds later. If a
                // future entry kind is worth carrying, decide that
                // deliberately rather than inheriting it here.
                return false
            }
        }
        if history.count > Self.historyEntryLimit {
            let dropped = history.count - Self.historyEntryLimit
            history.removeFirst(dropped)
            // Where "it forgot what I just asked" comes from. The cap is
            // deliberate, but the turn it starts biting on is worth
            // knowing when a follow-up question stops resolving.
            Log.stage3.info("history trimmed by \(dropped) to \(Self.historyEntryLimit) entries")
        }
    }

    /// Forgets the conversation. For a "new chat" affordance, and for
    /// tests that need a clean agent without building a new one.
    func clearHistory() {
        history.removeAll()
    }

    // MARK: Result

    struct Answer {
        let text: String
        /// Tools the model actually invoked, in order. Differs from the
        /// routed plan when the agent skips or adds a step.
        let executedTools: [String]
        /// Those same calls with their arguments and raw results, for the
        /// UI's pipeline view. `executedTools` stays as it is because
        /// evals compare name sequences and shouldn't have to unpack this.
        let invocations: [RoutingTrace.ExecutionStage.Invocation]
        /// The full session transcript, so a trajectory evaluation can
        /// grade the calls and their arguments rather than re-running a
        /// copy of this method.
        let transcript: Transcript
        /// How long THIS generation took to produce its first character,
        /// tool calls included. Nil if it never produced one.
        let timeToFirstToken: Duration?
        /// Input tokens the last turn cost. The direct measurement of the
        /// O(plan) claim: it should track the size of the routed plan, not
        /// the size of the catalog bound to the session.
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

    // MARK: Answering

    /// Runs `plan` against `query` and returns the composed answer.
    ///
    /// The plan decides WHICH tools exist for this turn — they are the
    /// only ones bound to the session — and the model decides how to call
    /// them, re-deriving every argument from each tool's own schema.
    /// Stage 2 selects; Stage 3 parameterises and orders. Neither can do
    /// the other's job, and neither can reach past the one before it.
    ///
    /// `onUpdate` receives the answer as it is written. It defaults to a
    /// no-op so the evals, which want the finished text and nothing else,
    /// call this exactly as they always did — the streaming is a delivery
    /// detail, not a second code path with its own behaviour to trust.
    func answer(
        _ query: String,
        using plan: [ToolName],
        onUpdate: (RoutingUpdate) -> Void = { _ in }
    ) async throws -> Answer {
        let names = plan.map(\.displayName).filter { $0 != ToolName.none.displayName }

        // The routed plan, resolved to live tools. THIS LIST IS THE
        // SESSION'S ENTIRE TOOLBOX — anything absent here cannot be
        // called, however plausible it looks to the model.
        let tools = names.compactMap { BankToolRegistry.tool(named: $0, client: client) }

        // A plan naming only tools with no implementation cannot be run.
        // Better to surface that than to hand the model an empty toolbox
        // and let it invent an answer.
        guard !tools.isEmpty else {
            Log.stage3.error("no executable tool for \(names) — nothing to bind")
            throw AgentError.noExecutableTools(names)
        }

        let runnable = names.filter { BankToolRegistry.tool(named: $0, client: client) != nil }
        if runnable.count != names.count {
            // A routed name with no registry entry: the catalog and the
            // registry have drifted apart.
            Log.stage3.error("unimplemented tool(s) dropped from the plan: \(Set(names).subtracting(runnable).sorted())")
        }

        let session = makeSession(for: runnable, tools: tools)
        let answer = try await respond(in: session, to: query, onUpdate: onUpdate)

        // Every call the model actually made, with the arguments it chose
        // and what came back. This is where a wrong answer is usually
        // explained: the right tool called with the wrong account, or a
        // chain that ran out of order and passed a placeholder along.
        for invocation in answer.invocations {
            Log.stage3.info("""
                ↳ \(invocation.toolName)(\(invocation.arguments ?? "")) \
                → \(invocation.output?.loggable() ?? "NO OUTPUT")
                """)
        }
        if answer.text.isEmpty {
            Log.stage3.error("empty reply — planned \(runnable), called \(answer.executedTools)")
        }

        remember(session.transcript)
        return answer
    }

    /// One generation, delivered as it is produced.
    ///
    /// Streaming rather than awaiting the whole reply because of where
    /// the time goes: the tools have to run before the model can write a
    /// single grounded figure, so a one-tool question spends most of its
    /// wall clock before the first word and the rest of it emitting a
    /// two-sentence answer. Awaiting the whole thing hides the answer
    /// until after the part that was already fast.
    ///
    /// Partials are for the eye only — nothing acts on them, and the
    /// caller works from the FINAL text.
    private func respond(
        in session: LanguageModelSession,
        to query: String,
        onUpdate: (RoutingUpdate) -> Void
    ) async throws -> Answer {
        let clock = ContinuousClock()
        let start = clock.now
        var timeToFirstToken: Duration?
        var text = ""
        var promptTokens: Int?

        let stream = session.streamResponse(
            to: query,
            // Not greedy, unlike routing. Routing is classification and
            // benefits from being reproducible; this is prose, and greedy
            // decoding makes it stilted and repetitive.
            options: GenerationOptions(temperature: 0.3)
        )

        for try await snapshot in stream {
            // Read every time rather than once at the end: the stream can
            // finish on a snapshot whose text is unchanged, and the last
            // usage figure is the one that counts the whole turn.
            promptTokens = snapshot.usage.input.totalTokenCount

            // Snapshots are CUMULATIVE — each is the whole reply so far,
            // not the newest fragment. Trimmed on the way out so the
            // finished text is identical to what was last displayed;
            // trimming only at the end would make the bubble twitch on
            // the final frame.
            let partial = snapshot.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !partial.isEmpty else { continue }

            if timeToFirstToken == nil {
                timeToFirstToken = clock.now - start
                // Everything before this instant is tool execution: the
                // model cannot write a grounded figure until the calls
                // have come back. A long ttft with fast tools is a slow
                // prefill; a long one with slow tools is the API.
                Log.stage3.debug("first token at \((clock.now - start).logged)")
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
            timeToFirstToken: timeToFirstToken,
            promptTokens: promptTokens
        )
    }

    // MARK: Instructions

    /// O(plan), not O(catalog): the tools describe themselves through
    /// their own schemas, so these instructions only need to say how to
    /// behave, never what exists.
    ///
    /// CALLING and REPLYING are kept separate on purpose. An earlier
    /// wording ("use the ones that help") collapsed them, which read as
    /// permission to skip a call — and a skipped call is indistinguishable
    /// from a model error in the trajectory evaluation, since both show up
    /// as a tool missing from the transcript. Saying "call all of them,
    /// omit from the reply" keeps the guard against an over-broad plan
    /// contributing an irrelevant figure, while leaving the trajectory
    /// deterministic: every tool routing selected should appear, and one
    /// that doesn't is a real defect rather than obedience.
    // TRIED AND REVERTED, 2026-08-12. A paragraph told the model to
    // summarise list-shaped tool output rather than reproduce the rows,
    // aiming at samples 26 and 29 (verbatim transaction dumps scoring
    // Naturalness 2). It compressed by dropping qualifiers and merging
    // figures ACROSS rows: "$27.14" lost "last month at 4.05% APY",
    // Netflix's $15.49 was reattached to the credit card autopay, and one
    // answer asserted "no transactions found" that no tool returned.
    // Faithfulness fell on three working samples (39, 47, 51) and neither
    // target improved. Whatever fixes a verbatim dump, it is not an
    // instruction to be briefer.
    //
    // FIXED ELSEWHERE, 2026-08-12, once that reversion was read properly:
    // both failure modes were the model doing work on a row-shaped
    // payload — pasting it (Naturalness 2) or folding it up and losing a
    // date doing so (Faithfulness 2). Neither is a behaviour these
    // instructions can reach, because the instruction that would reach it
    // is the one that just failed. `ListTransactionsTool.summary` now
    // returns the window as one sentence, so there is no table to paste
    // and no compression left for the model to get wrong.
    //
    // MEASURED on the run after: sample 3 went Naturalness 2 → 4 ("one
    // concise, conversational sentence … no raw output pasted through"),
    // and sample 1's misattributed Amazon date went with it, 2 → 4 on
    // Faithfulness. Sample 2 regressed 4 → 1 on Completeness in a way
    // worth naming, because it is the reason the "never announce"
    // paragraph below exists: given three tools whose output was now
    // short, the model wrote "Here are your recent transactions, pending
    // payments, and scheduled payments." and STOPPED. It named all three
    // parts and delivered none of them.
    //
    // That is not the reverted "be briefer" instruction returning under
    // another name, and the distinction is the whole reason it is safe to
    // add: the reverted one capped LENGTH, which is what made the model
    // drop qualifiers and merge figures across rows. This one requires
    // CONTENT — every part named must carry its figures — and the length
    // rule above it was loosened, not tightened, so a three-part question
    // is no longer being squeezed into one sentence.
    private static func instructions(for names: [String]) -> String {
        """
        You are a banking assistant answering the user's question with the \
        tools you have been given. Call them to get real values — never \
        guess a balance, a number, or a date, and never mention the tools, \
        the app, or that you called anything.

        The tools were retrieved for this question already: \
        \(names.joined(separator: ", ")). Call all of them. When one needs \
        another's result, call that one first and pass its answer along. \
        If a result does not answer what was asked, leave it out of your \
        REPLY rather than working it in — routing errs on the side of \
        offering one tool too many. Skipping the call is not the fix; \
        omitting the result from the answer is.

        Call each tool ONCE. When it takes a parameter that covers \
        everything asked for — "all" rather than one account at a time — \
        use that instead of calling the same tool again with a different \
        value. MEASURED: "what's my account balance" produced three \
        separate account_balance calls where one with "all" returns the \
        same three figures, tripling the wait before a word appears.

        Never work out a total, a difference, or a percentage, and never \
        report a figure you arrived at yourself — only figures a tool \
        returned. If the question compares two amounts, whether one \
        covers another, give BOTH figures and say which is larger rather \
        than reporting what is left over. A number you calculated is \
        indistinguishable to the reader from one the bank returned, and \
        this is someone's money.

        Answer in one or two short sentences, in plain language, using the \
        exact figures the tools return — a sentence longer when the \
        question has several parts, because every part still needs its \
        own figures. If a tool comes back empty, say so plainly rather \
        than filling the gap.

        NEVER ANNOUNCE WHAT YOU ARE ABOUT TO SHOW. "Here are your recent \
        transactions, pending payments, and scheduled payments." is not \
        an answer — it names the three things asked for and gives none of \
        them. If you name something the customer asked about, its figures \
        belong in that same sentence.
        """
    }

    // MARK: Transcript

    /// Every tool call the model made, in order, paired with the result
    /// that came back.
    ///
    /// Calls and outputs are separate transcript entries, so they are
    /// matched by name in arrival order — the same tool called twice gets
    /// its first output paired with its first call. A call with no output
    /// (the run was cut short) still appears, with `output` nil: a tool
    /// that was invoked and returned nothing is exactly the kind of thing
    /// this view exists to make visible.
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
