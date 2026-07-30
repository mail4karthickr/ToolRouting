/*
Evaluations for the LLM-based tool router.

The router does NOT execute tools — it returns the list of tools matching
the user's prompt. So the evaluation is purely quantitative: does the
selected tool list match the expected list, and is the order right where
the scenario demands a specific order (dependent chains)?
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

/// Measures the tool-selection quality of `LLMRouter`.
struct ToolRoutingEvaluation: Evaluation {
    func subject(from sample: ModelSample<RoutingSelection>) async throws -> ModelSubject<RoutingSelection> {
        // Fresh router per sample so the reused session's transcript
        // can't leak context between samples.
        let router = await LLMRouter()
        do {
            let result = try await router.route(sample.promptDescription)
            return ModelSubject(value: RoutingSelection(tools: result.calls.map(\.tool.displayName)))
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

// MARK: - Tool Routing Evaluations

@Suite("Tool Routing Evaluations")
struct ToolRoutingStrategiesTests {
    static let evaluation = ToolRoutingEvaluation()

    /// Metadata recorded alongside each run.
    static let evaluationInfo: [String: String] = [
        "ModelName": "SystemLanguageModel",
        "Strategy": "On-Device LLM Router",
        "AppVersion": "1.0",
        "Feature": "Tool selection (routing) for the banking assistant"
    ]

    @Test(
        "LLM Router Tool Selection",
        .enabled(if: SystemLanguageModel.default.isAvailable),
        .evaluates(evaluation, info: evaluationInfo)
    )
    func evaluateToolSelection() async throws {
        let result = EvaluationContext.current.result

        #expect(result.aggregateValue(.mean(of: Self.evaluation.routingAccuracy)) >= 0.8)
    }
}
