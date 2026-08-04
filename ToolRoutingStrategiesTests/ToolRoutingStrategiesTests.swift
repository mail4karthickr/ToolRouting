/*
Evaluations for the tool routers.

A router does NOT execute tools — it returns the list of tools matching
the user's prompt. So the evaluation is purely quantitative: does the
selected tool list match the expected list, and is the order right where
the scenario demands a specific order (dependent chains)?

The same dataset and metric grade every strategy (LLM, embedding,
hybrid), so their Routing Accuracy numbers are directly comparable.
*/

import Evaluations
import Foundation
import FoundationModels
import Testing
@testable import ToolRoutingStrategies

// MARK: - Expected / actual value

/// The tool list for one routing decision. Used both as the expected
/// value (with `orderMatters` set per scenario) and as the subject value
/// produced by the router.
struct RoutingSelection: Codable, Sendable {
    /// Tool display names, in plan order.
    var tools: [String]
    /// Whether the expected order is part of the contract (dependent
    /// chains) or the tools may appear in any order (independent fan-out).
    var orderMatters: Bool = true
}

// MARK: - Evaluation

/// Measures the tool-selection quality of any `ToolRouter` strategy.
struct ToolRoutingEvaluation: Evaluation {
    /// Fresh router per sample so no state (a reused LLM session's
    /// transcript, a warmed cache) can leak context between samples.
    /// The MLX embedder's downloaded weights and the persisted tool
    /// index are shared across instances, so this stays cheap.
    let makeRouter: @Sendable @MainActor () -> any ToolRouter

    func subject(from sample: ModelSample<RoutingSelection>) async throws -> ModelSubject<RoutingSelection> {
        let router = await makeRouter()
        do {
            let result = try await router.route(sample.promptDescription)
            // Abstain ("none", an empty selection) escalates to the
            // backend in production (ToolRoutingViewModel), so grade it
            // as the system outcome, not the router-internal value.
            let tools = result.calls.isEmpty
                ? ["send_to_backend"]
                : result.calls.map(\.tool.displayName)
            return ModelSubject(value: RoutingSelection(tools: tools))
        } catch is LanguageModelSession.GenerationError {
            // Mirror production (ToolRoutingViewModel): a routing failure —
            // e.g. a guardrail refusal — degrades to backend escalation,
            // not a dead end. The eval grades the routing SYSTEM (model +
            // fallback policy), not the raw model.
            return ModelSubject(value: RoutingSelection(tools: ["send_to_backend"]))
        }
    }

    // MARK: - Dataset

    /// Pairs each test question with the expected tool list.
    var dataset = ArrayLoader(samples: [
        // Discrimination: merchant query must pick search over list.
        ModelSample(
            prompt: "What did I spend at Starbucks?",
            expected: RoutingSelection(tools: ["search_transactions"])
        ),
        // Discrimination reverse.
        ModelSample(
            prompt: "Show my transactions from the last 5 days",
            expected: RoutingSelection(tools: ["list_transactions"])
        ),
        // Dependent chain: location lookup must come first.
        ModelSample(
            prompt: "Find the nearest ATM",
            expected: RoutingSelection(tools: ["get_location", "find_atm"])
        ),
        // Chain-skip control: named place must not trigger get_location.
        ModelSample(
            prompt: "Find ATMs in Chicago",
            expected: RoutingSelection(tools: ["find_atm"])
        ),
        // Data-dependency chain: balance feeds the conversion.
        ModelSample(
            prompt: "How much is my savings balance in euros?",
            expected: RoutingSelection(tools: ["account_balance", "convert_currency"])
        ),
        // Independent fan-out — order is not part of the contract.
        ModelSample(
            prompt: "Show my balance and this week's transactions",
            expected: RoutingSelection(tools: ["account_balance", "list_transactions"], orderMatters: false)
        ),
        // Same tool twice with different parameters.
        ModelSample(
            prompt: "Get my June and July statements for checking",
            expected: RoutingSelection(tools: ["bank_statement", "bank_statement"], orderMatters: false)
        ),
        // All-or-nothing backend policy on a mixed request.
        ModelSample(
            prompt: "Show my balance and transfer $200 to savings",
            expected: RoutingSelection(tools: ["send_to_backend"])
        ),
        // Action vs. lookup on the same noun ("card").
        ModelSample(
            prompt: "Freeze my debit card",
            expected: RoutingSelection(tools: ["send_to_backend"])
        ),
        // No-parameter tool + fan-out.
        ModelSample(
            prompt: "What's my credit score and do I have any pending payments?",
            expected: RoutingSelection(tools: ["credit_score", "pending_payments"], orderMatters: false)
        ),

        // MARK: New tools — single-tool sanity

        ModelSample(
            prompt: "What's my daily ATM withdrawal limit?",
            expected: RoutingSelection(tools: ["card_limits"])
        ),
        ModelSample(
            prompt: "How many reward points do I have?",
            expected: RoutingSelection(tools: ["reward_points"])
        ),
        ModelSample(
            prompt: "Show my autopay settings",
            expected: RoutingSelection(tools: ["scheduled_payments"])
        ),
        ModelSample(
            prompt: "Any update on the charge I disputed?",
            expected: RoutingSelection(tools: ["dispute_status"])
        ),
        ModelSample(
            prompt: "What time does the Main St branch close?",
            expected: RoutingSelection(tools: ["branch_hours"])
        ),
        ModelSample(
            prompt: "How much interest did my savings earn last month?",
            expected: RoutingSelection(tools: ["interest_earned"])
        ),

        // MARK: New discrimination pairs

        // Processing-now vs. scheduled-future.
        ModelSample(
            prompt: "Do I have any payments still processing?",
            expected: RoutingSelection(tools: ["pending_payments"])
        ),
        ModelSample(
            prompt: "What payments are scheduled to go out next week?",
            expected: RoutingSelection(tools: ["scheduled_payments"])
        ),
        // "Credit limit" must hit card_limits, not credit_score or card_number.
        ModelSample(
            prompt: "What's my credit limit?",
            expected: RoutingSelection(tools: ["card_limits"])
        ),
        // Fees charged vs. interest earned.
        ModelSample(
            prompt: "What fees did I pay and what interest did I earn last month?",
            expected: RoutingSelection(tools: ["fees_and_charges", "interest_earned"], orderMatters: false)
        ),
        // Status of an existing dispute vs. raising a new one.
        ModelSample(
            prompt: "I want to dispute a charge from Amazon",
            expected: RoutingSelection(tools: ["send_to_backend"])
        ),
        // Lookup vs. action on the same noun ("limit").
        ModelSample(
            prompt: "Increase my ATM withdrawal limit",
            expected: RoutingSelection(tools: ["send_to_backend"])
        ),

        // MARK: New chains and fan-out

        // Three-step dependent chain.
        ModelSample(
            prompt: "How late is the nearest branch open?",
            expected: RoutingSelection(tools: ["get_location", "find_branch", "branch_hours"])
        ),
        // Chain-skip control: named branch goes straight to hours.
        ModelSample(
            prompt: "Is the airport branch open on Saturday?",
            expected: RoutingSelection(tools: ["branch_hours"])
        ),
        // Fan-out across the new tools.
        ModelSample(
            prompt: "Show my reward points and my credit card limit",
            expected: RoutingSelection(tools: ["reward_points", "card_limits"], orderMatters: false)
        ),

        // MARK: Informal phrasings — deployment-distribution coverage

        ModelSample(
            prompt: "whats my atm limit",
            expected: RoutingSelection(tools: ["card_limits"])
        ),
        ModelSample(
            prompt: "bal in savings?",
            expected: RoutingSelection(tools: ["account_balance"])
        ),
        ModelSample(
            prompt: "atm near me",
            expected: RoutingSelection(tools: ["get_location", "find_atm"])
        ),
        ModelSample(
            prompt: "starbucks charges this month",
            expected: RoutingSelection(tools: ["search_transactions"])
        ),
        ModelSample(
            prompt: "cancel my netflix payment",
            expected: RoutingSelection(tools: ["send_to_backend"])
        )
    ])

    // MARK: - Evaluator & Metric

    /// Pass when every expected tool was selected — in the expected order
    /// when the sample says order matters, in any order otherwise. Extra
    /// or missing tools fail either way.
    let routingAccuracy = Metric("Routing Accuracy")

    var evaluators: Evaluators {
        Evaluator { input, subject in
            guard let expected = input.expected else { return routingAccuracy.ignore() }

            let actual = subject.value.tools
            let matches = expected.orderMatters
                ? actual == expected.tools
                : actual.sorted() == expected.tools.sorted()

            if matches {
                return routingAccuracy.passing(rationale: actual.joined(separator: " → "))
            }
            return routingAccuracy.failing(
                rationale: "Expected \(expected.tools.joined(separator: " → ")); got \(actual.joined(separator: " → "))"
            )
        }
    }

    // MARK: - Analysis

    func aggregateMetrics(using aggregator: inout MetricsAggregator) {
        aggregator.computeMean(of: routingAccuracy)
    }
}

// MARK: - Retrieval Evaluation (embedder as Stage 1)

/// The retrieved shortlist for one query. Unlike `RoutingSelection`,
/// order NEVER matters here: retrieval is a similarity search, and the
/// shortlist's ranking is confidence, not an execution plan.
struct RetrievalSelection: Codable, Sendable {
    /// Tool display names above the similarity threshold, best first.
    var tools: [String]
    /// Cosine similarity per tool, parallel to `tools`.
    var scores: [Double] = []
}

/// Measures `MiniLMRouter.retrieve` in its hybrid Stage-1 role: for the
/// tool-serviceable routing prompts, every tool the correct plan needs
/// must appear in the top-k shortlist — order-free, extras are fine.
/// This is the hybrid's hard ceiling: a tool missing here is
/// unrecoverable downstream ("if the embedding model fails to retrieve
/// the correct tool, the LLM never sees it").
///
/// Backend/action prompts are deliberately NOT in this dataset: an
/// embedder cannot distinguish "freeze my card" from "show my card
/// number" (topic similarity is all it sees), so escalation is graded
/// only in the routing eval, and threshold abstention will be measured
/// in the calibration exercise with genuinely off-topic samples.
struct ToolRetrievalEvaluation: Evaluation {
    let topK = 4

    func subject(from sample: ModelSample<RetrievalSelection>) async throws -> ModelSubject<RetrievalSelection> {
        let router = await MiniLMRouter()
        let retrieved = try await router.retrieve(sample.promptDescription, topK: topK)
        return ModelSubject(value: RetrievalSelection(
            tools: retrieved.map(\.toolName),
            scores: retrieved.map { Double($0.score) }
        ))
    }

    // MARK: Dataset — tool-serviceable routing samples reshaped for
    // retrieval: expected = deduplicated tool SET of the correct plan.

    var dataset = ArrayLoader(samples: [
        ModelSample(prompt: "What did I spend at Starbucks?", expected: RetrievalSelection(tools: ["search_transactions"])),
        ModelSample(prompt: "Show my transactions from the last 5 days", expected: RetrievalSelection(tools: ["list_transactions"])),
        ModelSample(prompt: "Find the nearest ATM", expected: RetrievalSelection(tools: ["get_location", "find_atm"])),
        ModelSample(prompt: "Find ATMs in Chicago", expected: RetrievalSelection(tools: ["find_atm"])),
        ModelSample(prompt: "How much is my savings balance in euros?", expected: RetrievalSelection(tools: ["account_balance", "convert_currency"])),
        ModelSample(prompt: "Show my balance and this week's transactions", expected: RetrievalSelection(tools: ["account_balance", "list_transactions"])),
        ModelSample(prompt: "Get my June and July statements for checking", expected: RetrievalSelection(tools: ["bank_statement"])),
        ModelSample(prompt: "What's my credit score and do I have any pending payments?", expected: RetrievalSelection(tools: ["credit_score", "pending_payments"])),
        ModelSample(prompt: "What's my daily ATM withdrawal limit?", expected: RetrievalSelection(tools: ["card_limits"])),
        ModelSample(prompt: "How many reward points do I have?", expected: RetrievalSelection(tools: ["reward_points"])),
        ModelSample(prompt: "Show my autopay settings", expected: RetrievalSelection(tools: ["scheduled_payments"])),
        ModelSample(prompt: "Any update on the charge I disputed?", expected: RetrievalSelection(tools: ["dispute_status"])),
        ModelSample(prompt: "What time does the Main St branch close?", expected: RetrievalSelection(tools: ["branch_hours"])),
        ModelSample(prompt: "How much interest did my savings earn last month?", expected: RetrievalSelection(tools: ["interest_earned"])),
        ModelSample(prompt: "Do I have any payments still processing?", expected: RetrievalSelection(tools: ["pending_payments"])),
        ModelSample(prompt: "What payments are scheduled to go out next week?", expected: RetrievalSelection(tools: ["scheduled_payments"])),
        ModelSample(prompt: "What's my credit limit?", expected: RetrievalSelection(tools: ["card_limits"])),
        ModelSample(prompt: "What fees did I pay and what interest did I earn last month?", expected: RetrievalSelection(tools: ["fees_and_charges", "interest_earned"])),
        ModelSample(prompt: "How late is the nearest branch open?", expected: RetrievalSelection(tools: ["get_location", "find_branch", "branch_hours"])),
        ModelSample(prompt: "Is the airport branch open on Saturday?", expected: RetrievalSelection(tools: ["branch_hours"])),
        ModelSample(prompt: "Show my reward points and my credit card limit", expected: RetrievalSelection(tools: ["reward_points", "card_limits"])),
        ModelSample(prompt: "whats my atm limit", expected: RetrievalSelection(tools: ["card_limits"])),
        ModelSample(prompt: "bal in savings?", expected: RetrievalSelection(tools: ["account_balance"])),
        ModelSample(prompt: "atm near me", expected: RetrievalSelection(tools: ["get_location", "find_atm"])),
        ModelSample(prompt: "starbucks charges this month", expected: RetrievalSelection(tools: ["search_transactions"]))
    ])

    // MARK: Evaluators & Metrics

    let recall = Metric("Recall@4")

    var evaluators: Evaluators {
        Evaluator { input, subject in
            guard let expected = input.expected, !expected.tools.isEmpty else {
                return recall.ignore()
            }
            let retrieved = Set(subject.value.tools)
            let missing = Set(expected.tools).subtracting(retrieved)
            let got = zip(subject.value.tools, subject.value.scores)
                .map { String(format: "%@ %.2f", $0.0, $0.1) }
                .joined(separator: ", ")
            if missing.isEmpty {
                return recall.passing(rationale: "all of \(expected.tools.joined(separator: ", ")) in [\(got)]")
            }
            return recall.failing(rationale: "missing \(missing.sorted().joined(separator: ", ")) from [\(got)]")
        }
    }

    func aggregateMetrics(using aggregator: inout MetricsAggregator) {
        aggregator.computeMean(of: recall)
    }
}

// MARK: - Tool Routing Evaluations

@Suite("Tool Routing Evaluations")
struct ToolRoutingStrategiesTests {
    static let llmEvaluation = ToolRoutingEvaluation(makeRouter: { LLMRouter() })
    static let miniLMEvaluation = ToolRoutingEvaluation(makeRouter: { MiniLMRouter() })

    /// Metadata recorded alongside each run.
    private static func evaluationInfo(model: String, strategy: String) -> [String: String] {
        [
            "ModelName": model,
            "Strategy": strategy,
            "AppVersion": "1.0",
            "Feature": "Tool selection (routing) for the banking assistant"
        ]
    }

    @Test(
        "LLM Router Tool Selection",
        .enabled(if: SystemLanguageModel.default.isAvailable),
        .evaluates(llmEvaluation, info: evaluationInfo(
            model: "SystemLanguageModel",
            strategy: "On-Device LLM Router"
        ))
    )
    func evaluateToolSelection() async throws {
        let result = EvaluationContext.current.result

        #expect(result.aggregateValue(.mean(of: Self.llmEvaluation.routingAccuracy)) >= 0.8)
    }

    // Needs MLX (Apple-silicon Metal): run on device or a Mac — not the
    // iOS simulator. The first run downloads the MiniLM weights from the
    // Hugging Face Hub, so it needs network once.
    @Test(
        "MiniLM Embedding Router Tool Selection",
        .evaluates(miniLMEvaluation, info: evaluationInfo(
            model: "all-MiniLM-L6-v2 (MLX)",
            strategy: "MiniLM Embedding Router"
        ))
    )
    func evaluateMiniLMToolSelection() async throws {
        let result = EvaluationContext.current.result

        // Baseline floor, not a target: pure embedding routing is expected
        // to trail the LLM on dependent chains and multi-intent samples —
        // that gap is the measurement motivating the hybrid strategy.
        // Recalibrate this gate after the first recorded run.
        #expect(result.aggregateValue(.mean(of: Self.miniLMEvaluation.routingAccuracy)) >= 0.5)
    }

    static let retrievalEvaluation = ToolRetrievalEvaluation()

    // Grades the embedder in its hybrid STAGE-1 role: is every needed
    // tool in the top-4 shortlist? (Recall@4 — the hybrid's hard ceiling)
    @Test(
        "MiniLM Retrieval — Recall@4",
        .evaluates(retrievalEvaluation, info: evaluationInfo(
            model: "all-MiniLM-L6-v2 (MLX)",
            strategy: "MiniLM Retrieval (hybrid Stage 1)"
        ))
    )
    func evaluateMiniLMRetrieval() async throws {
        let result = EvaluationContext.current.result

        // Recall is the number that must be high — a missed tool here is
        // unrecoverable in the hybrid. Provisional floor; recalibrate
        // after the first recorded run.
        #expect(result.aggregateValue(.mean(of: Self.retrievalEvaluation.recall)) >= 0.75)
    }
}
