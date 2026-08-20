import Foundation
import FoundationModels

// MARK: - Calculator (not bound — no session hands this to the model)

final class CalculatorTool: Tool, @unchecked Sendable {
    let name = "calculator"
    let description = """
        Calculate a figure from numbers other tools have already returned: \
        a total, an average, a difference, a percentage, a product, a \
        quotient, the largest or smallest of a set, or a two-way \
        comparison. Use this whenever the answer needs a number no tool \
        returned directly. Never do the arithmetic yourself.
        """

    @Generable
    enum Operation {
        case sum
        /// The mean of several figures, e.g. average monthly spend across three months.
        case average
        /// The largest of several figures, e.g. which month or merchant spent the most.
        case max
        /// The smallest of several figures, e.g. which month or merchant spent the least.
        case min
        case difference
        case multiply
        case divide
        case percentage
        case compare
    }

    @Generable
    enum Style {
        case currency
        case percent
        case plain
    }

    @Generable
    struct Arguments {
        @Guide(description: "What to calculate")
        var operation: Operation

        @Guide(description: """
            The figures to use, copied character for character from the tool \
            results, for example ["$2,340.12", "$1,850.00"]
            """)
        var operands: [String]

        @Guide(description: "How to format the result: currency, percent, or plain")
        var style: Style

        @Guide(description: "What the result means, for example 'total spent at Amazon'")
        var label: String

        init(operation: Operation, operands: [String], style: Style, label: String) {
            self.operation = operation
            self.operands = operands
            self.style = style
            self.label = label
        }
    }

    func call(arguments: Arguments) async throws -> String {
        var values: [Decimal] = []
        for operand in arguments.operands {
            guard let value = Self.parse(operand) else {
                return """
                    Could not read a number from '\(operand)'. Pass a figure exactly \
                    as a tool returned it.
                    """
            }
            values.append(value)
        }

        switch arguments.operation {
        case .sum:
            guard !values.isEmpty else { return "No figures to add." }
            return format(values.reduce(0, +), arguments)

        case .average:
            guard !values.isEmpty else { return "No figures to average." }
            return format(values.reduce(0, +) / Decimal(values.count), arguments)

        case .max:
            guard let largest = values.max() else { return "No figures given." }
            return format(largest, arguments)

        case .min:
            guard let smallest = values.min() else { return "No figures given." }
            return format(smallest, arguments)

        case .difference:
            guard values.count == 2 else {
                return "A difference needs exactly two figures; \(values.count) were given."
            }
            return format(values[0] - values[1], arguments)

        case .multiply:
            guard values.count == 2 else {
                return "A product needs exactly two figures; \(values.count) were given."
            }
            return format(values[0] * values[1], arguments)

        case .divide:
            guard values.count == 2 else {
                return "A quotient needs exactly two figures; \(values.count) were given."
            }
            guard values[1] != 0 else { return "Cannot divide by zero." }
            return format(values[0] / values[1], arguments)

        case .percentage:
            guard values.count == 2 else {
                return "A percentage needs exactly two figures; \(values.count) were given."
            }
            guard values[1] != 0 else { return "Cannot take a percentage of zero." }
            return format(values[0] / values[1] * 100, arguments)

        case .compare:
            guard values.count == 2 else {
                return "A comparison needs exactly two figures; \(values.count) were given."
            }
            let surplus = values[0] - values[1]
            let covers = surplus >= 0
            return """
                \(arguments.label): \(money(values[0])) \(covers ? "is enough to cover" : "falls short of") \
                \(money(values[1])), a \(covers ? "surplus" : "shortfall") of \(money(abs(surplus))).
                """
        }
    }

    private static func parse(_ text: String) -> Decimal? {
        let digits = text.filter { $0.isNumber || $0 == "." || $0 == "-" }
        guard digits.contains(where: \.isNumber) else { return nil }
        return Decimal(string: digits)
    }

    private func format(_ value: Decimal, _ arguments: Arguments) -> String {
        switch arguments.style {
        case .currency:
            "\(arguments.label): \(money(value))"
        case .percent:
            "\(arguments.label): \(value.formatted(.number.precision(.fractionLength(0...1))))%"
        case .plain:
            "\(arguments.label): \(value.formatted(.number.precision(.fractionLength(0...2))))"
        }
    }

    private func money(_ value: Decimal) -> String {
        value.formatted(.currency(code: "USD"))
    }
}
