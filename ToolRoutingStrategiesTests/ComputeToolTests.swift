/*
Locks the arithmetic ComputeTool does on the model's behalf.

The point of the tool is that Swift computes the figure rather than a 3B
model retyping one — so what is asserted here is that each operation
returns the right number, in the right format, and that a malformed call
comes back as a sentence the model can read and correct rather than an
error that ends the turn.

Note what is NOT checked: whether an operand actually came from a tool.
That guard was removed with AnswerVerifier, so an invented figure will be
computed with like any other. See the header of ComputeTool.

Pure logic — no MLX, no Apple Intelligence, no network, no session.
*/

import Foundation
import Testing
@testable import ToolRoutingStrategies

@Suite("Compute Tool")
struct ComputeToolTests {

    private static func arguments(
        _ operation: ComputeTool.Operation,
        _ operands: [String],
        style: ComputeTool.Style = .currency,
        label: String = "result"
    ) -> ComputeTool.Arguments {
        ComputeTool.Arguments(operation: operation, operands: operands, style: style, label: label)
    }

    // MARK: - Arithmetic

    @Test("Adds the figures it is given")
    func sumsFigures() async throws {
        let output = try await ComputeTool().call(
            arguments: Self.arguments(.sum, ["$2,340.12", "$8,120.55"], label: "total across accounts")
        )
        #expect(output.contains("total across accounts"))
        #expect(output.contains("10,460.67"))
    }

    @Test("Reads an operand however the model formatted it")
    func parsesReformattedOperand() async throws {
        // The tools printed "$1,850.00"; the model passes "1850". Currency
        // symbols and thousands separators are stripped, so both parse to
        // the same Decimal.
        let output = try await ComputeTool().call(
            arguments: Self.arguments(.difference, ["$2,340.12", "1850"], label: "left after rent")
        )
        #expect(output.contains("490.12"))
    }

    @Test("Compare reports the verdict and the margin")
    func comparesWithMargin() async throws {
        let output = try await ComputeTool().call(
            arguments: Self.arguments(.compare, ["$2,340.12", "$1,850.00"], label: "rent check")
        )
        #expect(output.contains("is enough to cover"))
        #expect(output.contains("490.12"))
    }

    @Test("Compare says so when the first figure falls short")
    func comparesShortfall() async throws {
        let output = try await ComputeTool().call(
            arguments: Self.arguments(.compare, ["$2,340.12", "$5,000"], label: "rent check")
        )
        #expect(output.contains("falls short of"))
    }

    @Test("Percentage is computed rather than left to the model")
    func computesPercentage() async throws {
        let output = try await ComputeTool().call(
            arguments: Self.arguments(
                .percentage, ["$1,850.00", "$2,340.12"], style: .percent, label: "rent as share of checking"
            )
        )
        // 1850 / 2340.12 = 79.05…%
        #expect(output.contains("79.1%"))
    }

    // MARK: - Malformed calls come back as sentences

    @Test("An operand carrying no figure is refused")
    func refusesNonNumericOperand() async throws {
        let output = try await ComputeTool().call(
            arguments: Self.arguments(.sum, ["my checking balance"])
        )
        #expect(output.contains("Could not read a number"))
    }

    @Test("Difference and comparison need exactly two figures")
    func rejectsWrongArity() async throws {
        let difference = try await ComputeTool().call(
            arguments: Self.arguments(.difference, ["$2,340.12"])
        )
        #expect(difference.contains("exactly two figures"))

        let comparison = try await ComputeTool().call(
            arguments: Self.arguments(.compare, ["$2,340.12", "$1,850.00", "$8,120.55"])
        )
        #expect(comparison.contains("exactly two figures"))
    }

    @Test("A percentage of zero is refused rather than crashing")
    func rejectsZeroDenominator() async throws {
        let output = try await ComputeTool().call(
            arguments: Self.arguments(.percentage, ["$15.49", "$0.00"], style: .percent)
        )
        #expect(output.contains("Cannot take a percentage of zero"))
    }
}
