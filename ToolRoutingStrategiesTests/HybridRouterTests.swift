import Evaluations
import Foundation
import FoundationModels
import TabularData
import Testing
import ClaudeForFoundationModels
@testable import ToolRoutingStrategies

enum ClaudeJudge {
    static let apiKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? ""

    static var isConfigured: Bool { !apiKey.isEmpty }

    static let missingKeyMessage = """
        ANTHROPIC_API_KEY is not set, so the judge cannot score anything and this \
        evaluation would report nothing at all.

        Set it in Xcode under Edit Scheme ▸ Test ▸ Arguments ▸ Environment Variables, \
        or pass it to xcodebuild as TEST_RUNNER_ANTHROPIC_API_KEY=… — a test process \
        running on a device does not inherit your shell's environment.

        The scheme that normally carries it is gitignored, so a fresh clone will not \
        have one.
        """

    static var model: ClaudeLanguageModel {
        precondition(isConfigured, missingKeyMessage)
        return ClaudeLanguageModel(name: .opus5, auth: .apiKey(apiKey), timeout: 300)
    }
}

struct HybridAnswerEvaluation: Evaluation {
    var dataset: ArrayLoader<ModelSample<BankingAnswer>>

    var onSubject: (@Sendable (String, BankingAnswer) -> Void)?

    func subject(from sample: ModelSample<BankingAnswer>) async throws -> ModelSubject<BankingAnswer> {
        let router = await ChatAgent()
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
            let abstention = BankingAnswer(tools: ["none"])
            onSubject?(sample.promptDescription, abstention)
            return ModelSubject(value: abstention)
        }
    }

    static func observedToolOutput(in result: RoutingResult) -> String {
        (result.trace.execution?.invocations ?? [])
            .compactMap { invocation in
                let output = invocation.output?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return output.isEmpty ? nil : "\(invocation.toolName) returned: \(output)"
            }
            .joined(separator: "\n")
    }

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
        ValidatedModelJudge(
            judge: modelJudge,
            dimensions: [faithfulness, completeness, naturalness]
        )
    }

    private var modelJudge: ModelJudgeEvaluator<ModelSample<BankingAnswer>> {
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

                    THE REPLY IS WHAT FOLLOWS "Assistant reply:", and that label is OUR \
                    framing — it is not something the customer saw, and it is not part of \
                    what you are scoring. MEASURED: two replies in two runs were marked \
                    down on Naturalness for "a label a customer would not expect to see" \
                    and "a scaffolding artifact", both times quoting this line rather than \
                    anything the assistant wrote. Score the words after it and nothing else.

                    EVERY DIMENSION GETS ONE OF 1, 2, 3 OR 4. There is no 0, no N/A and \
                    no blank: a reply you find nothing to say about is a 4, and a reply \
                    with no text in it is still scored on all three — see the paragraph \
                    above for which way. This is not a formatting preference. A score \
                    outside the scale has no place on it, and the run cannot record it: \
                    the whole report fails to encode, and every other sample's score is \
                    lost with it.
                    """,
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
        for dimension in [faithfulness, completeness, naturalness] {
            aggregator.computeMean(of: dimension.metric)
            aggregator.computeMinimum(of: dimension.metric)
        }
    }
}

@Suite("Hybrid Router Evaluations")
struct HybridRouterTests {
    static let datasetName = "synthetic_banking_qa"

    static let samplesURL: URL = {
        guard let url = #bundle.url(forResource: datasetName, withExtension: "json") else {
            fatalError("""
                Missing required resource: \(datasetName).json. \
                Ensure it is included in the ToolRoutingStrategiesTests target.
                """)
        }
        return url
    }()

    static let batch: Range<Int>? = nil

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
        guard let batch else { return all }
        let slice = batch.clamped(to: all.indices)
        return Array(all[slice])
    }()

    static let evaluation = HybridAnswerEvaluation(
        dataset: ArrayLoader(samples: samples)
    )

    static let evaluationInfo: [String: String] = [
        "ModelName": "all-MiniLM-L6-v2 (MLX) + SystemLanguageModel",
        "Strategy": "Hybrid cascade end to end (retrieval → selection → agent)",
        "Judge": "Claude Opus 5 (ClaudeForFoundationModels)",
        "AppVersion": "1.0",
        "Feature": "End-to-end banking answers (\(datasetName), \(samples.count) samples)"
    ]

    static func spread(of dimension: ScoreDimension, in result: EvaluationResult) -> Double {
        guard let column = result.detailed.columns
            .first(where: { $0.name == dimension.name })?
            .assumingType(Metric.self)
        else { return 0 }

        let values = column.compactMap { $0?.doubleValue }
        guard values.count > 1 else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values
            .map { ($0 - mean) * ($0 - mean) }
            .reduce(0, +) / Double(values.count - 1)
        return variance.squareRoot()
    }

    @MainActor
    static func printPerSample(_ result: EvaluationResult) {
        let detailed = result.detailed
        let inputs = detailed[evaluation.inputColumn]
        let responses = detailed[evaluation.responseColumn]
        let scored = [
            evaluation.faithfulness,
            evaluation.completeness,
            evaluation.naturalness
        ].map { ($0.name, detailed[metric: $0.metric]) }

        print("\n─────── \(datasetName): \(detailed.rows.count) samples ───────")

        let uncalled = ChatAgent.turnsWithUncalledTools
        print(uncalled == 0
            ? "tool dispatch: every routed tool was called"
            : "⚠️ \(uncalled) turn\(uncalled == 1 ? "" : "s") routed a tool that was never called — those answers have no tool output behind them")

        for row in 0..<detailed.rows.count {
            let sample = inputs[row]
            let observed = responses[row]?.value
            let expected = sample?.expected?.answer ?? ""
            let actual = observed?.answer ?? ""

            let scores = scored
                .map { name, column in
                    let score = column[row]?.doubleValue
                    return "\(name) \(score.map { String(format: "%g", $0) } ?? "—")"
                }
                .joined(separator: "  ·  ")

            let routed = observed?.tools ?? []
            let called = observed?.executedTools ?? []
            let returned = observed?.toolOutput ?? ""

            print("""

                #\(row)  \(oneLine(sample?.promptDescription ?? "(no prompt)"))
                   expected  \(expected.isEmpty ? "(no answer — this request should escalate)" : oneLine(expected))
                   actual    \(actual.isEmpty ? "(no reply — routed off device)" : oneLine(actual))
                   note      \(oneLine(observed?.note ?? "").isEmpty ? "(none)" : oneLine(observed?.note ?? ""))
                   routed    \(routed.isEmpty ? "(nothing routed)" : routed.joined(separator: ", "))
                   called    \(called.isEmpty ? "(no tool ran)" : called.joined(separator: ", "))
                   returned  \(returned.isEmpty ? "(nothing)" : oneLine(returned))
                   score     \(scores)
                """)
        }
        print("")
    }

    private static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    @Test(
        "Hybrid Router Answer Evaluations",
        .enabled(if: SystemLanguageModel.default.isAvailable),
        .evaluates(evaluation, info: evaluationInfo)
    )
    func evaluateAnswers() async throws {
        try #require(ClaudeJudge.isConfigured, "\(ClaudeJudge.missingKeyMessage)")

        let result = EvaluationContext.current.result

        if let batch = Self.batch {
            print("""
                ⚠️ BATCH RUN — samples \(batch.lowerBound)..<\(batch.upperBound) of \(Self.datasetName) \
                (\(Self.samples.count) of 60). A batch is not a small full run: the 95% interval is \
                about ±0.22 at 20 samples. Not comparable to a full pass.
                """)
        }

        await Self.printPerSample(result)

        for dimension in [
            Self.evaluation.faithfulness,
            Self.evaluation.completeness,
            Self.evaluation.naturalness
        ] {
            let mean = result.aggregateValue(.mean(of: dimension.metric))
            let worst = result.aggregateValue(.minimum(of: dimension.metric))
            let sigma = Self.spread(of: dimension, in: result)
            print("\(dimension.name) — mean \(mean), minimum \(worst), σ \(sigma)")

            #expect(
                mean > 0,
                "\(dimension.name) produced no score. The judge did not run, or the dimension is not wired into `dimensions:`."
            )

            #expect(
                mean >= Self.judgeFloor,
                "\(dimension.name) mean \(mean) is below \(Self.judgeFloor) (minimum \(worst), σ \(sigma))"
            )
        }
    }
}
