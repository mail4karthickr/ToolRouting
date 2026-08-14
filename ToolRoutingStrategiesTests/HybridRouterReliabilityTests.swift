/*
Is a single HybridRouterTests run trustworthy?

That file reports three judge means and gates on them. Every decision made
from those numbers — did removing the compute binding help, is 3.5 a fair
floor — assumes a rerun would say roughly the same thing. This file runs
the SAME evaluation repeatedly and measures whether it does.

Replaces LLMRouterReliabilityTests, which asked the question of Stage 2
alone. Stage 2 is not what ships: the cascade adds a policy layer and an
agent, and the agent is where the answer is actually written. Wobble in
Stage 2's plan was never the whole story, and a plan that is stable can
still produce a different answer every time.

TWO SOURCES OF NOISE, AND THEY NEED SEPARATING. Conflating them is how a
reliability figure becomes useless:

  1. PIPELINE — does the same question produce the same answer? Judge-free
     and exact: repeated trials are compared as strings. Stage 2 samples
     greedily and MiniLM is a dot product over fixed weights, so routing
     SHOULD reproduce; Stage 3's agent is the open question.

  2. JUDGE — does the same answer receive the same score? Measured
     2026-08-12 and the answer was no: sample 9's reply was byte-identical
     across two runs and scored Faithfulness 4, then 2, with a rationale
     both times that described a 4. Sample 15 went 3 → 1 on unchanged
     behaviour.

Only (1) is asserted here, because only (1) is reachable in-process — the
evaluator hands the judge a subject and gets a metric back, never a score
this code can group by prompt. For (2), read the exported artifact, where
every trial is a row and repeated prompts are identifiable by their text:

    xceval export <path>.xcresult --output-path ./out
    xceval inspect out/<id> --output json | \
      jq '.artifact.samples[] | {i:.index, m:[.metrics[]|{(.name):.value}]}'

Group those rows by prompt and read the spread WITHIN each group. A group
whose answers are identical and whose scores are not is judge noise, and
that number is the one that says how far apart two HybridRouterTests
means have to be before the difference is real. EvalStats below does that
arithmetic.

COST. `trialsPerSample` × whatever dataset HybridRouterTests points at,
each trial a full cascade plus a judge call. At the failing set's 20
samples and 3 trials that is 60 runs, about 20 minutes. Against the full
60-sample dataset it is 180 runs and close to an hour — check
`HybridRouterTests.datasetName` before starting, and do not put this in a
routine test run.

Needs everything HybridRouterTests needs: MLX, a one-time MiniLM weight
download, Apple Intelligence, and the judge's API key. Device or Mac only.
*/

import Evaluations
import Foundation
import FoundationModels
import Testing
@testable import ToolRoutingStrategies

// MARK: - Statistics (framework-independent)

/// The decision rules, kept as plain functions so they can be used on
/// numbers from any two runs — including two runs of a different eval.
enum EvalStats {
    /// 95% confidence half-width for a MEAN measured over n samples, given
    /// the spread actually observed.
    ///
    /// Takes σ rather than assuming Bernoulli variance, because the judge
    /// dimensions are 1–4 scores and not pass/fail. The old pass-rate form
    /// went with LLMRouterReliabilityTests.
    static func ciHalfWidth(sigma: Double, samples n: Int) -> Double {
        guard n > 1 else { return 0 }
        return 1.96 * sigma / Double(n).squareRoot()
    }

    /// Whether a difference between two runs is bigger than their combined
    /// noise. Use before concluding that a change helped: on the
    /// 2026-08-12 pair of runs, Faithfulness moved 2.45 → 2.90, which this
    /// is the test of.
    static func isRealChange(
        meanA: Double, sigmaA: Double, nA: Int,
        meanB: Double, sigmaB: Double, nB: Int
    ) -> Bool {
        let a = ciHalfWidth(sigma: sigmaA, samples: nA)
        let b = ciHalfWidth(sigma: sigmaB, samples: nB)
        return abs(meanB - meanA) > (a * a + b * b).squareRoot()
    }
}

// MARK: - Pipeline reproducibility

/// Collects every trial's answer, keyed by the prompt that produced it.
///
/// A lock rather than an actor because the evaluation framework calls the
/// `onSubject` hook from a non-isolated context and the test body reads
/// the result synchronously afterwards. The contents are small — one
/// string per trial.
final class AnswerLedger: @unchecked Sendable {
    struct Trial {
        let answer: String
        let trajectory: [String]
    }

    /// One prompt's trials, and what disagreed across them.
    struct Group {
        let prompt: String
        let trials: Int
        /// 1 when every trial wrote the same answer, character for
        /// character. Anything higher is pipeline nondeterminism.
        let distinctAnswers: Int
        /// 1 when every trial called the same tools in the same order.
        let distinctTrajectories: Int

        var isStable: Bool { distinctAnswers == 1 }
    }

    private let lock = NSLock()
    private var trials: [String: [Trial]] = [:]
    /// Insertion order, so the report reads in dataset order rather than
    /// whatever order a dictionary happens to hand back.
    private var order: [String] = []

    func record(prompt: String, answer: BankingAnswer) {
        lock.lock()
        defer { lock.unlock() }
        if trials[prompt] == nil { order.append(prompt) }
        trials[prompt, default: []].append(
            Trial(answer: answer.answer, trajectory: answer.executedTools)
        )
    }

    var groups: [Group] {
        lock.lock()
        defer { lock.unlock() }
        return order.compactMap { prompt in
            guard let recorded = trials[prompt] else { return nil }
            return Group(
                prompt: prompt,
                trials: recorded.count,
                distinctAnswers: Set(recorded.map(\.answer)).count,
                distinctTrajectories: Set(recorded.map { $0.trajectory.joined(separator: ">") }).count
            )
        }
    }
}

/// File-scope so the evaluation's `onSubject` closure can capture it
/// without touching a static that is still being initialised.
private let ledger = AnswerLedger()

// MARK: - Suite

@Suite("Hybrid Router Reliability")
struct HybridRouterReliabilityTests {
    /// How many times each sample runs.
    ///
    /// Repetition is expressed by putting the sample in the dataset N
    /// times — the framework runs a dataset once, and every copy is a
    /// fresh router, agent and session, so nothing carries between trials
    /// and each appears as its own row in the report.
    ///
    /// THREE, not the five LLMRouterReliabilityTests used. That file's
    /// trial was a routing call; this one is a full cascade plus a judge
    /// call, roughly ten times the wall clock each. The interval narrows
    /// with √n, so five would buy about 30% tighter bounds for 67% more
    /// time — take that trade deliberately, not by default.
    static let trialsPerSample = 3

    /// HybridRouterTests' dataset, verbatim, whatever it currently points
    /// at. Deliberately a reference and not a copy: the old file kept its
    /// own hand-maintained duplicate of LLMRouterTests' samples, with a
    /// comment admitting a sample added there had to be added here by hand
    /// "or this stops describing the same measurement". It drifted anyway.
    static let samples = HybridRouterTests.samples

    /// Total cascade runs, each with a judge call behind it.
    static let trialCount = samples.count * trialsPerSample

    /// The SAME evaluation type HybridRouterTests runs — same routing,
    /// same agent, same judge, same three dimensions, same prompt — with
    /// the dataset repeated and the subject hook wired up. Reusing the
    /// type rather than restating it is what makes the wobble measured
    /// here the wobble that applies there.
    static let evaluation = HybridAnswerEvaluation(
        dataset: ArrayLoader(
            samples: samples.flatMap { Array(repeating: $0, count: trialsPerSample) }
        ),
        onSubject: { prompt, answer in ledger.record(prompt: prompt, answer: answer) }
    )

    @Test(
        "Repeated trials — pipeline reproducibility and judge spread",
        // Device capability only — a missing judge key stops the run
        // rather than skipping it, the same as HybridRouterTests. See
        // `ClaudeJudge.missingKeyMessage` for why a skip is the wrong
        // failure here.
        .enabled(if: SystemLanguageModel.default.isAvailable),
        .evaluates(evaluation, info: [
            "ModelName": "all-MiniLM-L6-v2 (MLX) + SystemLanguageModel",
            "Strategy": "Hybrid cascade end to end, repeated trials",
            "Judge": "Claude Opus 5 (ClaudeForFoundationModels)",
            "AppVersion": "1.0",
            "Feature": "Eval reliability: \(HybridRouterTests.datasetName), \(samples.count) samples × \(trialsPerSample) trials"
        ])
    )
    func evaluateReliability() async throws {
        let result = EvaluationContext.current.result

        // 1. JUDGE SPREAD, for context.
        //
        // σ here is across the WHOLE dataset, so it mixes the spread
        // between different samples — which is meant to be large, samples
        // legitimately score 1 and 4 — with the spread between trials of
        // one sample, which is the noise. It is reported, not gated, for
        // exactly that reason. The per-prompt split is in the artifact;
        // see this file's header.
        print("\nJudge scores over \(Self.trialCount) trials (\(Self.samples.count) samples × \(Self.trialsPerSample)):")
        for dimension in [
            Self.evaluation.faithfulness,
            Self.evaluation.completeness,
            Self.evaluation.naturalness
        ] {
            let mean = result.aggregateValue(.mean(of: dimension.metric))
            let sigma = result.aggregateValue(.standardDeviation(of: dimension.metric))
            let ci = EvalStats.ciHalfWidth(sigma: sigma, samples: Self.trialCount)
            print(String(
                format: "  %-14@ mean %.3f ± %.3f (95%% CI)   σ %.3f",
                dimension.name as NSString, mean, ci, sigma
            ))

            // Wiring check, the one assertion here that cannot flake: a
            // dimension that never scored aggregates to a placeholder, so
            // a judge that failed to run would otherwise report as
            // silence and pass.
            #expect(
                mean > 0,
                "\(dimension.name) produced no score. The judge did not run, or the dimension is not wired into `dimensions:`."
            )
        }

        // 2. PIPELINE REPRODUCIBILITY — the number this file exists for.
        //
        // No judge involved: same question in, same answer out, compared
        // as text. This is the half that can be stated as a fact.
        let groups = ledger.groups
        let stable = groups.filter(\.isStable).count
        let sameRoute = groups.filter { $0.distinctTrajectories == 1 }.count

        print("\nPipeline reproducibility (judge-free, \(groups.count) prompts × \(Self.trialsPerSample) trials):")
        print("  identical answer every trial     \(stable)/\(groups.count)")
        print("  identical tool trajectory        \(sameRoute)/\(groups.count)")
        for group in groups where !group.isStable {
            print("    ✗ \(group.prompt) — \(group.distinctAnswers) different answers, \(group.distinctTrajectories) different trajectories")
        }
        print("")

        // Every prompt should have been seen exactly `trialsPerSample`
        // times. If not, the dataset repetition or the hook is broken and
        // every number above is measuring something other than what it
        // claims to.
        #expect(
            groups.allSatisfy { $0.trials == Self.trialsPerSample },
            "some prompts did not run \(Self.trialsPerSample) times: \(groups.filter { $0.trials != Self.trialsPerSample }.map(\.prompt))"
        )

        // NOT #expect(stable == groups.count). Stage 3 writes prose with a
        // model that is not pinned to greedy, so some variation is
        // expected and the count above is the finding rather than a
        // failure. What this bounds is a pipeline so unstable that
        // comparing two HybridRouterTests runs means nothing: if fewer
        // than half the prompts reproduce, a moved mean cannot be
        // attributed to a change in the code.
        //
        // Raise it as the number improves. Lowering it to get green
        // discards the only measurement here that is not an opinion.
        #expect(
            Double(stable) / Double(max(1, groups.count)) >= 0.5,
            "only \(stable) of \(groups.count) prompts reproduced their answer; run-to-run comparison is not meaningful at this level"
        )
    }
}
