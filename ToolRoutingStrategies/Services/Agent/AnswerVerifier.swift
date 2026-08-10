import Foundation
import FoundationModels

// MARK: - Numeric provenance guard
//
// Stage 3 asks a ~3B on-device model to retype figures the tools already
// returned exactly. That retyping is where money gets corrupted. Two real
// failures from the 2026-08-07 hybrid run, both on correct tool calls:
//
//   "Your monthly service fee is $1 fee is $12.00."      (stutter)
//   "…the Market Square Branch is 1."                    (truncated 1.2 mi)
//
// The judge scored the first 1 — calling a decoding stutter an invented
// figure, the only rung its scale had — and the second 4, missing it.
// Neither is a hallucination: the tool ran and returned the right value.
// They are generation defects, and a deterministic check catches both for
// free where a model judge is both slower and less reliable.
//
// THE RULE: every numeral the user is shown must already appear in the
// tool output, or in their own question. Nothing else is displayable.
//
// This is a NARROWING, not a proof. A stutter that happens to land on
// another figure the tools returned ($3 from the ATM fee in a
// service-fee sentence) still passes. Closing that hole needs the model
// to stop authoring digits at all — see the slot-rendering note at the
// bottom of this file.
enum AnswerVerifier {

    // MARK: Failure

    struct UnverifiedFigures: LocalizedError {
        /// Numerals in the answer with no source. Canonical form.
        let stray: [String]
        let answer: String

        var errorDescription: String? {
            """
            Answer contains \(stray.count == 1 ? "a figure" : "figures") no tool \
            returned: \(stray.joined(separator: ", ")). Refusing to display it. \
            Answer was: "\(answer)"
            """
        }
    }

    // MARK: Checking

    /// Numerals in `answer` that appear in none of `sources`.
    ///
    /// `sources` should be the raw tool results plus the user's own query —
    /// a question like "enough to cover $5,000?" entitles the answer to
    /// echo $5,000 even though no tool returned it.
    static func strayNumerals(in answer: String, allowedFrom sources: [String]) -> [String] {
        let allowed = Set(sources.flatMap { numerals(in: $0) }.map(canonical))
        var stray: [String] = []
        var seen = Set<String>()
        for numeral in numerals(in: answer) {
            let key = canonical(numeral)
            guard !allowed.contains(key), seen.insert(key).inserted else { continue }
            stray.append(numeral)
        }
        return stray
    }

    /// Throws `UnverifiedFigures` if the answer shows a figure with no source.
    static func verify(_ answer: String, allowedFrom sources: [String]) throws {
        let stray = strayNumerals(in: answer, allowedFrom: sources)
        guard stray.isEmpty else {
            throw UnverifiedFigures(stray: stray, answer: answer)
        }
    }

    // MARK: Scanning

    /// Every numeric literal in `text`: digit runs, embedded thousands
    /// separators, and one optional decimal part. Hand-rolled rather than
    /// regex so it behaves identically under any Swift language mode.
    ///
    /// Word-numbers ("two pending payments") are deliberately not matched —
    /// they carry no figure a customer would act on, and matching them
    /// produced false positives against the run's own data.
    static func numerals(in text: String) -> [String] {
        var found: [String] = []
        let characters = Array(text)
        var index = 0

        while index < characters.count {
            guard characters[index].isNumber else {
                index += 1
                continue
            }
            let start = index
            while index < characters.count, characters[index].isNumber || characters[index] == "," {
                index += 1
            }
            // A decimal part only counts when a digit follows the dot, so a
            // sentence-ending period is not swallowed into the figure.
            if index + 1 < characters.count, characters[index] == ".", characters[index + 1].isNumber {
                index += 1
                while index < characters.count, characters[index].isNumber { index += 1 }
            }
            found.append(String(characters[start..<index]))
        }
        return found
    }

    /// Comparison form: separators dropped, trailing decimal zeros trimmed,
    /// so the tools' "$12.00" and an answer's "12" are the same figure.
    static func canonical(_ numeral: String) -> String {
        var value = numeral.replacingOccurrences(of: ",", with: "")
        if value.contains(".") {
            while value.hasSuffix("0") { value.removeLast() }
            if value.hasSuffix(".") { value.removeLast() }
        }
        return value.isEmpty ? "0" : value
    }

    // MARK: Transcript

    /// The raw text every tool returned this turn — the only figures the
    /// answer is entitled to use.
    ///
    /// Read from the transcript rather than re-running the API so the check
    /// sees exactly what the model saw, including a tool the agent called
    /// that routing never planned.
    static func toolOutputs(in transcript: Transcript) -> [String] {
        transcript.flatMap { entry -> [String] in
            guard case .toolOutput(let output) = entry else { return [] }
            return output.segments.compactMap { segment in
                guard case .text(let text) = segment else { return nil }
                return text.content
            }
        }
    }
}

// MARK: - Why this is an interim guard
//
// Every money figure crosses the model as text because BankAPIClient
// returns pre-formatted strings ("Monthly service fee: $12.00"), while
// creditScore() and rewardPoints() return Int. The structural fix is to
// return typed values and have the MODEL NEVER TYPE A DIGIT: it emits a
// sentence with slots, and code substitutes the figures.
//
//   model:   "Your monthly service fee is {{fee.monthly_service}}."
//   render:  "Your monthly service fee is $12.00."
//
// Then a stutter can only corrupt prose, a truncation leaves an
// unterminated slot, and a wrong figure is impossible rather than
// improbable. Keep this verifier afterwards as the assertion that the
// guarantee holds — it should never fire again once slots land.
