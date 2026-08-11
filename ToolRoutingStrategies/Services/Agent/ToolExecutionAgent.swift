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
// model can fill `find_atm(location:)` with the string `get_location`
// just returned. Routing narrows the field; the agent does the last mile.
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
//   bound at init   every tool — what a call can DISPATCH to
//   in the entry    the routed plan — what the model can SEE, and the
//                   only one of the two that costs prompt tokens
//
// The O(plan) property the routing stages exist to buy is preserved by
// the second list. If a change ever makes the prompt carry the first one,
// the cascade is still running but paying for nothing — `promptTokens` in
// StreamingTests is the tripwire for that.

@MainActor
final class ToolExecutionAgent {
    private let client: any BankAPIClient

    /// Bound on every request, unlike the routed tools. Whether an answer
    /// needs arithmetic is only knowable after the figures come back,
    /// which is after both routing stages have run — see the header of
    /// ComputeTool for why it is kept out of the catalog.
    private let compute = ComputeTool()

    /// The one session. Nil until `prewarm()` or the first request builds
    /// it.
    private var session: LanguageModelSession?

    /// Every bound tool's definition, keyed by name, so a turn can pick
    /// out the handful it wants to show without rebuilding schemas.
    private var definitions: [String: Transcript.ToolDefinition] = [:]

    /// The question being answered right now. `compute` is wired once, in
    /// `init`, but its allowed operands include the user's own words —
    /// which change every turn — so the closure reads this rather than
    /// capturing a query that was current when the session was built.
    private var currentQuery = ""

    /// How many sessions this agent has built. The reuse tripwire: it
    /// should read 1 after prewarm and stay there for the life of the
    /// app, however many questions are asked.
    private(set) var sessionsBuilt = 0

    init(client: any BankAPIClient = MockBankAPIClient()) {
        self.client = client
        // Wired once here instead of per request. `compute` can only ever
        // calculate with figures the tools actually returned — without
        // this it would launder an invented operand into a
        // verified-looking result, since its own output is what the
        // verifier trusts.
        compute.allowedSources = { [weak self] in
            guard let self, let session else { return [] }
            return AnswerVerifier.toolOutputs(in: session.transcript) + [currentQuery]
        }
    }

    // MARK: Session

    /// Builds the session on first use and hands back the same one
    /// forever after.
    @discardableResult
    private func warmSession() -> LanguageModelSession {
        if let session { return session }

        let tools = BankToolRegistry.allTools(client: client) + [compute]
        definitions = Dictionary(
            tools.map { ($0.name, Transcript.ToolDefinition(tool: $0)) },
            uniquingKeysWith: { first, _ in first }
        )
        // The instructions given here are immediately replaced by the
        // first turn's. They are not wasted: this is the text the prewarm
        // prefills, and every turn's instructions share its opening, so
        // the prefix stays warm.
        let session = LanguageModelSession(
            tools: tools,
            instructions: Self.instructions(for: [])
        )
        self.session = session
        sessionsBuilt += 1
        return session
    }

    /// Called when the chat screen appears, so the model is paged in and
    /// the instruction prefix prefilled before the user's first question
    /// rather than inside it.
    func prewarm() {
        warmSession().prewarm()
    }

    /// Points the session at one turn: these instructions, these visible
    /// tools, no history.
    ///
    /// The reset is deliberate and is what makes reuse safe here. A
    /// transcript carried across turns would leave LAST turn's tool output
    /// in context, and `AnswerVerifier` trusts anything a tool returned —
    /// so yesterday's balance would both be reachable by the model and
    /// pass verification. Clearing per turn keeps "every figure traces to
    /// a tool call made for THIS question" true. The session, its bound
    /// tools, and the warmed weights all survive; only the conversation
    /// does not.
    private func beginTurn(_ query: String, showing names: [String]) -> LanguageModelSession {
        let session = warmSession()
        let visible = (names + [compute.name]).compactMap { definitions[$0] }

        session.transcript = Transcript(entries: [
            .instructions(
                Transcript.Instructions(
                    segments: [.text(Transcript.TextSegment(content: Self.instructions(for: names)))],
                    toolDefinitions: visible
                )
            )
        ])
        currentQuery = query
        return session
    }

    /// Rewrites the instructions entry to offer no tools at all, keeping
    /// everything else in the transcript — including the tool output the
    /// retry has to copy from.
    ///
    /// Entries are rebuilt rather than mutated in place: `Transcript`
    /// exposes its entries as a collection to read, and swapping the
    /// first one is clearer than reaching for an index setter.
    private func withdrawTools(from session: LanguageModelSession) {
        var entries = Array(session.transcript)
        guard case .instructions(var instructions) = entries.first else { return }

        instructions.toolDefinitions = []
        instructions.segments = [.text(Transcript.TextSegment(content: Self.copyOnlyInstructions))]
        entries[0] = .instructions(instructions)
        session.transcript = Transcript(entries: entries)
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
        /// The verifier rejected the first draft and this is the retry.
        var retriedForUnverifiedFigures = false
        /// The figures that got the first draft rejected, and the draft
        /// itself. Kept because the retry is the single most expensive
        /// thing that can happen in a turn — a whole extra generation —
        /// and `retriedForUnverifiedFigures` alone says it happened
        /// without saying why, which is not enough to lower the rate.
        var rejectedFigures: [String] = []
        var rejectedDraft: String?
    }

    enum AgentError: LocalizedError {
        case noExecutableTools([String])
        case emptyReply(plan: [String], executed: [String])
        case unverifiedFigures(AnswerVerifier.UnverifiedFigures)

        var errorDescription: String? {
            switch self {
            case .noExecutableTools(let names):
                "No executable tool for: \(names.joined(separator: ", "))."
            case .emptyReply(let plan, let executed):
                """
                Model returned an empty reply. Planned \(plan.joined(separator: ", ")); \
                called \(executed.isEmpty ? "nothing" : executed.joined(separator: ", ")).
                """
            case .unverifiedFigures(let failure):
                "Answer failed numeric verification twice. \(failure.localizedDescription)"
            }
        }
    }

    // MARK: Answering

    /// Runs `plan` against `query` and returns the composed answer.
    ///
    /// `plan` carries the parameters Stage 2 extracted, but they are not
    /// passed to the tools directly — the model re-derives each argument
    /// with the tool's own schema in front of it. The plan's parameters
    /// are still worth having: they are what the routing UI shows, and
    /// what an eval grades.
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
        warmSession()

        // A plan naming only tools with no implementation cannot be run.
        // Better to surface that than to hand the model an empty toolbox
        // and let it invent an answer. Checked against what is BOUND, so
        // the failure still means "nothing here can run this" rather than
        // "nothing was shown".
        let runnable = names.filter { definitions[$0] != nil }
        guard !runnable.isEmpty else { throw AgentError.noExecutableTools(names) }

        let session = beginTurn(query, showing: runnable)
        let answer = try await respond(in: session, to: query, onUpdate: onUpdate)

        // FAIL CLOSED. Every figure shown must trace to a tool result or to
        // the user's own question; anything else is a generation defect, and
        // in a banking app a wrong number is worse than no number.
        //
        // One retry, because the failure mode is a sampling artifact at
        // temperature 0.3 rather than a reasoning error — the tools have
        // already run and their output is in the session, so a second pass
        // is cheap and usually clean. If it fails again we throw, and
        // HybridRouter degrades to the routed plan with no answer, which
        // the UI already handles.
        let sources = AnswerVerifier.toolOutputs(in: session.transcript) + [query]
        do {
            try AnswerVerifier.verify(answer.text, allowedFrom: sources)
            return answer
        } catch let first as AnswerVerifier.UnverifiedFigures {
            // The user has already watched the rejected draft appear. Say
            // so before the replacement starts overwriting it — text that
            // silently rewrites itself reads as a glitch, and "we checked
            // the figures and they were wrong" is the more reassuring
            // truth in a banking app.
            onUpdate(.answerRewriting)
            // Take the tools away before asking again. MEASURED: a retry
            // on a three-call turn re-ran all three tools and produced six
            // identical calls, because "use the figures already in this
            // conversation" is a request the model is free to decline
            // while the tools are still in front of it. With no tool
            // visible it cannot decline: the transcript's existing output
            // is the only material there is. Saves the round trips and
            // shrinks the retry's prompt to the text alone.
            withdrawTools(from: session)
            var retry = try await respond(
                in: session,
                to: Self.retryPrompt(for: query),
                onUpdate: onUpdate
            )
            retry.retriedForUnverifiedFigures = true
            retry.rejectedFigures = first.stray
            retry.rejectedDraft = first.answer
            let retrySources = AnswerVerifier.toolOutputs(in: session.transcript) + [query]
            do {
                try AnswerVerifier.verify(retry.text, allowedFrom: retrySources)
                return retry
            } catch let second as AnswerVerifier.UnverifiedFigures {
                throw AgentError.unverifiedFigures(second)
            } catch {
                throw AgentError.unverifiedFigures(first)
            }
        }
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
    /// The verification contract is unchanged. Partials are for the eye
    /// only — nothing acts on them, and the caller still verifies the
    /// FINAL text against the tool outputs before anyone treats it as an
    /// answer. A draft that fails is retracted, which is exactly why
    /// `.answerRewriting` exists.
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

    /// Re-asks in the same session, so the tool results already in the
    /// transcript are reused rather than the tools being called again.
    private static func retryPrompt(for query: String) -> String {
        """
        That reply contained a number the tools did not return. Answer again \
        using only the exact figures already in this conversation, copying \
        each one character for character. The question was: \(query)
        """
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

        Never work out a total, a difference, a percentage, or whether one \
        amount covers another yourself. Call `compute` with the exact \
        figures the tools returned and use the number it gives back. It is \
        always available and is not part of the list above.

        Answer in one or two short sentences, in plain language, using the \
        exact figures the tools return. If a tool comes back empty, say so \
        plainly rather than filling the gap.
        """
    }

    /// Instructions for the retry, which runs with every tool withdrawn.
    ///
    /// Says nothing about calling anything, because nothing is callable —
    /// the previous instructions' first paragraph would be an invitation
    /// to attempt it and get an error. The whole job here is transcription.
    private static let copyOnlyInstructions = """
        You are a banking assistant. The conversation above already \
        contains everything you need: the question, and the exact values \
        the tools returned for it.

        You have no tools. Write the answer using ONLY figures that appear \
        verbatim above, copied character for character — every digit, \
        comma, decimal and currency symbol identical. Do not calculate, \
        round, combine or reformat any of them, and do not introduce a \
        figure that is not already there.

        One or two short sentences, plain language, no mention of tools or \
        of this correction.
        """

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
