/*
Locks the streaming contract, which is a contract about ORDER and about
the numbers derived from it — not about the answer, which the eval suites
grade.

Three things can silently regress here and none of them show up as a
wrong answer:

  1. The answer arrives in one piece. `streamResponse` still returns the
     right text when nothing incremental reaches the UI, so a router that
     forgot to forward its callback looks perfect from the outside and
     ships a bubble that pops into existence fully written.
  2. The partials are treated as deltas. They are cumulative snapshots. A
     consumer that appends instead of assigns produces the answer with
     every prefix of itself glued in front, which is obvious on screen and
     invisible to every test that only reads the return value.
  3. Time to first token stops being smaller than the total. That is the
     one inequality the whole feature exists to create, and if timing is
     ever measured from the wrong instant it inverts or collapses.

Needs MLX, the MiniLM weights, and Apple Intelligence, like the other
pipeline tests. No judge and no API key: everything asserted here is
structural.
*/

import Foundation
import FoundationModels
import Testing
@testable import ToolRoutingStrategies

@Suite("Streaming")
@MainActor
struct StreamingTests {

    /// A question with an obvious single tool, so the run reaches Stage 3
    /// rather than escalating — an escalation streams nothing, correctly,
    /// and would make this vacuous.
    static let query = "What's my checking balance?"

    /// Everything one run reported, in arrival order.
    struct Recording {
        var stages: [String] = []
        var partials: [String] = []
        var timeToFirstToken: Duration?
        var total: Duration = .zero
        var result: RoutingResult?
    }

    static func record(_ query: String = query) async throws -> Recording {
        let router = HybridRouter()
        var recording = Recording()
        let clock = ContinuousClock()
        let start = clock.now

        recording.result = try await router.route(query) { update in
            switch update {
            case .retrieving: recording.stages.append("retrieving")
            case .selecting: recording.stages.append("selecting")
            case .answering: recording.stages.append("answering")
            case .answerRewriting: recording.stages.append("rewriting")
            case .answerPartial(let text):
                if recording.timeToFirstToken == nil {
                    recording.timeToFirstToken = clock.now - start
                }
                recording.partials.append(text)
            }
        }
        recording.total = clock.now - start
        return recording
    }

    // MARK: Order

    @Test("The pipeline reports its stages before it writes anything")
    func stagesPrecedeTheAnswer() async throws {
        let run = try await Self.record()
        try #require(!run.partials.isEmpty, "The run escalated; nothing was generated locally.")

        #expect(run.stages.prefix(3) == ["retrieving", "selecting", "answering"])
    }

    @Test("The answer arrives in pieces, each one the whole answer so far")
    func partialsAreCumulative() async throws {
        let run = try await Self.record()
        try #require(!run.partials.isEmpty, "The run escalated; nothing was generated locally.")

        // More than one, or nothing is being streamed — the single-shot
        // path also produces exactly one final string.
        #expect(run.partials.count > 1)

        // Cumulative, not deltas: each snapshot contains the last. Compared
        // on length rather than by prefix because the model can revise the
        // tail of a word between snapshots; what must never happen is a
        // snapshot that is a fragment of what came before.
        let lengths: [Int] = run.partials.map(\.count)
        #expect(lengths == lengths.sorted())

        // And the last one is what the caller gets back, so the bubble does
        // not change under the user at the end of the run.
        #expect(run.partials.last == run.result?.answer)
    }

    // MARK: Timing

    @Test("The first token lands before the answer finishes")
    func firstTokenPrecedesCompletion() async throws {
        let run = try await Self.record()
        let first = try #require(run.timeToFirstToken, "Nothing was generated locally.")

        #expect(first > .zero)
        #expect(first < run.total)
    }

    @Test("The trace records the generation's own time to first token")
    func executionStageRecordsItsFirstToken() async throws {
        let run = try await Self.record()
        let execution = try #require(run.result?.trace.execution, "Stage 3 never ran.")
        let first = try #require(execution.timeToFirstToken, "Stage 3 generated nothing.")

        // Inside the stage, so smaller than the stage. And smaller than the
        // user-facing figure too, which carries Stages 1 and 2 on top of it —
        // the gap between the two is what routing costs before a word appears.
        #expect(first <= execution.duration)
        #expect(first < (run.timeToFirstToken ?? .zero))
    }
}

/*
The other half of the same change: the sessions those runs went through
are built once and reused.

Reuse is cheap to claim and easy to lose — a session constructed inside a
function body still produces correct answers, just slower and colder, so
nothing fails when it comes back. `sessionsBuilt` is the tripwire.

The agent's reuse rests on a mechanism that needs its own proof. Its
session has EVERY tool bound, because a session's tools are fixed at init
and this one outlives every request; what keeps the prompt small is that
each turn rewrites the transcript's instructions entry to show only the
routed tools. Two things could go wrong and neither shows up as a wrong
answer:

  • The framework ignores the rewritten entry and prompts with all 20
    tools. Answers stay right; the routing stages become decoration and
    the context bill goes up ~5×. Caught by comparing prompt cost across
    plans of different sizes — if the entry were ignored, a one-tool turn
    and a four-tool turn would cost the same.
  • Dispatch breaks, because a tool the model calls is visible in the
    entry but resolved against the bound list. Caught by asking two
    unrelated questions on one agent and checking each ran its own tools.
*/

@Suite("Session reuse")
@MainActor
struct SessionReuseTests {

    // MARK: The tripwire

    @Test("The selector builds one session, however many requests it serves")
    func selectorKeepsOneSession() async throws {
        let router = LLMRouter()
        try #require(router.unavailabilityMessage == nil, "Apple Intelligence is unavailable.")

        router.prewarm()
        #expect(router.sessionsBuilt == 1)

        let candidates = Array(ToolCatalog.all.prefix(5))
        _ = try await router.select("What's my checking balance?", from: candidates)
        _ = try await router.select("Where is the nearest ATM?", from: candidates)

        #expect(router.sessionsBuilt == 1)
    }

    @Test("The agent builds one session, however many turns it answers")
    func agentKeepsOneSession() async throws {
        let agent = ToolExecutionAgent()
        agent.prewarm()
        #expect(agent.sessionsBuilt == 1)

        _ = try await agent.answer("What's my checking balance?", using: [.accountBalance(account: .checking)])
        _ = try await agent.answer("How many reward points do I have?", using: [.rewardPoints])

        #expect(agent.sessionsBuilt == 1)
    }

    // MARK: The mechanism

    @Test("A turn's prompt carries the routed tools, not every bound tool")
    func promptScalesWithThePlanNotTheCatalog() async throws {
        let agent = ToolExecutionAgent()

        let one = try await agent.answer(
            "What's my checking balance?",
            using: [.accountBalance(account: .checking)]
        )
        let several = try await agent.answer(
            "What's my balance, my reward points, my credit score, and what's pending?",
            using: [.accountBalance(account: .all), .rewardPoints, .creditScore, .pendingPayments(account: .all)]
        )

        let small = try #require(one.promptTokens)
        let large = try #require(several.promptTokens)

        // Four tool definitions cost visibly more than one. If the
        // instructions entry were being ignored, both turns would be
        // priced at the whole catalog and these would differ only by the
        // length of the question — tens of tokens, not hundreds.
        #expect(large > small + 100, "one tool: \(small) tokens, four tools: \(large) tokens")
    }

    @Test("Tools still dispatch after the instructions entry is rewritten")
    func dispatchSurvivesTheRewrite() async throws {
        let agent = ToolExecutionAgent()

        let balance = try await agent.answer(
            "What's my checking balance?",
            using: [.accountBalance(account: .checking)]
        )
        let points = try await agent.answer(
            "How many reward points do I have?",
            using: [.rewardPoints]
        )

        #expect(balance.executedTools.contains("account_balance"))
        #expect(points.executedTools.contains("reward_points"))

        // And the second turn is not still holding the first. Each turn
        // resets the transcript, which is what keeps AnswerVerifier's
        // guarantee — every figure traces to a tool call made for THIS
        // question — true on a session that outlives the question.
        #expect(!points.executedTools.contains("account_balance"))
        #expect(AnswerVerifier.toolOutputs(in: points.transcript).allSatisfy { !$0.contains("Checking") })
    }
}
