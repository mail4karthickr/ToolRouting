/*
A deterministic smoke test for the calculator/search_transactions work,
kept SEPARATE from HybridRouterTests on purpose.

HybridRouterTests scores natural-language quality against a Claude judge
(ANTHROPIC_API_KEY, cloud round-trips, minutes per run) — that is the
EVAL. This is the TEST: no judge, no API key, just "did the right tools
run, and did the total survive into the reply" — the things that were
actually broken, in order found: the date-range default, the dropped
total, and search_transactions pre-totaling so calculator never got
exercised. Fast enough to run on every change while this capability is
still being built out.

`expectedTools` names BOTH search_transactions and calculator on
purpose — search_transactions returns each matching transaction on its
own now (see its header in Tools.swift), so a plain "how much did I
spend at X" question is only answered correctly when calculator sums
what it returned. One tool running without the other is exactly the
regression this file exists to catch.

Starts at the two questions already verified by hand against the app —
see calculator_search_qa.json. Add more samples there once these two
hold; this file does not need to change to pick them up.
*/

import Foundation
import Testing
import FoundationModels
@testable import ToolRoutingStrategies

struct QASample: Codable, Sendable {
    let prompt: String
    let expectedTools: [String]
    let expectedTotal: String
}

@Suite("Calculator + Search Transactions QA")
struct CalculatorSearchQATests {
    static let samples: [QASample] = {
        guard let url = #bundle.url(forResource: "calculator_search_qa", withExtension: "json") else {
            fatalError("""
                Missing required resource: calculator_search_qa.json. \
                Ensure it is included in the ToolRoutingStrategiesTests target.
                """)
        }
        do {
            return try JSONDecoder().decode([QASample].self, from: Data(contentsOf: url))
        } catch {
            fatalError("Could not decode calculator_search_qa.json: \(error)")
        }
    }()

    @Test(
        "The routed tools match, and the reply keeps the tool's own total",
        .enabled(if: SystemLanguageModel.default.isAvailable),
        arguments: samples
    )
    func answerKeepsTheTotal(_ sample: QASample) async throws {
        let agent = await ChatAgent()
        let result = try await agent.route(sample.prompt)

        #expect(
            Set(result.executedTools) == Set(sample.expectedTools),
            "expected \(sample.expectedTools) to run; actually ran \(result.executedTools)"
        )

        let answer = result.answer ?? ""
        #expect(
            answer.contains(sample.expectedTotal),
            "answer is missing the expected total \(sample.expectedTotal): \(answer.isEmpty ? "(no reply)" : answer)"
        )
    }
}
