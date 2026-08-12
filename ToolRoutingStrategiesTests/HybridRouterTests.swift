/*
Grades the answer HybridRouter produces end to end. Tool selection is
graded in LLMRouterTests.

  Faithfulness   judge — is every fact traceable to the tool output?
  Completeness   judge — is every part of the request answered, and was a
                 non-reply the right call?
  Naturalness    judge — does it read like a person, without leaking the
                 tools or the app?

Every metric here is a judge score, so every assertion is a floor on a
noisy number rather than a gate. The deterministic Fabrication check that
used to sit alongside them was removed with AnswerVerifier.

Faithfulness and Completeness are deliberately opposite: one asks whether
anything extra crept IN, the other whether anything required was left
OUT. An answer can score 4 on the first and 1 on the second by being
impeccably sourced and half of what was asked for.

Completeness also carries the escalation verdict, because a wrongly
withheld answer is the most incomplete answer there is. That only works
because the judge is TOLD whether a reply was owed — silence looks
identical either way, and inferring it from the silence is what the
earlier prompt got wrong.

The tool output each answer is graded against is the output of the calls
the agent REALLY made, collected from the run's own trace rather than
stored or re-derived from the expectation — see `observedToolOutput`,
which is where that used to be wrong. The judge is Claude,
reached through the Foundation Models server-side model API — a different
and more capable model than the on-device one that wrote the answer, so
the score is not self-assessment.

The judge is swappable: `JudgeModel` below reaches a corporate
OpenAI-compatible gateway through ``CustomLanguageModel`` and drops into
the same slot. Both conform to `LanguageModel`, so switching is one
argument to `ModelJudgeEvaluator` and nothing else in this file moves.

Needs MLX, a one-time MiniLM weight download, Apple Intelligence, and an
Anthropic API key (see ClaudeJudge). Device or Mac only.
*/

import Evaluations
import Foundation
import FoundationModels
import Testing
import ClaudeForFoundationModels
@testable import ToolRoutingStrategies

// MARK: - Judge (active)

/// Claude as the judge model, conformed to `LanguageModel` by
/// ClaudeForFoundationModels so it drops straight into
/// `ModelJudgeEvaluator`.
///
/// The key is read from the environment rather than bundled, so it never
/// lands in the repository: set `ANTHROPIC_API_KEY` under Edit Scheme ▸ Test
/// ▸ Arguments ▸ Environment Variables, or export it before `xcodebuild test`
/// on a Mac destination. Without it the evaluation is skipped rather than
/// failing.
enum ClaudeJudge {
    static let apiKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? ""
//    static let apiKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? ""

    static var isConfigured: Bool { !apiKey.isEmpty }

    static var model: ClaudeLanguageModel {
        ClaudeLanguageModel(name: .opus5, auth: .apiKey(apiKey))
    }
}

// MARK: - Judge (standby)

/// The same judge reached through the company's OpenAI-compatible
/// gateway, for environments where the Anthropic API is not reachable.
///
/// Unused while ``ClaudeJudge`` is wired in. To switch, pass
/// `JudgeModel.model` to `ModelJudgeEvaluator` below and swap
/// `ClaudeJudge.isConfigured` for `JudgeModel.isConfigured` in the test's
/// `.enabled(if:)`. Nothing else in this file changes — both conform to
/// `LanguageModel`, so the dimensions, the prompt, and the scoring are
/// identical either way.
///
/// Credentials are read from the environment rather than bundled, so they
/// never land in the repository: set them under Edit Scheme ▸ Test ▸
/// Arguments ▸ Environment Variables, or export them before `xcodebuild
/// test` on a Mac destination. Without them the evaluation is skipped
/// rather than failing.
///
///   CUSTOM_LLM_BASE_URL       https://api.mycompany.com/llm/v1
///   CUSTOM_LLM_MODEL          the gateway's name for the model
///   CUSTOM_LLM_API_KEY        static application key
///   APIGEE_TOKEN_URL          optional; omit for key-only gateways
///   APIGEE_CLIENT_ID
///   APIGEE_CLIENT_SECRET
enum JudgeModel {
    static func environment(_ key: String) -> String? {
        guard let value = ProcessInfo.processInfo.environment[key], !value.isEmpty else {
            return nil
        }
        return value
    }

    static var endpoint: CustomLanguageModel.Endpoint? {
        guard let base = environment("CUSTOM_LLM_BASE_URL"),
              let url = URL(string: base),
              let modelID = environment("CUSTOM_LLM_MODEL")
        else { return nil }
        return .init(baseURL: url, modelID: modelID)
    }

    /// Nil when the gateway authorizes on the API key alone.
    static var apigee: ApigeeCredentials? {
        guard let tokenURL = environment("APIGEE_TOKEN_URL").flatMap(URL.init(string:)),
              let clientID = environment("APIGEE_CLIENT_ID"),
              let clientSecret = environment("APIGEE_CLIENT_SECRET")
        else { return nil }
        return .init(tokenURL: tokenURL, clientID: clientID, clientSecret: clientSecret)
    }

    static var isConfigured: Bool { endpoint != nil }

    static var model: CustomLanguageModel {
        CustomLanguageModel(
            // Unreachable placeholder when nothing is configured: the suite
            // is skipped by `isConfigured`, but the evaluation value is
            // still built, and a force-unwrap here would take the whole
            // test target down before the skip could apply.
            endpoint: endpoint
                ?? .init(baseURL: URL(string: "https://unconfigured.invalid")!, modelID: "none"),
            credentials: .init(
                apiKey: environment("CUSTOM_LLM_API_KEY") ?? "",
                apigee: apigee
            ),
            behavior: .init(
                // A judge scores; it never calls tools. Off keeps `tools`
                // off the wire entirely.
                supportsToolCalling: false,
                // The judge is asked for a @Generable score object, so this
                // decides whether the shape is enforced on the wire or only
                // asked for in the prompt. Turn it off if the gateway
                // rejects `response_format: json_schema` — the eval still
                // runs, it just leans on the model to hold the shape.
                supportsStructuredOutputs: true
            )
        )
    }
}

// MARK: - Evaluation

struct HybridAnswerEvaluation: Evaluation {
    var dataset: ArrayLoader<ModelSample<BankingAnswer>>

    /// Called with the prompt and the answer as each subject is produced,
    /// BEFORE the judge sees it.
    ///
    /// Nil for a normal run. HybridRouterReliabilityTests sets it to tell
    /// two kinds of noise apart: whether repeated trials of one prompt
    /// produce the same ANSWER is a fact about the pipeline and needs no
    /// judge, while whether they produce the same SCORE is a fact about
    /// the judge. Conflating them is how a reliability number becomes
    /// meaningless — measured 2026-08-12, where an identical answer
    /// scored Faithfulness 4 on one run and 2 on the next.
    var onSubject: (@Sendable (String, BankingAnswer) -> Void)?

    func subject(from sample: ModelSample<BankingAnswer>) async throws -> ModelSubject<BankingAnswer> {
        let router = await HybridRouter()
        do {
            let result = try await router.route(sample.promptDescription)
            let answer = BankingAnswer(
                tools: result.calls.isEmpty ? ["none"] : result.calls.map(\.tool.displayName),
                answer: result.answer ?? "",
                toolOutput: Self.observedToolOutput(in: result),
                note: result.reasoning ?? "",
                executedTools: result.executedTools
            )
            onSubject?(sample.promptDescription, answer)
            return ModelSubject(value: answer)
        } catch where LLMRouter.isDecliningToRoute(error) {
            // Mirrors production exactly: a guardrail trip or a refusal is
            // the model declining to serve the request, which the router
            // treats as an escalation. Scored as ["none"] because that is
            // the outcome the user gets.
            //
            // NARROWED, 2026-08-11. This used to catch every
            // GenerationError, which handed the router a free correct
            // abstention whenever the pipeline actually broke — a context
            // overflow would have scored as a well-judged `none`. Anything
            // else now propagates and the sample errors out, which is what
            // a failure should look like in a report.
            //
            // No tool output, because no tool ran. It used to carry the
            // expected plan's output here, which told the judge that
            // figures were available to an answer that never existed.
            let abstention = BankingAnswer(tools: ["none"])
            onSubject?(sample.promptDescription, abstention)
            return ModelSubject(value: abstention)
        }
    }

    /// What the agent's tools returned THIS RUN, named tool by tool.
    ///
    /// This is the string the judge scores Faithfulness against, so it
    /// has to be the output of the calls that actually produced the
    /// answer.
    ///
    /// MEASURED, 2026-08-12. It used to be re-derived from the sample's
    /// EXPECTED tools — `MockGroundTruth.toolOutput(tools: expected.tools)`
    /// — and handed to the judge under the label "What the tools actually
    /// returned", which is not what it was. Wherever routing diverged
    /// from the expectation the judge was grading an answer against a
    /// different set of tool outputs than the one that produced it, and a
    /// failing subset is made of nothing but such samples:
    ///
    ///   ILL-POSED   Sample 8 expects `none`, so the derived output was
    ///               EMPTY while the agent had really called four tools
    ///               and fetched real figures. Asked whether an answer
    ///               full of numbers was traceable to "nothing", the
    ///               judge scored Faithfulness 1, then 4, then 3 on three
    ///               consecutive runs of the same unchanged defect —
    ///               ±0.33 on the reported mean from one sample.
    ///   BACKWARDS   The dangerous direction, and the reason this is a
    ///               correctness fix rather than a tidying one. An agent
    ///               that skips a tool and invents its figures was graded
    ///               against expected output CONTAINING those figures, so
    ///               the invention read as grounded. A fabrication check
    ///               that clears fabrications is worse than no check.
    ///
    /// Whether the RIGHT tools ran is Completeness's question, and
    /// LLMRouterTests grades selection on its own. Keeping them apart is
    /// the point: a wrong tool read honestly and a right tool answered
    /// dishonestly are different defects with different fixes, and one
    /// number that moves for both explains neither.
    ///
    /// Each chunk names its tool because Faithfulness is a question about
    /// attribution — sample 7 reported scheduled payments as pending, and
    /// that is only visible to a judge that can see which tool returned
    /// which rows.
    static func observedToolOutput(in result: RoutingResult) -> String {
        (result.trace.execution?.invocations ?? [])
            .compactMap { invocation in
                let output = invocation.output?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                // A call whose output never came back is not evidence of
                // anything, and printing "x returned:" with nothing after
                // it invites the judge to read the blank as a value.
                return output.isEmpty ? nil : "\(invocation.toolName) returned: \(output)"
            }
            .joined(separator: "\n")
    }

    // MARK: Metrics

    let faithfulness = ScoreDimension(
        "Faithfulness",
        description: """
            Whether every fact in the answer could have come from the tool \
            output, with no invented balances, dates, names, or amounts, and \
            no rounding or restating of a figure into a different value.
            """,
        scale: .numeric([
            4: "Every figure and fact is traceable to the tools",
            3: "Traceable, but a figure is reworded or rounded",
            2: "Contains a plausible detail the tools did not provide",
            1: "Contains invented figures"
        ])
    )

    /// The counterpart to Faithfulness: that one asks whether anything
    /// extra crept IN, this asks whether anything required was left OUT.
    /// The multi-intent failure lives here — "show my balance and this
    /// week's transactions" answered with only the balance is perfectly
    /// faithful and half an answer.
    ///
    /// A non-reply is scored here too, and it is the reason this
    /// dimension carries the escalation decision: refusing a request the
    /// tools could have served is the most incomplete answer possible,
    /// while refusing one they cannot serve is completely correct. The
    /// judge is told which case it is looking at through `reference`.
    let completeness = ScoreDimension(
        "Completeness",
        description: """
            Whether the reply answers every part of what the customer \
            asked. A request with two parts needs both; a request the \
            assistant should not have served on device needs no reply at \
            all.
            """,
        scale: .numeric([
            4: "Every part of the request is answered, or a non-reply was the correct call",
            3: "The main part is answered but a minor detail is missing",
            2: "Only some parts of a multi-part request are answered",
            1: "Does not answer what was asked, or stayed silent where an answer was expected"
        ])
    )

    /// Product requirements, not style preferences. The agent is told to
    /// answer in one or two plain sentences and to never mention the
    /// tools, the app, or that it called anything — a customer should not
    /// learn the app's internals from a balance enquiry. Pasted-through
    /// tool output is the other failure this catches: the raw strings are
    /// formatted for the model, not for a person.
    let naturalness = ScoreDimension(
        "Naturalness",
        description: """
            Whether the reply reads as a banking assistant talking to a \
            customer: plain language, one or two sentences, no mention of \
            tools, routing, or the app's internals, and no raw tool output \
            pasted through.
            """,
        scale: .numeric([
            4: "Reads like a person; plain, brief, no internals mentioned",
            3: "Clear but stilted, repetitive, or longer than it needs to be",
            2: "Mentions the tools, the app, or how the answer was produced",
            1: "Raw tool output pasted through, or not readable as a reply"
        ])
    )

    var evaluators: Evaluators {
        ModelJudgeEvaluator(
            judge: ClaudeJudge.model,
            dimensions: [faithfulness, completeness, naturalness],
            prompt: ModelJudgePrompt(
                instructions: """
                    You are evaluating a banking assistant's reply to a customer. The \
                    assistant reads account data through read-only tools and answers in \
                    plain language. It is not allowed to invent figures, and it is not \
                    allowed to talk about its own tools or internals.

                    Some requests cannot be served on device at all: anything asking the \
                    assistant to DO something (transfer, freeze, cancel, raise a limit, \
                    open or close an account) and anything the read-only tools do not \
                    cover. For those, staying silent is the CORRECT behaviour — score a \
                    non-reply 4 on every dimension. For a request the tools could have \
                    served, a non-reply is a total failure of Completeness. The \
                    reference below tells you which of the two you are looking at; do \
                    not infer it from the silence itself.
                    """,
                // Deliberately states only what happened, with no verdict
                // attached. The previous wording told the judge a non-reply
                // "is correct for anything it cannot serve", which pre-judged
                // the very thing Completeness exists to score — a wrongly
                // withheld answer was being described to the judge as
                // correct behaviour. The verdict now comes from `reference`,
                // which is the only closure that can see `input` and
                // therefore the only one that KNOWS whether a reply was owed.
                evaluationTarget: { value in
                    value.answer.isEmpty
                        ? "The assistant did not reply; it routed the request off device."
                        : "Assistant reply: \(value.answer)"
                },
                reference: { input, observed in
                    let wasAnswerable = input.expected?.answer.isEmpty == false
                    return [
                        "Should this have been answered on device?": wasAnswerable
                            ? "YES — the tools cover this request, so staying silent is a Completeness failure."
                            : "NO — this needs an action or a capability the tools do not have, so staying silent is correct and complete.",
                        "Tools the assistant used": observed.executedTools.isEmpty
                            ? "none recorded"
                            : observed.executedTools.joined(separator: ", "),
                        "A correct answer for reference": wasAnswerable
                            ? input.expected!.answer
                            : "this request should not have been answered on device",
                        "What the tools actually returned": observed.toolOutput.isEmpty
                            ? "nothing"
                            : observed.toolOutput
                    ]
                }
            )
        )
    }

    func aggregateMetrics(using aggregator: inout MetricsAggregator) {
        // All three judge dimensions get the same treatment: mean for the
        // headline, minimum because one bad answer matters more than a
        // good average, and standard deviation because these are model
        // scores with real variance — read the σ before comparing two
        // runs, per HybridRouterReliabilityTests.
        for dimension in [faithfulness, completeness, naturalness] {
            aggregator.computeMean(of: dimension.metric)
            aggregator.computeMinimum(of: dimension.metric)
            aggregator.computeStandardDeviation(of: dimension.metric)
        }
    }
}

// MARK: - Suite

@Suite("Hybrid Router Evaluations")
struct HybridRouterTests {
    /// TEMPORARY — which bundled dataset this eval runs.
    ///
    /// `failing_banking_qa` holds whatever is currently failing, lifted
    /// from `synthetic_banking_qa` so its expectations can never drift
    /// from the source. It exists to make the fix loop short, and it gets
    /// re-cut as samples are fixed:
    ///
    ///   20 samples  the 2026-08-12 08:30 failures — synthetic indices
    ///               3, 7, 11, 14, 19, 21, 23, 26, 27, 29, 31, 33, 35,
    ///               39, 47, 49, 50, 51, 58, 59. About 6 minutes.
    ///    9 samples  re-cut after run 7 — 3, 26, 27, 29, 31, 39, 47, 51,
    ///               59. About 3 minutes.
    ///
    /// EVERY RE-CUT NARROWS WHAT IS WATCHED. The 11 dropped in the second
    /// cut no longer run, so a regression in one of them is invisible
    /// here — the same trade as running 20 of 60, one level deeper. Two of
    /// today's changes had to be reverted for breaking samples that WERE
    /// still in the set; a narrower set would have hidden them. Re-cut to
    /// move faster, then run the full dataset before believing anything.
    ///
    /// NOTHING MEASURED ON IT IS A ROUTER SCORE. It is the failures only,
    /// so its mean is bounded far below the real one and cannot be
    /// compared to any run of the full dataset — and because it is a
    /// filtered subset it is no longer interleaved by answer size, so
    /// `sampleLimit` prefixes of it are not proportional either. The
    /// number to report is a full `synthetic_banking_qa` pass.
    ///
    /// Set back to "synthetic_banking_qa" once these are fixed.
    static let datasetName = "failing_banking_qa"

    /// URL to the dataset bundled with the test target.
    static let samplesURL: URL = {
        guard let url = #bundle.url(forResource: datasetName, withExtension: "json") else {
            fatalError("""
                Missing required resource: \(datasetName).json. \
                Ensure it is included in the ToolRoutingStrategiesTests target.
                """)
        }
        return url
    }()

    /// TEMPORARY — how many samples to run, counting from the top of the
    /// file. A full pass runs 60 requests through retrieval, selection,
    /// the agent AND a Claude judge call, so it is far too slow to sit in
    /// an edit-run loop. Set to `nil` before reading any number as real.
    ///
    /// The slice is a PREFIX, which is only informative because the
    /// dataset is INTERLEAVED: `synthetic_banking_qa.json` round-robins
    /// none → 1-call → 2-call → 3-call, so any prefix is roughly
    /// proportional and the first 10 cover 3 escalations, 3 single
    /// lookups, 2 chains and 2 three-call plans. It was previously
    /// grouped by bucket, which made the first 15 samples all escalation
    /// and a truncated run actively misleading — keep the interleave if
    /// you regenerate the file.
    ///
    /// A prefix is still not a small version of the full run: 10 samples
    /// puts the 95% interval at roughly ±0.3, so it catches a pipeline
    /// that is broken, not a prompt that is 10% worse.
    ///
    /// The interleave argument holds for `synthetic_banking_qa` ONLY.
    /// While `datasetName` is the failing subset there is no bucket
    /// rotation left to preserve, so keep this at `nil` — a prefix of
    /// that file is an arbitrary handful of defects, not a sample of
    /// anything.
    static let sampleLimit: Int? = nil

    /// Floor for every judge dimension's mean, on the 1–4 scale. See the
    /// expectation in `evaluateAnswers` for why it is set where it is.
    ///
    /// RAISED 3.0 → 3.5 on 2026-08-11, deliberately, and with a known
    /// flake risk at the current sample count. The 20-sample run that
    /// preceded it measured Faithfulness 3.68, Completeness 3.79,
    /// Naturalness 3.89 with σ ≈ 0.70 on the first two — a standard error
    /// of 0.16 and a 95% interval of about ±0.31 on the mean. So an
    /// unchanged build can land near 3.48, and this floor will sometimes
    /// fail on code that did not get worse.
    ///
    /// WHEN IT FAILS, RAISE `sampleLimit` BEFORE LOWERING THIS. The
    /// interval narrows with √n: at 60 samples it is about ±0.18, which
    /// puts 3.5 clear of the noise. Lowering the floor to make a red
    /// suite green is how the 3.0 version stopped meaning anything —
    /// it sat so far below the measured range that it could not fire.
    ///
    /// One number for three dimensions, so it is set by the least stable:
    /// Completeness, which tracks routing errors and has ranged 3.00–3.80
    /// across today's runs. Naturalness has never left 3.70–3.90 and
    /// could carry a tighter bar of its own if this ever becomes worth
    /// splitting.
    ///
    /// DELIBERATELY UNCHANGED while `datasetName` is the failing subset,
    /// where it stops being a regression gate and becomes a completion
    /// one: every sample in that file is a known defect, so the suite
    /// goes green exactly when they are fixed. Expect red until then, and
    /// do not lower it to get green — that is the failure mode this
    /// comment's 3.0 story is already about.
    static let judgeFloor = 3.5

    static let samples: [ModelSample<BankingAnswer>] = {
        let all: [ModelSample<BankingAnswer>]
        do {
            all = try JSONDecoder().decode(
                [ModelSample<BankingAnswer>].self,
                from: Data(contentsOf: samplesURL)
            )
        } catch {
            fatalError("Could not decode \(datasetName).json: \(error)")
        }
        guard let sampleLimit else { return all }
        return Array(all.prefix(sampleLimit))
    }()

    static let evaluation = HybridAnswerEvaluation(
        dataset: ArrayLoader(samples: samples)
    )

    static let evaluationInfo: [String: String] = [
        "ModelName": "all-MiniLM-L6-v2 (MLX) + SystemLanguageModel",
        "Strategy": "Hybrid cascade end to end (retrieval → selection → agent)",
        "Judge": "Claude Opus 5 (ClaudeForFoundationModels)",
        "AppVersion": "1.0",
        // Names the dataset, so a .xcevalresult can never be mistaken for
        // a full-dataset run once it is sitting in a report next to one.
        "Feature": "End-to-end banking answers (\(datasetName), \(samples.count) samples)"
    ]

    @Test(
        "Hybrid Router Answer Evaluations",
        .enabled(if: SystemLanguageModel.default.isAvailable && ClaudeJudge.isConfigured),
        .evaluates(evaluation, info: evaluationInfo)
    )
    func evaluateAnswers() async throws {
        let result = EvaluationContext.current.result

        // Printed first, and loudly, so a truncated run can never be read
        // as the real number — the whole risk of a sample limit is a
        // partial score being copied into a decision.
        if let limit = Self.sampleLimit {
            print("⚠️ TRUNCATED RUN — first \(limit) samples only (prefix, not a sample). Not comparable to a full run.")
        }

        for dimension in [
            Self.evaluation.faithfulness,
            Self.evaluation.completeness,
            Self.evaluation.naturalness
        ] {
            let mean = result.aggregateValue(.mean(of: dimension.metric))
            let worst = result.aggregateValue(.minimum(of: dimension.metric))
            let sigma = result.aggregateValue(.standardDeviation(of: dimension.metric))
            print("\(dimension.name) — mean \(mean), minimum \(worst), σ \(sigma)")

            // WIRING CHECK, not a quality bar. A dimension that never
            // scored aggregates to a placeholder rather than raising, so
            // without this a judge that failed to run — bad key, a
            // dimension left out of `dimensions:`, an API error on every
            // sample — reports as silence and the suite passes green.
            // This is the assertion that cannot flake.
            #expect(
                mean > 0,
                "\(dimension.name) produced no score. The judge did not run, or the dimension is not wired into `dimensions:`."
            )

            // QUALITY BAR, deliberately loose. These are model scores with
            // real variance — the 2026-08-07 run had the judge score
            // silence 4 and a decoding stutter 1 — so the threshold is set
            // to catch a collapse, not to police a point of drift. On a
            // 1–4 scale, a mean below 3 means the AVERAGE answer has a
            // real defect, which no amount of judge noise explains.
            //
            // Provisional until a full run reports σ. If σ turns out large
            // enough that 3.0 is inside the noise, this needs a confidence
            // interval rather than a bare comparison — EvalStats in
            // HybridRouterReliabilityTests already has the maths, and that file
            // reports the σ this comment is waiting on.
            #expect(
                mean >= Self.judgeFloor,
                "\(dimension.name) mean \(mean) is below \(Self.judgeFloor) (minimum \(worst), σ \(sigma))"
            )
        }

    }
}
