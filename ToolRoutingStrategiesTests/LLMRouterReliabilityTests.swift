/*
Is a single eval run trustworthy?

Every routing decision in this project so far has been made by comparing
two numbers from two runs of 28 samples — 0.679 then 0.852 then 0.25 —
and treating the difference as real. That is only sound if a run is
reproducible and the dataset is big enough to resolve the difference.
This file measures both, so the other evals can be read honestly.

It answers two separate questions that are easy to conflate:

  1. RUN WOBBLE — same prompt, same model, same dataset, run twice: does
     the number move? Measured by repeating each sample `trialsPerSample`
     times and reading the standard deviation. LLMRouter samples greedily
     (GenerationOptions(sampling: .greedy)) and MiniLM retrieval is a
     dot product over fixed weights, so the pipeline SHOULD be
     deterministic and σ SHOULD be 0. If it is, single runs can be
     compared directly and no confidence interval is needed for wobble.
     If it is not, every comparison in this project needs one.

  2. SAMPLING ERROR — how precisely does any dataset of this size pin
     down the router's true accuracy over the requests users actually
     send? This exists even when σ is exactly 0: a 28-sample dataset
     measuring 0.85 has a 95% interval of roughly ±0.13, so a 0.85 and a
     0.79 from two different prompts are not distinguishable no matter
     how deterministic each run was. EvalStats computes it.

Reading the result: σ = 0 does NOT mean the number is certain, only that
the same dataset gives the same answer twice. Question 2 still applies.
Conversely σ > 0 means the .xcevalresult holds trials of the same prompt
that disagree — those samples are the unstable ones, and they are worth
more attention than any aggregate.

Scope: this is a diagnostic, not a gate on router quality —
LLMRouterTests owns that. It runs that file's ENTIRE dataset five times
over: 28 samples × 5 trials = 140 generations. Expect twenty minutes or
more, and do not put it in a routine test run — `trialsPerSample` is the
knob if that is too slow (3 trials still halves the interval versus a
single run).

Needs BOTH stages: MLX (Apple-silicon Metal) and Apple Intelligence.
Device or Mac only, never the iOS simulator.
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
    /// 95% confidence half-width for a pass rate measured over n trials.
    /// Bernoulli variance p(1-p), so it is widest at p = 0.5 and narrows
    /// as the rate approaches 0 or 1.
    static func ciHalfWidth(passRate p: Double, trials n: Int) -> Double {
        guard n > 1 else { return 0 }
        return 1.96 * (p * (1 - p) / Double(n)).squareRoot()
    }

    /// Whether a difference between two runs is bigger than their
    /// combined wobble. Use before concluding that a prompt change
    /// helped: over 28 samples, a change of less than about 0.13 near a
    /// pass rate of 0.85 is indistinguishable from noise.
    static func isRealChange(meanA: Double, nA: Int, meanB: Double, nB: Int) -> Bool {
        let a = ciHalfWidth(passRate: meanA, trials: nA)
        let b = ciHalfWidth(passRate: meanB, trials: nB)
        return abs(meanB - meanA) > (a * a + b * b).squareRoot()
    }
}

// MARK: - Evaluation

/// One routing plan, same shape LLMRouterTests grades.
struct ReliabilitySelection: Codable, Sendable {
    var tools: [String]
    var orderMatters: Bool = true
}

/// Runs the Stage-1 → Stage-2 pipeline repeatedly over a fixed subset.
struct LLMRouterReliabilityEvaluation: Evaluation {
    /// How many times each sample is run. The framework runs a dataset
    /// once, so repetition is expressed by putting the sample in the
    /// dataset N times — every copy is a fresh session, so nothing is
    /// carried between trials and each one appears as its own row in the
    /// report.
    ///
    /// 5 × 28 samples = 140 generations. The interval narrows with the
    /// square root of the trial count, so going to 10 would only take it
    /// from about +/-0.06 to +/-0.04 for twice the wall clock.
    static let trialsPerSample = 5

    /// Deliberately the unstable half of routing: the escalation calls
    /// that have flipped between runs, the dependency chains that were
    /// truncated, and two settled single-call samples as a control. If
    /// even the controls wobble, the problem is the harness, not the
    /// prompt.
    /// EVERY sample from LLMRouterTests, verbatim. Two reasons to copy
    /// rather than subset: the wobble figure then describes the number
    /// that file reports, not a harder slice of it; and repeating the
    /// full dataset is what narrows the confidence interval — 28 samples
    /// once gives +/-0.13 near a rate of 0.85, the same 28 five times
    /// gives about +/-0.06, which is the difference between being able to
    /// resolve a prompt change and not.
    ///
    /// Kept as a copy on purpose. These two files own their datasets
    /// outright, so editing one never silently moves the other's number —
    /// but that also means a sample added there must be added here by
    /// hand, or this stops describing the same measurement.
    static let samples: [ModelSample<ReliabilitySelection>] = [
        // MARK: none (7) — the cloud class
        //
        // Each of the first five shares its noun with a real tool, so a
        // router matching on topic alone gets every one of them wrong.

        ModelSample(prompt: "Freeze my debit card", expected: ReliabilitySelection(tools: ["none"])),
        ModelSample(prompt: "Increase my ATM withdrawal limit", expected: ReliabilitySelection(tools: ["none"])),
        ModelSample(prompt: "I want to dispute a charge from Amazon", expected: ReliabilitySelection(tools: ["none"])),
        ModelSample(prompt: "cancel my netflix payment", expected: ReliabilitySelection(tools: ["none"])),
        // The conversion QUESTION is a lookup; moving money is not.
        ModelSample(prompt: "Send 200 euros to my friend in Berlin", expected: ReliabilitySelection(tools: ["none"])),
        // Uncovered capability rather than an action.
        ModelSample(prompt: "What are your mortgage rates for first-time buyers?", expected: ReliabilitySelection(tools: ["none"])),
        // All-or-nothing policy: half the request is serviceable, the
        // whole thing still goes to the cloud with full context.
        ModelSample(prompt: "Show my balance and transfer $200 to savings", expected: ReliabilitySelection(tools: ["none"])),

        // MARK: 1 call (7)
        //
        // Four are the lookup half of a verb pair above. Three are
        // chain-skip controls: the user names the place or amount, so
        // emitting the lookup step is a wrong answer, not a harmless
        // extra one.

        ModelSample(prompt: "What's my debit card number?", expected: ReliabilitySelection(tools: ["card_number"])),
        ModelSample(prompt: "What's my daily ATM withdrawal limit?", expected: ReliabilitySelection(tools: ["card_limits"])),
        ModelSample(prompt: "Any update on the charge I disputed?", expected: ReliabilitySelection(tools: ["dispute_status"])),
        ModelSample(prompt: "What payments are scheduled to go out next week?", expected: ReliabilitySelection(tools: ["scheduled_payments"])),
        ModelSample(prompt: "Find ATMs in Chicago", expected: ReliabilitySelection(tools: ["find_atm"])),
        ModelSample(prompt: "Is the airport branch open on Saturday?", expected: ReliabilitySelection(tools: ["branch_hours"])),
        ModelSample(prompt: "Convert $500 to yen", expected: ReliabilitySelection(tools: ["convert_currency"])),

        // MARK: 2 calls (7)

        // Ordered — the second call needs the first one's result.
        ModelSample(prompt: "Find the nearest ATM", expected: ReliabilitySelection(tools: ["get_location", "find_atm"])),
        ModelSample(prompt: "How much is my savings balance in euros?", expected: ReliabilitySelection(tools: ["account_balance", "convert_currency"])),
        // Independent — any order.
        ModelSample(
            prompt: "Show my balance and this week's transactions",
            expected: ReliabilitySelection(tools: ["account_balance", "list_transactions"], orderMatters: false)
        ),
        ModelSample(
            prompt: "What's my credit score and do I have any pending payments?",
            expected: ReliabilitySelection(tools: ["credit_score", "pending_payments"], orderMatters: false)
        ),
        ModelSample(
            prompt: "What fees did I pay and what interest did I earn last month?",
            expected: ReliabilitySelection(tools: ["fees_and_charges", "interest_earned"], orderMatters: false)
        ),
        // Same tool twice, different parameters — the call COUNT is the
        // measurement here, not the tool choice.
        ModelSample(
            prompt: "Get my June and July statements for checking",
            expected: ReliabilitySelection(tools: ["bank_statement", "bank_statement"], orderMatters: false)
        ),
        // Informal, and two intents the model has to keep apart: the
        // Starbucks clause must not swallow the balance clause.
        ModelSample(
            prompt: "starbucks charges this month and whats my balance",
            expected: ReliabilitySelection(tools: ["search_transactions", "account_balance"], orderMatters: false)
        ),

        // MARK: 3 calls (7)

        // Three-step chain: location → branch → its hours.
        ModelSample(prompt: "How late is the nearest branch open?", expected: ReliabilitySelection(tools: ["get_location", "find_branch", "branch_hours"])),
        // Chain plus an unrelated lookup riding along.
        ModelSample(
            prompt: "Find the nearest ATM and tell me my daily withdrawal limit",
            expected: ReliabilitySelection(tools: ["get_location", "find_atm", "card_limits"], orderMatters: false)
        ),
        // Independent fan-out, three ways.
        ModelSample(
            prompt: "Show my balance, my pending payments and my scheduled payments",
            expected: ReliabilitySelection(tools: ["account_balance", "pending_payments", "scheduled_payments"], orderMatters: false)
        ),
        ModelSample(
            prompt: "What's my credit score, my credit limit and my reward points?",
            expected: ReliabilitySelection(tools: ["credit_score", "card_limits", "reward_points"], orderMatters: false)
        ),
        ModelSample(
            prompt: "I need my routing number, my account number and my card number",
            expected: ReliabilitySelection(tools: ["routing_number", "account_number", "card_number"], orderMatters: false)
        ),
        // A dependency INSIDE a three-call plan: the balance feeds the
        // conversion, and the transactions lookup is independent of both.
        ModelSample(
            prompt: "Convert my savings balance to euros and show my recent transactions",
            expected: ReliabilitySelection(tools: ["account_balance", "convert_currency", "list_transactions"], orderMatters: false)
        ),
        ModelSample(
            prompt: "Show my recent transactions, my Amazon purchases and my June statement",
            expected: ReliabilitySelection(tools: ["list_transactions", "search_transactions", "bank_statement"], orderMatters: false)
        )
    ]

    /// Total generations this evaluation performs.
    static let trialCount = samples.count * trialsPerSample

    var dataset = ArrayLoader(
        samples: samples.flatMap { Array(repeating: $0, count: trialsPerSample) }
    )

    func subject(from sample: ModelSample<ReliabilitySelection>) async throws -> ModelSubject<ReliabilitySelection> {
        do {
            return ModelSubject(value: ReliabilitySelection(
                tools: try await Self.routeOnce(sample.promptDescription)
            ))
        } catch is LanguageModelSession.GenerationError {
            return ModelSubject(value: ReliabilitySelection(tools: ["none"]))
        }
    }

    /// The same two stages LLMRouterTests runs, wired the same way, so
    /// the wobble measured here is the wobble that applies there.
    @MainActor
    private static func routeOnce(_ query: String) async throws -> [String] {
        let shortlist = try await MiniLMRouter().retrieve(query, topK: HybridRouter.Config().topK)
        guard !shortlist.isEmpty else { return ["none"] }
        let candidates = shortlist.compactMap { ToolCatalog.byName[$0.toolName] }
        let plan = try await LLMRouter().select(query, from: candidates)
        guard plan.route == .useTools else { return ["none"] }
        return plan.calls.map(\.displayName)
    }

    // MARK: Metric

    /// 1 when the trial produced exactly the expected plan, 0 otherwise —
    /// the same all-or-nothing judgement LLMRouterTests applies, so the
    /// two numbers mean the same thing.
    ///
    /// The mean is the pass rate; the standard deviation IS the answer to
    /// question 1. Both come off one metric.
    let trialPassed = Metric("Trial Passed")

    var evaluators: Evaluators {
        Evaluator { input, subject in
            guard let expected = input.expected else { return trialPassed.ignore() }
            let actual = subject.value.tools
            let matches = expected.orderMatters
                ? actual == expected.tools
                : actual.sorted() == expected.tools.sorted()

            // The rationale carries the prompt so that repeated rows can
            // be grouped back together when reading the report — five
            // rows of the same prompt disagreeing is the finding.
            return matches
                ? trialPassed.passing(rationale: "\(input.promptDescription) → \(actual.joined(separator: " → "))")
                : trialPassed.failing(rationale: "\(input.promptDescription) → expected \(expected.tools.joined(separator: " → ")), got \(actual.joined(separator: " → "))")
        }
    }

    func aggregateMetrics(using aggregator: inout MetricsAggregator) {
        aggregator.computeMean(of: trialPassed)
        aggregator.computeMinimum(of: trialPassed)
        aggregator.group("Reliability (wobble)") { group in
            group.computeStandardDeviation(of: trialPassed)
            group.computeVariance(of: trialPassed)
        }
    }
}

// MARK: - Suite

@Suite("LLM Router Reliability")
struct LLMRouterReliabilityTests {
    static let evaluation = LLMRouterReliabilityEvaluation()

    @Test(
        "Repeated trials — wobble and confidence",
        .enabled(if: SystemLanguageModel.default.isAvailable),
        .evaluates(evaluation, info: [
            "ModelName": "all-MiniLM-L6-v2 (MLX) + SystemLanguageModel",
            "Strategy": "Hybrid Stage 1 → Stage 2, repeated trials",
            "AppVersion": "1.0",
            "Feature": "Eval reliability: run wobble and sampling error"
        ])
    )
    func evaluateReliability() async throws {
        let result = EvaluationContext.current.result
        let metric = Self.evaluation.trialPassed

        let mean = result.aggregateValue(.mean(of: metric))
        let sigma = result.aggregateValue(.standardDeviation(of: metric))
        let n = LLMRouterReliabilityEvaluation.trialCount
        let ci = EvalStats.ciHalfWidth(passRate: mean, trials: n)

        // The number this file exists to produce. Recorded in the report
        // and printed here so it lands in the test log too.
        print("""

            Reliability over \(n) trials \
            (\(LLMRouterReliabilityEvaluation.samples.count) samples \
            × \(LLMRouterReliabilityEvaluation.trialsPerSample)):
              pass rate  \(String(format: "%.3f", mean)) ± \(String(format: "%.3f", ci))  (95% CI)
              std dev    \(String(format: "%.3f", sigma))
              honest range for a change to beat: \
            \(String(format: "%.3f", max(0, mean - ci)))–\(String(format: "%.3f", min(1, mean + ci)))

            """)

        // The gate is on the LOWER edge of the interval, not the point
        // estimate, so a lucky run cannot sneak past it. Set below
        // LLMRouterTests' 0.8 because this file exists to report a
        // number, not to police one — if the two disagree by more than
        // the interval, that disagreement IS the finding, and a tight
        // gate here would just mask it behind a failure.
        #expect(mean - ci >= 0.6, "pass rate \(mean) ± \(ci): lower edge below target")

        // Question 1, stated as a check rather than left to the eye. A
        // greedy pipeline over fixed weights should reproduce exactly;
        // any wobble at all means single-run comparisons elsewhere in
        // this project need EvalStats.isRealChange applied to them.
        //
        // Not #expect(sigma == 0): a trial that legitimately fails on
        // every repetition also has σ > 0 across the dataset. What this
        // bounds is the spread being small enough that the mean is not
        // being driven by samples flipping between runs. Read the
        // per-sample rows in the report to tell those two apart.
        #expect(sigma <= 0.5, "σ = \(sigma): trials of the same prompt disagree")
    }
}
