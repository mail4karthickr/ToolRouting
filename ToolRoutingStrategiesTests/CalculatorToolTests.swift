/*
Locks the arithmetic CalculatorTool does on the model's behalf.

The point of the tool is that Swift computes the figure rather than a 3B
model retyping one — so what is asserted here is that each operation
returns the right number, in the right format, and that a malformed call
comes back as a sentence the model can read and correct rather than an
error that ends the turn.

Note what is NOT checked: whether an operand actually came from a tool.
That guard was removed with AnswerVerifier, so an invented figure will be
computed with like any other. See the header of CalculatorTool.

Pure logic — no MLX, no Apple Intelligence, no network, no session.
*/

import Foundation
import Testing
@testable import ToolRoutingStrategies

@Suite("Calculator Tool")
struct CalculatorToolTests {

    private static func arguments(
        _ operation: CalculatorTool.Operation,
        _ operands: [String],
        style: CalculatorTool.Style = .currency,
        label: String = "result"
    ) -> CalculatorTool.Arguments {
        CalculatorTool.Arguments(operation: operation, operands: operands, style: style, label: label)
    }

    // MARK: - Arithmetic

    @Test("Adds the figures it is given")
    func sumsFigures() async throws {
        let output = try await CalculatorTool().call(
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
        let output = try await CalculatorTool().call(
            arguments: Self.arguments(.difference, ["$2,340.12", "1850"], label: "left after rent")
        )
        #expect(output.contains("490.12"))
    }

    @Test("Averages the figures it is given")
    func averagesFigures() async throws {
        // Three months of spend, averaged — the shape "compare three
        // months" questions actually need.
        let output = try await CalculatorTool().call(
            arguments: Self.arguments(.average, ["$1,200.00", "$1,500.00", "$900.00"], label: "average monthly spend")
        )
        #expect(output.contains("average monthly spend"))
        #expect(output.contains("1,200.00"))
    }

    @Test("Max picks the largest figure")
    func picksMax() async throws {
        let output = try await CalculatorTool().call(
            arguments: Self.arguments(.max, ["$1,200.00", "$1,500.00", "$900.00"], label: "highest month")
        )
        #expect(output.contains("1,500.00"))
    }

    @Test("Min picks the smallest figure")
    func picksMin() async throws {
        let output = try await CalculatorTool().call(
            arguments: Self.arguments(.min, ["$1,200.00", "$1,500.00", "$900.00"], label: "lowest month")
        )
        #expect(output.contains("900.00"))
    }

    @Test("Multiplies two figures")
    func multipliesFigures() async throws {
        let output = try await CalculatorTool().call(
            arguments: Self.arguments(.multiply, ["$150.00", "12"], label: "yearly savings contribution")
        )
        #expect(output.contains("1,800.00"))
    }

    @Test("Divides two figures")
    func dividesFigures() async throws {
        let output = try await CalculatorTool().call(
            arguments: Self.arguments(.divide, ["$100.00", "4"], label: "per-week spend")
        )
        #expect(output.contains("25.00"))
    }

    @Test("Compare reports the verdict and the margin")
    func comparesWithMargin() async throws {
        let output = try await CalculatorTool().call(
            arguments: Self.arguments(.compare, ["$2,340.12", "$1,850.00"], label: "rent check")
        )
        #expect(output.contains("is enough to cover"))
        #expect(output.contains("490.12"))
    }

    @Test("Compare says so when the first figure falls short")
    func comparesShortfall() async throws {
        let output = try await CalculatorTool().call(
            arguments: Self.arguments(.compare, ["$2,340.12", "$5,000"], label: "rent check")
        )
        #expect(output.contains("falls short of"))
    }

    @Test("Percentage is computed rather than left to the model")
    func computesPercentage() async throws {
        let output = try await CalculatorTool().call(
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
        let output = try await CalculatorTool().call(
            arguments: Self.arguments(.sum, ["my checking balance"])
        )
        #expect(output.contains("Could not read a number"))
    }

    @Test("Difference, product, quotient, and comparison need exactly two figures")
    func rejectsWrongArity() async throws {
        let difference = try await CalculatorTool().call(
            arguments: Self.arguments(.difference, ["$2,340.12"])
        )
        #expect(difference.contains("exactly two figures"))

        let product = try await CalculatorTool().call(
            arguments: Self.arguments(.multiply, ["$2,340.12"])
        )
        #expect(product.contains("exactly two figures"))

        let quotient = try await CalculatorTool().call(
            arguments: Self.arguments(.divide, ["$2,340.12", "2", "3"])
        )
        #expect(quotient.contains("exactly two figures"))

        let comparison = try await CalculatorTool().call(
            arguments: Self.arguments(.compare, ["$2,340.12", "$1,850.00", "$8,120.55"])
        )
        #expect(comparison.contains("exactly two figures"))
    }

    @Test("A percentage of zero is refused rather than crashing")
    func rejectsZeroDenominator() async throws {
        let output = try await CalculatorTool().call(
            arguments: Self.arguments(.percentage, ["$15.49", "$0.00"], style: .percent)
        )
        #expect(output.contains("Cannot take a percentage of zero"))
    }

    @Test("Dividing by zero is refused rather than crashing")
    func rejectsZeroDivisor() async throws {
        let output = try await CalculatorTool().call(
            arguments: Self.arguments(.divide, ["$15.49", "0"])
        )
        #expect(output.contains("Cannot divide by zero"))
    }

    @Test("Sum, average, max, and min need at least one figure")
    func rejectsEmptyOperandsOnAggregates() async throws {
        let sum = try await CalculatorTool().call(arguments: Self.arguments(.sum, []))
        #expect(sum.contains("No figures to add"))

        let average = try await CalculatorTool().call(arguments: Self.arguments(.average, []))
        #expect(average.contains("No figures to average"))

        let max = try await CalculatorTool().call(arguments: Self.arguments(.max, []))
        #expect(max.contains("No figures given"))

        let min = try await CalculatorTool().call(arguments: Self.arguments(.min, []))
        #expect(min.contains("No figures given"))
    }
}
