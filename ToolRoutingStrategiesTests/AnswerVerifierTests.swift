/*
Locks the numeric provenance guard against the two real defects from the
2026-08-07 hybrid run, plus the answers it must NOT flag.

Pure logic — no MLX, no Apple Intelligence, no network. The regression
cases are verbatim from that run's .xcevalresult, so if the scanner or
the canonical form ever drifts, these fail instead of a customer seeing
a wrong balance.
*/

import Foundation
import Testing
@testable import ToolRoutingStrategies

@Suite("Answer Verifier")
struct AnswerVerifierTests {

    // MARK: Regressions — must be caught

    @Test("Catches the stutter that split a figure in two (sample 23)")
    func catchesStutter() {
        let stray = AnswerVerifier.strayNumerals(
            in: "Your monthly service fee is $1 fee is $12.00.",
            allowedFrom: [
                """
                Monthly service fee: $12.00
                Overdraft fee: $34.00
                Domestic wire transfer: $25.00
                Out-of-network ATM: $3.00
                """,
                "What's my monthly service fee?"
            ]
        )
        // $12.00 is correct and traceable; the stray "$1" is half of it,
        // emitted before the model restarted the number.
        #expect(stray == ["1"])
    }

    @Test("Catches an answer truncated mid-figure (sample 36)")
    func catchesTruncation() {
        let stray = AnswerVerifier.strayNumerals(
            in: "Yes, there are branches downtown. The Main St Branch is 0.4 miles away, the Market Square Branch is 1.",
            allowedFrom: [
                """
                Main St Branch — 0.4 mi, open until 5 pm
                Market Square Branch — 1.2 mi, open until 6 pm
                Airport Branch — 5.6 mi, open until 8 pm
                """,
                "Is there a branch downtown?"
            ]
        )
        // Cut before the ".2" of "1.2 mi". The judge scored this 4.
        #expect(stray == ["1"])
    }

    // MARK: Must NOT be flagged

    @Test("Accepts a figure reworded from the tool's formatting")
    func acceptsRewording() {
        // "$12.00" from the tool, written "12" in the answer.
        #expect(AnswerVerifier.strayNumerals(
            in: "Your monthly service fee is $12.",
            allowedFrom: ["Monthly service fee: $12.00"]
        ).isEmpty)
    }

    @Test("Accepts a figure the user supplied in the question")
    func acceptsFigureFromQuestion() {
        // Sample 4: $5,000 is the customer's number, not a tool's.
        #expect(AnswerVerifier.strayNumerals(
            in: "Yes, you have enough in savings to cover $5,000, as your balance is $8,120.55.",
            allowedFrom: ["Savings: $8,120.55", "Do I have enough in savings to cover $5,000?"]
        ).isEmpty)
    }

    @Test("Accepts word-numbers, which carry no actionable figure")
    func ignoresWordNumbers() {
        #expect(AnswerVerifier.strayNumerals(
            in: "You have two payments processing.",
            allowedFrom: ["Netflix — $15.49 (processing)"]
        ).isEmpty)
    }

    @Test("Accepts a multi-line list whose every figure is sourced")
    func acceptsList() {
        // Sample 21 — the kind of answer a terminal-punctuation heuristic
        // would have false-positived on, which is why there isn't one.
        #expect(AnswerVerifier.strayNumerals(
            in: "- 7 Aug: Starbucks, Checking, -$6.45\n- 1 Aug: Uber, Credit Card, -$23.75",
            allowedFrom: ["7 Aug · Starbucks · Checking · -$6.45\n1 Aug · Uber · Credit Card · -$23.75"]
        ).isEmpty)
    }

    @Test("Accepts an abstention, which shows no figure at all")
    func acceptsAbstention() {
        #expect(AnswerVerifier.strayNumerals(in: "", allowedFrom: ["Savings: $8,120.55"]).isEmpty)
    }

    // MARK: Scanner

    @Test("Does not swallow a sentence-ending period into the figure")
    func stopsAtSentenceEnd() {
        // "12." must scan as "12", or every sentence-final figure would
        // fail to match its source.
        #expect(AnswerVerifier.numerals(in: "The fee is $12.") == ["12"])
        #expect(AnswerVerifier.numerals(in: "It is 1.2 miles.") == ["1.2"])
    }

    @Test("Canonical form ignores separators and trailing decimal zeros")
    func canonicalForm() {
        #expect(AnswerVerifier.canonical("8,120.55") == "8120.55")
        #expect(AnswerVerifier.canonical("12.00") == "12")
        #expect(AnswerVerifier.canonical("1,000") == "1000")
        #expect(AnswerVerifier.canonical("0.92") == "0.92")
    }

    // MARK: Known limit

    @Test("Known hole: a stutter landing on another sourced figure passes")
    func knownHole() {
        // "$3" is the out-of-network ATM fee, so it verifies even though
        // the sentence is about the monthly fee. Value-matching cannot see
        // this; only slot rendering can. Documented so the limit is not
        // mistaken for a guarantee.
        #expect(AnswerVerifier.strayNumerals(
            in: "Your monthly service fee is $3.",
            allowedFrom: ["Monthly service fee: $12.00\nOut-of-network ATM: $3.00"]
        ).isEmpty)
    }
}
