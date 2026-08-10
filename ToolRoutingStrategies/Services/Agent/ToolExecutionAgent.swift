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

@MainActor
final class ToolExecutionAgent {
    private let client: any BankAPIClient

    init(client: any BankAPIClient = MockBankAPIClient()) {
        self.client = client
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
        /// The verifier rejected the first draft and this is the retry.
        var retriedForUnverifiedFigures = false
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
    func answer(_ query: String, using plan: [ToolName]) async throws -> Answer {
        let names = plan.map(\.displayName).filter { $0 != ToolName.none.displayName }
        let tools = names.compactMap { BankToolRegistry.tool(named: $0, client: client) }

        // A plan naming only tools with no implementation cannot be run.
        // Better to surface that than to hand the model an empty toolbox
        // and let it invent an answer.
        guard !tools.isEmpty else { throw AgentError.noExecutableTools(names) }

        // Bound on every request, unlike the routed tools. Whether an
        // answer needs arithmetic is only knowable after the figures come
        // back, which is after both routing stages have run — see the
        // header of ComputeTool for why it is kept out of the catalog.
        let compute = ComputeTool()
        let session = LanguageModelSession(
            tools: tools + [compute],
            instructions: Self.instructions(for: names)
        )
        // Chicken-and-egg: the tool needs the transcript, the session
        // needs the tool. Wired here so `compute` can only ever calculate
        // with figures the tools actually returned — without this it
        // would launder an invented operand into a verified-looking
        // result, since its own output is what the verifier trusts.
        compute.allowedSources = { [weak session] in
            guard let session else { return [] }
            return AnswerVerifier.toolOutputs(in: session.transcript) + [query]
        }

        let answer = try await respond(in: session, to: query)

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
            var retry = try await respond(in: session, to: Self.retryPrompt(for: query))
            retry.retriedForUnverifiedFigures = true
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

    private func respond(in session: LanguageModelSession, to query: String) async throws -> Answer {
        let response = try await session.respond(
            to: query,
            // Not greedy, unlike routing. Routing is classification and
            // benefits from being reproducible; this is prose, and greedy
            // decoding makes it stilted and repetitive.
            options: GenerationOptions(temperature: 0.3)
        )
        let invocations = Self.invocations(in: session.transcript)
        return Answer(
            text: response.content.trimmingCharacters(in: .whitespacesAndNewlines),
            executedTools: invocations.map(\.toolName),
            invocations: invocations,
            transcript: session.transcript
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

        Never work out a total, a difference, a percentage, or whether one \
        amount covers another yourself. Call `compute` with the exact \
        figures the tools returned and use the number it gives back. It is \
        always available and is not part of the list above.

        Answer in one or two short sentences, in plain language, using the \
        exact figures the tools return. If a tool comes back empty, say so \
        plainly rather than filling the gap.
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
