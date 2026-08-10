/*
Grades the answer HybridRouter produces end to end. Tool selection is
graded in LLMRouterTests.

  Fabrication    DETERMINISTIC — is there a number in the reply that no
                 tool returned?
  Faithfulness   judge — is every fact traceable to the tool output?
  Completeness   judge — is every part of the request answered, and was a
                 non-reply the right call?
  Naturalness    judge — does it read like a person, without leaking the
                 tools or the app?

Fabrication overlaps Faithfulness on purpose: same question, different
reliability. Faithfulness is a semantic read with real variance (σ ≈ 0.67
at n = 20); Fabrication is a mechanical check with none. It is the only
GATED metric here — everything else is a floor on a noisy score.

Faithfulness and Completeness are deliberately opposite: one asks whether
anything extra crept IN, the other whether anything required was left
OUT. An answer can score 4 on the first and 1 on the second by being
impeccably sourced and half of what was asked for.

Completeness also carries the escalation verdict, because a wrongly
withheld answer is the most incomplete answer there is. That only works
because the judge is TOLD whether a reply was owed — silence looks
identical either way, and inferring it from the silence is what the
earlier prompt got wrong.

Fabrication works because the API is a mock with fixed values, re-derived
per run from the sample's tools rather than stored. The judge is a
server-side model reached through the company gateway
(``CustomLanguageModel``) — a different and more capable model than the
on-device one that wrote the answer, so the score is not self-assessment.

Needs MLX, a one-time MiniLM weight download, Apple Intelligence, and
gateway credentials (see JudgeModel). Device or Mac only.
*/

import Evaluations
import Foundation
import FoundationModels
import Testing
@testable import ToolRoutingStrategies

// MARK: - Judge

/// The judge, reached through the company's OpenAI-compatible gateway.
///
/// ``CustomLanguageModel`` conforms to `LanguageModel`, so it drops
/// straight into `ModelJudgeEvaluator` where the Claude bridge used to sit
/// — the dimensions, the prompt, and the scoring are unchanged.
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

// MARK: - Fabrication (deterministic)

/// Fails a sample when the answer shows a numeral that appears in neither
/// the tool output nor the user's question.
///
/// This exists because the judge cannot reliably grade it. On the
/// 2026-08-07 run it scored the stutter in sample 23 a 1 — reading a
/// decoding artifact as an invented figure, the only rung the scale had —
/// and gave the truncated figure in sample 36 a 4, missing it entirely.
/// Both are the same defect, both are exactly checkable in code, and the
/// check costs no API call and has no variance.
///
/// Note the source of truth here is `toolOutput`, which the evaluation
/// re-derives from the sample's EXPECTED tools — so when the router calls
/// something other than what was expected, this grades against output the
/// model never saw. That is deliberate for an eval: an answer built from
/// the wrong tool should not pass. The runtime guard in ToolExecutionAgent
/// uses the actual transcript instead.
struct FabricationEvaluator: EvaluatorProtocol {
    typealias Input = ModelSample<BankingAnswer>
    typealias Subject = ModelSubject<BankingAnswer>

    /// 1 = every figure traced, 0 = at least one had no source. Scored
    /// rather than pass/fail so `minimum` gates it: one fabricated figure
    /// anywhere drags the minimum to 0.
    static let metric = Metric("Fabrication")

    func metrics(subject: ModelSubject<BankingAnswer>, input: ModelSample<BankingAnswer>) async throws -> [Metric] {
        let observed = subject.value
        let answer = observed.answer.trimmingCharacters(in: .whitespacesAndNewlines)

        // An abstention shows the user nothing, so there is no figure to
        // fabricate. Scored clean rather than ignored so the metric stays
        // comparable across runs; whether it SHOULD have answered is the
        // job of a coverage metric, not this one.
        guard !answer.isEmpty else {
            return [Self.metric.scoring(1, rationale: "No answer shown; no figure to fabricate.")]
        }

        let stray = AnswerVerifier.strayNumerals(
            in: answer,
            allowedFrom: [observed.toolOutput, input.promptDescription]
        )

        guard stray.isEmpty else {
            return [Self.metric.scoring(0, rationale: """
                Answer shows \(stray.joined(separator: ", ")) — not in the tool \
                output and not in the question.
                """)]
        }
        return [Self.metric.scoring(1, rationale: "Every figure traces to a tool result or the question.")]
    }
}

// MARK: - Evaluation

struct HybridAnswerEvaluation: Evaluation {
    var dataset: ArrayLoader<ModelSample<BankingAnswer>>

    func subject(from sample: ModelSample<BankingAnswer>) async throws -> ModelSubject<BankingAnswer> {
        let expected = sample.expected
        let truth = await MockGroundTruth.toolOutput(
            tools: expected?.tools ?? [],
            arguments: expected?.arguments ?? []
        )

        let router = await HybridRouter()
        do {
            let result = try await router.route(sample.promptDescription)
            return ModelSubject(value: BankingAnswer(
                tools: result.calls.isEmpty ? ["none"] : result.calls.map(\.tool.displayName),
                answer: result.answer ?? "",
                toolOutput: truth,
                note: result.reasoning ?? "",
                executedTools: result.executedTools
            ))
        } catch is LanguageModelSession.GenerationError {
            return ModelSubject(value: BankingAnswer(tools: ["none"], toolOutput: truth))
        }
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
        // Deterministic first: it needs no network, never varies, and grades
        // the one thing a banking answer cannot get wrong.
        //
        // It overlaps with Faithfulness on purpose. The two ask the same
        // question with different reliability: Faithfulness is a broad
        // semantic read with σ ≈ 0.67, this is a narrow mechanical check
        // with σ = 0. The judge has scored the SAME defect class 1 and 4
        // on different samples (2026-08-07), and on the 20-sample run it
        // gave the "Checking account checking account balance" stutter a
        // Faithfulness 4 and filed the duplication under Naturalness as a
        // style issue. A digit-level version of that is a wrong number in
        // a banking app, so it gets a check that cannot have an opinion.
        FabricationEvaluator()

        ModelJudgeEvaluator(
            judge: JudgeModel.model,
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
        // runs, per LLMRouterReliabilityTests.
        for dimension in [faithfulness, completeness, naturalness] {
            aggregator.computeMean(of: dimension.metric)
            aggregator.computeMinimum(of: dimension.metric)
            aggregator.computeStandardDeviation(of: dimension.metric)
        }

        // Mean is the clean rate; minimum is the gate. Minimum below 1
        // means at least one customer was shown a figure no tool returned.
        aggregator.computeMean(of: FabricationEvaluator.metric)
        aggregator.computeMinimum(of: FabricationEvaluator.metric)
    }
}

// MARK: - Suite

@Suite("Hybrid Router Evaluations")
struct HybridRouterTests {
    /// URL to the synthetic dataset bundled with the test target.
    static let samplesURL: URL = {
        guard let url = #bundle.url(forResource: "synthetic_banking_qa", withExtension: "json") else {
            fatalError("""
                Missing required resource: synthetic_banking_qa.json. \
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
    /// The slice is a PREFIX, and the dataset is grouped by bucket, so a
    /// truncated run is not a small version of the full one: the first 15
    /// samples are all escalation, and chains do not begin until sample
    /// 31. Twenty samples exercises the pipeline end to end but says
    /// nothing about multi-tool routing.
    static let sampleLimit: Int? = nil

    /// Floor for every judge dimension's mean, on the 1–4 scale. See the
    /// expectation in `evaluateAnswers` for why it is set where it is.
    static let judgeFloor = 3.0

    static let samples: [ModelSample<BankingAnswer>] = {
        let all: [ModelSample<BankingAnswer>]
        do {
            all = try JSONDecoder().decode(
                [ModelSample<BankingAnswer>].self,
                from: Data(contentsOf: samplesURL)
            )
        } catch {
            fatalError("Could not decode synthetic_banking_qa.json: \(error)")
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
        "Judge": "Company gateway (CustomLanguageModel, \(JudgeModel.endpoint?.modelID ?? "unconfigured"))",
        "AppVersion": "1.0",
        "Feature": "End-to-end banking answers (synthetic dataset, \(samples.count) samples)"
    ]

    @Test(
        "Hybrid Router Answer Evaluations",
        .enabled(if: SystemLanguageModel.default.isAvailable && JudgeModel.isConfigured),
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
            // LLMRouterReliabilityTests already has the maths.
            #expect(
                mean >= Self.judgeFloor,
                "\(dimension.name) mean \(mean) is below \(Self.judgeFloor) (minimum \(worst), σ \(sigma))"
            )
        }

        let cleanRate = result.aggregateValue(.mean(of: FabricationEvaluator.metric))
        let anyFabricated = result.aggregateValue(.minimum(of: FabricationEvaluator.metric))
        print("Fabrication — clean rate \(cleanRate), minimum \(anyFabricated)")

        // Same wiring check as the judge dimensions, and it matters more
        // here: this is the gate, so a Fabrication that silently stopped
        // running would take the suite's only hard assertion with it and
        // still report green.
        #expect(
            cleanRate > 0,
            "Fabrication produced no score. The evaluator is not in `evaluators`, or its aggregation is disabled."
        )

        // THE GATE. Deterministic, zero variance, and the property it
        // asserts — no customer is shown a figure the tools never
        // returned — is the one this app cannot trade off. Every other
        // assertion in this file is a floor on a noisy score; this one is
        // a fact.
        //
        // A failure here is a real defect, not a flaky threshold. Read the
        // failing sample's rationale to see which figure had no source; the
        // cause has been a generation stutter (2026-08-07 samples 23, 36) and
        // an over-broad plan whose extra tool contributed an irrelevant but
        // genuine figure (sample 4, same date).
        //
        // Note what a pass actually proves. AnswerVerifier also runs at
        // RUNTIME inside ToolExecutionAgent, fail-closed with one retry,
        // so a fabricated figure is usually rejected and regenerated
        // before the eval ever sees it. This gate is therefore a
        // regression test on that guard as much as a probe of the model —
        // if it ever fires, check whether the guard stopped running
        // before assuming the model got worse.
        #expect(
            anyFabricated == 1,
            "A sample showed a figure with no source (clean rate \(cleanRate))"
        )
    }
}
