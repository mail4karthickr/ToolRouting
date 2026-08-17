import Foundation
import FoundationModels

// MARK: - Arithmetic (NOT BOUND — see the end of this comment)
//
// UNBOUND SINCE 2026-08-12. This type still exists and ComputeToolTests
// still exercise it, but ToolExecutionAgent no longer hands it to the
// model, so nothing in the app can call it. Read the rest of this header
// as the argument that WAS made for binding it, then the measurement
// that ended it.
//
// Lets the model REASON about figures without ever AUTHORING one. It
// picks the operands and the operation — semantic work a 3B model
// handles — and Swift does the arithmetic, which it does not. Two real
// defects from the 2026-08-07 run ("$1 fee is $12.00", "1.2 mi" cut to
// "1") were the model failing to RETYPE a figure correctly; nothing
// about that suggests it can be trusted to compute one.
//
// The result comes back as tool output, so it enters the transcript
// through the normal channel and the answer can quote it like any other
// tool result.
//
// DELIBERATELY NOT IN ToolCatalog, which is why `catalogEntry` is not
// used here. The catalog is what Stage 1 embeds and Stage 2 selects
// from, and this tool must appear in neither:
//
//   - Routing runs BEFORE any tool returns anything, so it cannot know
//     whether arithmetic will be needed — that is only visible once the
//     figures are back.
//   - It has no data affinity to embed against. Every other tool matches
//     a question semantically ("balance" → account_balance); this one
//     describes arithmetic, so it would surface erratically.
//   - In the catalog it would compete for top-k slots and could displace
//     a real data tool, trading the figures for the calculator.
//
// So the agent bound it unconditionally alongside the routed plan. That
// is O(plan)+1 rather than the O(catalog) session ToolExecutionAgent
// argues against, and the tool breaking the rule is the one that is not
// a data source.
//
// THE OPERANDS ARE TAKEN ON TRUST. Nothing here checks that a figure the
// model passes in actually came from a tool, so an invented $4,000 gets
// a correctly-calculated result and that result becomes tool output like
// any other. That check used to exist and was removed with
// AnswerVerifier; if fabricated figures start showing up, this is where
// the guard goes back.
//
// THEY SHOWED UP. On the 2026-08-12 failing-sample run this tool was in
// 9 of 20 trajectories and behind every invented headline figure: a
// $5,435.90 "balance" on a question where account_balance was never
// called at all, $4,190.12 of "June spending" for a request that only
// wanted the statement, an $11,665.54 all-accounts total offered as the
// checking balance. Not one of those questions asked for arithmetic. The
// figures were not stable between runs either, so it was not one bad
// formula — the model reached for the calculator INSTEAD OF the lookup,
// then reported the result in place of the figure it was asked for.
//
// The paragraph above says the guard goes back here. It went somewhere
// cheaper instead: the tool is no longer bound, so there is no untrusted
// operand to check. The cost is genuine cross-tool arithmetic — "does
// checking cover rent" is now answered by stating both figures — and the
// tools that most needed a total (search_transactions) already return
// their own. Bind it again and the operand check is the price.
final class ComputeTool: Tool, @unchecked Sendable {
    let name = "compute"
    let description = """
        Calculate a figure from numbers other tools have already returned: \
        a total, a difference, a percentage, or a comparison. Use this \
        whenever the answer needs a number no tool returned directly. \
        Never do the arithmetic yourself.
        """

    // MARK: Arguments

    @Generable
    enum Operation {
        /// Add every operand together.
        case sum
        /// operands[0] − operands[1].
        case difference
        /// operands[0] as a percentage of operands[1].
        case percentage
        /// Whether operands[0] covers operands[1], and by how much.
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

        /// Written out rather than left to the memberwise synthesis so
        /// tests can build one without depending on what @Generable
        /// expands to.
        init(operation: Operation, operands: [String], style: Style, label: String) {
            self.operation = operation
            self.operands = operands
            self.style = style
            self.label = label
        }
    }

    // MARK: Calling

    /// Every failure returns a sentence rather than throwing. A throw
    /// ends the turn; a message goes back into the transcript, where the
    /// model can read what it did wrong and call again with figures it
    /// actually has.
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

        case .difference:
            guard values.count == 2 else {
                return "A difference needs exactly two figures; \(values.count) were given."
            }
            return format(values[0] - values[1], arguments)

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

    // MARK: Operands

    /// Decimal, never Double — this is money. Strips currency symbols and
    /// thousands separators so the model can copy a figure verbatim.
    private static func parse(_ text: String) -> Decimal? {
        let digits = text.filter { $0.isNumber || $0 == "." || $0 == "-" }
        guard digits.contains(where: \.isNumber) else { return nil }
        return Decimal(string: digits)
    }

    // MARK: Formatting

    /// The label travels with the figure so the transcript records what
    /// the number MEANS, not just its value. That is what gives the
    /// Faithfulness judge something to catch a correctly-computed answer
    /// to the wrong question with.
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
