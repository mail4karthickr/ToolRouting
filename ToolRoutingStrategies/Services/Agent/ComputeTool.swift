import Foundation
import FoundationModels

// MARK: - Arithmetic (Stage 3 only, always bound)
//
// Lets the model REASON about figures without ever AUTHORING one. It
// picks the operands and the operation — semantic work a 3B model
// handles — and Swift does the arithmetic, which it does not. Two real
// defects from the 2026-08-07 run ("$1 fee is $12.00", "1.2 mi" cut to
// "1") were the model failing to RETYPE a figure correctly; nothing
// about that suggests it can be trusted to compute one.
//
// The result comes back as tool output, so it lands in AnswerVerifier's
// allowed set through the normal channel and the guard needs no change.
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
// So the agent binds it unconditionally alongside the routed plan. That
// is O(plan)+1 rather than the O(catalog) session ToolExecutionAgent
// argues against, and the tool breaking the rule is the one that is not
// a data source.
//
// THE HOLE THIS WOULD OPEN WITHOUT `allowedSources`: the model invents
// $4,000, passes it here, and gets back a correctly-calculated result —
// which is now tool output, so the verifier whitelists it. A fabricated
// figure would launder itself into a verified one and take the only
// deterministic gate in the suite with it. Validating operands against
// what the tools actually returned is the load-bearing part of this
// file; the arithmetic is the easy half.
final class ComputeTool: Tool, @unchecked Sendable {
    let name = "compute"
    let description = """
        Calculate a figure from numbers other tools have already returned: \
        a total, a difference, a percentage, or a comparison. Use this \
        whenever the answer needs a number no tool returned directly. \
        Never do the arithmetic yourself.
        """

    /// The text the tools have returned so far, plus the user's own
    /// question — the only figures this tool will compute with.
    ///
    /// A closure rather than a value because of a chicken-and-egg: the
    /// tool has to exist before the session that will hold the
    /// transcript. The agent wires it immediately after creating the
    /// session; left unwired it returns nothing, which fails closed —
    /// every operand is rejected rather than silently trusted.
    ///
    /// Deliberately a non-`Sendable` closure. It reads the session's
    /// transcript, and the session is not `Sendable`; typing it this way
    /// keeps the capture legal at the assignment site. The class is
    /// `@unchecked Sendable` to match. In practice the read is a
    /// snapshot of an append-only transcript taken while the session is
    /// blocked awaiting this call, so there is no concurrent writer.
    var allowedSources: () -> [String] = { [] }

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
        let values: [Decimal]
        switch Self.resolve(arguments.operands, against: allowedSources()) {
        case .failure(let message): return message
        case .success(let resolved): values = resolved
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

    private enum Resolution {
        case success([Decimal])
        case failure(String)
    }

    /// Turns the model's operand strings into decimals, refusing any
    /// figure that appears in none of `sources`.
    ///
    /// Compared in `AnswerVerifier`'s canonical form, so the model may
    /// copy "$12.00" as "12" — the same latitude the verifier gives an
    /// answer. Anything with no source at all is refused outright.
    private static func resolve(_ operands: [String], against sources: [String]) -> Resolution {
        let allowed = Set(
            sources
                .flatMap { AnswerVerifier.numerals(in: $0) }
                .map(AnswerVerifier.canonical)
        )

        var values: [Decimal] = []
        for operand in operands {
            guard let value = parse(operand) else {
                return .failure("""
                    Could not read a number from '\(operand)'. Pass a figure exactly \
                    as a tool returned it.
                    """)
            }

            let figures = AnswerVerifier.numerals(in: operand).map(AnswerVerifier.canonical)
            // An operand with no numerals in it cannot be traced, so it
            // is refused rather than allowed through on an empty check.
            guard !figures.isEmpty, figures.allSatisfy(allowed.contains) else {
                return .failure("""
                    '\(operand)' is not a figure any tool returned. Only calculate with \
                    the figures already in this conversation.
                    """)
            }
            values.append(value)
        }
        return .success(values)
    }

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
