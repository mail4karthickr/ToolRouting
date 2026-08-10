/*
Locks the operand check on ComputeTool.

The arithmetic is the easy half and barely needs testing. The half that
matters is the refusal: ComputeTool's output is TOOL OUTPUT, and tool
output is what AnswerVerifier trusts. So a model that invents $4,000,
feeds it here and gets a correctly-calculated result would have laundered
a fabricated figure into a verified one — and taken the suite's only
deterministic gate with it. Most of what follows is that one hole,
approached from several directions.

Pure logic — no MLX, no Apple Intelligence, no network, no session. The
tool's transcript dependency is a closure, so these set it directly.
*/

import Foundation
import Testing
@testable import ToolRoutingStrategies

@Suite("Compute Tool")
struct ComputeToolTests {

    /// What the tools returned for "do I have enough for rent" — the two
    /// figures every traceable case below draws on.
    static let toolOutput = """
        Checking: $2,340.12 · Savings: $8,120.55 · Credit Card: $1,204.87 of $10,000 limit
        Rent — Transfer to Landlord — $1,850.00 — scheduled for the 1st
        """

    private static func tool(sources: [String] = [toolOutput]) -> ComputeTool {
        let tool = ComputeTool()
        tool.allowedSources = { sources }
        return tool
    }

    private static func arguments(
        _ operation: ComputeTool.Operation,
        _ operands: [String],
        style: ComputeTool.Style = .currency,
        label: String = "result"
    ) -> ComputeTool.Arguments {
        ComputeTool.Arguments(operation: operation, operands: operands, style: style, label: label)
    }

    // MARK: - Rejection — the laundering hole

    @Test("Refuses an operand no tool returned")
    func refusesInventedOperand() async throws {
        let output = try await Self.tool().call(
            arguments: Self.arguments(.sum, ["$2,340.12", "$4,000.00"])
        )
        #expect(output.contains("not a figure any tool returned"))
        // The refusal must not carry the arithmetic anyway. If the sum
        // appeared here it would enter the transcript, and the verifier
        // would then accept $6,340.12 in the answer.
        #expect(!output.contains("6,340.12"))
    }

    @Test("One invented operand poisons the whole call")
    func refusesPartiallyTraceableOperands() async throws {
        // Two of three are real. A check that passed on "most operands
        // trace" would let the third through.
        let output = try await Self.tool().call(
            arguments: Self.arguments(.sum, ["$2,340.12", "$1,850.00", "$99.99"])
        )
        #expect(output.contains("not a figure any tool returned"))
        #expect(!output.contains("4,290.11"))
    }

    @Test("Refuses an operand carrying no figure at all")
    func refusesNonNumericOperand() async throws {
        let output = try await Self.tool().call(
            arguments: Self.arguments(.sum, ["my checking balance"])
        )
        // Must not pass the trace check vacuously: an operand with no
        // numerals satisfies "every numeral traces" trivially.
        #expect(output.contains("Could not read a number"))
    }

    @Test("Refuses everything when the transcript was never wired")
    func failsClosedWithoutSources() async throws {
        // A ComputeTool whose `allowedSources` was never set has an empty
        // allowed set, so a real figure is refused too. Fails closed: the
        // wiring bug shows up as a refusal, not as silent trust.
        let unwired = ComputeTool()
        let output = try await unwired.call(
            arguments: Self.arguments(.sum, ["$2,340.12", "$1,850.00"])
        )
        #expect(output.contains("not a figure any tool returned"))
    }

    @Test("A figure from the user's own question is allowed")
    func acceptsFigureFromQuery() async throws {
        // The agent passes the query alongside the tool output, matching
        // AnswerVerifier: "enough to cover $5,000?" entitles the model to
        // work with $5,000 even though no tool returned it.
        let tool = Self.tool(sources: [Self.toolOutput, "Do I have enough to cover $5,000?"])
        let output = try await tool.call(
            arguments: Self.arguments(.compare, ["$2,340.12", "$5,000"])
        )
        #expect(output.contains("falls short of"))
    }

    // MARK: - Acceptance

    @Test("Adds figures that trace to the tool output")
    func sumsTraceableFigures() async throws {
        let output = try await Self.tool().call(
            arguments: Self.arguments(.sum, ["$2,340.12", "$8,120.55"], label: "total across accounts")
        )
        #expect(output.contains("total across accounts"))
        #expect(output.contains("10,460.67"))
    }

    @Test("Accepts an operand reformatted from the tool's own text")
    func acceptsCanonicalRewording() async throws {
        // The tools printed "$1,850.00"; the model passes "1850". Same
        // figure under AnswerVerifier.canonical, so the same latitude an
        // answer gets applies to an operand.
        let output = try await Self.tool().call(
            arguments: Self.arguments(.difference, ["$2,340.12", "1850"], label: "left after rent")
        )
        #expect(output.contains("490.12"))
    }

    @Test("Compare reports the verdict and the margin")
    func comparesWithMargin() async throws {
        let output = try await Self.tool().call(
            arguments: Self.arguments(.compare, ["$2,340.12", "$1,850.00"], label: "rent check")
        )
        #expect(output.contains("is enough to cover"))
        #expect(output.contains("490.12"))
    }

    @Test("Percentage is computed rather than left to the model")
    func computesPercentage() async throws {
        let output = try await Self.tool().call(
            arguments: Self.arguments(
                .percentage, ["$1,850.00", "$2,340.12"], style: .percent, label: "rent as share of checking"
            )
        )
        // 1850 / 2340.12 = 79.05…%
        #expect(output.contains("79.1%"))
    }

    // MARK: - Arity and division guards

    @Test("Difference and comparison need exactly two figures")
    func rejectsWrongArity() async throws {
        let difference = try await Self.tool().call(
            arguments: Self.arguments(.difference, ["$2,340.12"])
        )
        #expect(difference.contains("exactly two figures"))

        let comparison = try await Self.tool().call(
            arguments: Self.arguments(.compare, ["$2,340.12", "$1,850.00", "$8,120.55"])
        )
        #expect(comparison.contains("exactly two figures"))
    }

    @Test("A percentage of zero is refused rather than crashing")
    func rejectsZeroDenominator() async throws {
        let tool = Self.tool(sources: ["Pending payments total: $0.00\nNetflix: $15.49"])
        let output = try await tool.call(
            arguments: Self.arguments(.percentage, ["$15.49", "$0.00"], style: .percent)
        )
        #expect(output.contains("Cannot take a percentage of zero"))
    }

    // MARK: - The channel

    @Test("A computed figure passes AnswerVerifier once it is in the transcript")
    func computedFigureIsVerifiable() async throws {
        // The whole reason for routing arithmetic through a tool: the
        // result becomes tool output, so an answer quoting it verifies
        // without AnswerVerifier needing to know arithmetic exists.
        let computed = try await Self.tool().call(
            arguments: Self.arguments(.difference, ["$2,340.12", "$1,850.00"], label: "left after rent")
        )
        let stray = AnswerVerifier.strayNumerals(
            in: "You'll have $490.12 left after rent.",
            allowedFrom: [Self.toolOutput, computed]
        )
        #expect(stray.isEmpty)
    }

    @Test("A refused calculation leaves nothing for the answer to quote")
    func refusalContributesNoFigures() async throws {
        // The other half of the same guarantee: when the operand check
        // fires, the transcript gains no new figure, so an answer built
        // on the invented one still fails verification.
        let refusal = try await Self.tool().call(
            arguments: Self.arguments(.sum, ["$2,340.12", "$4,000.00"])
        )
        let stray = AnswerVerifier.strayNumerals(
            in: "Together that comes to $6,340.12.",
            allowedFrom: [Self.toolOutput, refusal]
        )
        #expect(stray == ["6,340.12"])
    }
}
