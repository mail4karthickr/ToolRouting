/*
A judge whose scores are checked against the scale they claim to be on.

WHAT THIS IS NOT FOR, since it was written while chasing the wrong thing:
the `EncodingError.invalidValue: nan` that killed five runs was
`computeStandardDeviation` over a dimension with no spread, and the fix
for that lives in `HybridRouterTests.aggregateMetrics`. This wrapper did
not fix it and was never going to.

WHAT IT IS FOR is a real defect the same investigation turned up.
Measured 2026-08-13: the judge, asked the same shape of question twelve
times, failed none and was never slow — and ONCE came back scoring two
of its three dimensions ZERO, on a scale whose lowest value is 1. A 0 is
a finite number, so nothing crashes; it simply drags a mean down by a
third of a point on a 20-sample batch and looks exactly like the router
having got worse. That is the more dangerous failure of the two, because
it is silent.

STEERING IS NOT CONSTRAINING. The judge's instructions now say in
capitals that every dimension gets one of 1, 2, 3 or 4. It still
happened. The scoring schema belongs to `ModelJudgeEvaluator` rather
than to this suite, so there is nowhere to put a real constraint — which
leaves checking the answer after it arrives.

`ModelJudgeEvaluator` still does the judging — same prompt, same
dimensions, same scale, so every number this suite has ever reported
stays comparable — and this wrapper only decides what to do when what
comes back is not a score:

  RETRY ONCE   because it is a one-in-twelve event, so a second ask
               almost always lands, and a recovered sample is worth more
               than a dropped one.
  THEN IGNORE  `Metric.ignore` is the harness's own word for "this
               sample has no value on this dimension". One sample leaves
               the mean; the other nineteen are reported. A score that
               is not a score should cost its own sample and nothing
               else — least of all a quiet third of a point off the
               dimension it lands on.

It logs both, loudly. A judge quietly ignoring a tenth of the dataset
would be a worse problem than the one this solves.
*/

import Evaluations
import Foundation
@testable import ToolRoutingStrategies

struct ValidatedModelJudge: EvaluatorProtocol {
    typealias Input = ModelSample<BankingAnswer>
    typealias Subject = ModelSubject<BankingAnswer>

    /// The real judge. Untouched — this type adds no prompt, no
    /// instruction and no opinion about the answer.
    let judge: ModelJudgeEvaluator<Input>

    /// The same dimensions the judge was built with, needed here to know
    /// what each one's scale actually allows.
    let dimensions: [ScoreDimension]

    /// Two attempts, not more. The failure is uncommon and independent,
    /// so a second ask clears it nearly always; a third would mostly buy
    /// judge calls on a sample that is not going to score.
    var attempts = 2

    func metrics(subject: Subject, input: Input) async throws -> [Metric] {
        var latest: [Metric] = []

        for attempt in 1...attempts {
            let metrics = try await judge.metrics(subject: subject, input: input)
            latest = metrics
            if metrics.allSatisfy(isOnScale) { return metrics }

            let offScale: String = metrics
                .filter { !isOnScale($0) }
                .map { metric -> String in
                    let value = metric.doubleValue.map { "\($0)" } ?? "—"
                    return "\(metric.name)=\(value)"
                }
                .joined(separator: ", ")
            print("""
                ⚠️ JUDGE OFF SCALE (attempt \(attempt)/\(attempts)) on "\(input.promptDescription)": \
                \(offScale). \(attempt < attempts ? "Asking again." : "Dropping those dimensions for this sample.")
                """)
        }

        return latest.map { metric in
            guard !isOnScale(metric) else { return metric }
            // The harness's own word for "no value here", which keeps the
            // sample's other dimensions and every other sample intact.
            let answered = metric.doubleValue.map { "\($0)" } ?? "nothing"
            return Metric(metric.name).ignore(
                rationale: """
                    The judge answered \(answered) on a scale that does not contain it, twice. \
                    Scored as no result rather than as a number.
                    """
            )
        }
    }

    /// Whether a metric carries a value the scale it belongs to admits.
    ///
    /// A metric with no number — passing, failing, already ignored — is
    /// left alone: this is about scores, and those are not scores.
    private func isOnScale(_ metric: Metric) -> Bool {
        guard let value = metric.doubleValue else { return true }
        guard value.isFinite else { return false }
        guard let dimension = dimensions.first(where: { $0.name == metric.name }) else {
            // A metric this wrapper was not told about. Not its business
            // to police, and silently dropping it would hide a wiring
            // mistake behind a clean report.
            return true
        }
        let allowed = dimension.scale.options.map(\.value)
        guard let lowest = allowed.min(), let highest = allowed.max() else { return true }
        return value >= lowest && value <= highest
    }
}
