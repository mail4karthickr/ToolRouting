/*
Does a spending question end up with every tool it needs?

Two things have to line up and they fail in different places, so they are
checked separately here:

  1. RETRIEVAL surfaces every tool the question needs, calculator
     included. `LLMRouter.schema(for:)` builds the output grammar from the
     shortlist, so a tool Stage 1 did not return is one Stage 2 cannot
     name however well it reasons. That makes a missing tool ambiguous
     from a trace alone — "the router failed to pick it" and "the router
     was never offered it" look identical in the answer and have opposite
     fixes.

  2. CLOSURE repairs the plan. Prerequisites the router left out are
     added, and a plan that only computes — with nothing fetching the
     figures to compute from — is emptied rather than run.

The second is pure logic and needs no model. The first needs MLX
(Apple-silicon Metal): run on device, not the iOS simulator.
*/

import Foundation
import Testing
@testable import ToolRoutingStrategies

struct ShortlistCase: Sendable, CustomStringConvertible {
    /// Every tool a correct answer needs. All of them have to fit.
    let query: String
    let needs: [String]

    var description: String { query }
}

@Suite("Shortlist coverage", .serialized)
struct ShortlistCoverageTests {

    static let cases: [ShortlistCase] = [
        ShortlistCase(
            query: "Total amount spent at Walmart over the last 6 months",
            needs: ["resolve_date_range", "search_transactions", "calculator"]
        ),
        ShortlistCase(
            query: "How much did I spend at Starbucks this month?",
            needs: ["resolve_date_range", "search_transactions", "calculator"]
        ),
        ShortlistCase(
            query: "How does my Starbucks spending this month compare with last month?",
            needs: ["resolve_date_range", "search_transactions", "calculator"]
        ),
        // No period named, so the window tool is not needed — but the
        // total still is.
        ShortlistCase(
            query: "How much did I spend at Starbucks?",
            needs: ["resolve_date_range", "search_transactions", "calculator"]
        ),
        // The eval's messy prompts, verbatim. #2 routed no calculator —
        // this is what says whether Stage 1 never offered it or Stage 2
        // declined it, which have opposite fixes.
        ShortlistCase(
            query: "how much did i spnd at walmart last mnth",
            needs: ["resolve_date_range", "search_transactions", "calculator"]
        ),
        ShortlistCase(
            query: "how much i spend at starbucks this month",
            needs: ["resolve_date_range", "search_transactions", "calculator"]
        ),
        ShortlistCase(
            query: "Where's the nearest ATM?",
            needs: ["get_location", "find_nearest_atm"]
        ),
        ShortlistCase(
            query: "Last two months starbucks spend",
            needs: ["search_transactions"]
        )
    ]

    @Test("Every tool a question needs fits in the shortlist", arguments: cases)
    func theShortlistHoldsTheSources(_ sample: ShortlistCase) async throws {
        let router = await MiniLMRouter()
        let ranked = try await router.retrieve(sample.query, topK: 5)
        let shortlist = ranked.map(\.toolName)

        let missing = sample.needs.filter { !shortlist.contains($0) }
        #expect(
            missing.isEmpty,
            """
            \"\(sample.query)\"
            missing from the shortlist: \(missing)
            shortlist was: \(ranked.map { "\($0.toolName) \(String(format: "%.2f", $0.score))" })
            """
        )
    }

    /// Prints the ranked shortlist for the eval's prompts. Not an
    /// assertion — Stage 2 is greedy, so when it declines a tool the
    /// question is always what it was SHOWN, and the selection prompt
    /// lists the shortlist in rank order.
    @Test("Shortlist ranks for the eval prompts")
    func printRanksForEvalPrompts() async throws {
        let prompts = [
            "how much i spend at starbucks this month",
            "total spent at starbcuks last 2 months",
            "how much did i spnd at walmart last mnth",
            "dining spend last month total",
            "hw much i spent at strbucks in june",
            "amazon spend last 30 days total"
        ]
        let router = await MiniLMRouter()
        for prompt in prompts {
            let ranked = try await router.retrieve(prompt, topK: 5)
            let line = ranked.enumerated()
                .map { "\($0.offset + 1).\($0.element.toolName) \(String(format: "%.2f", $0.element.score))" }
                .joined(separator: "  ")
            print("SHORTLIST | \(prompt)\n           \(line)")
        }
    }

    // MARK: - Closure (no model)

    @Test("A plan missing a prerequisite is completed, in execution order")
    func closureAddsPrerequisites() {
        // The router named the last link only. Both earlier ones are facts
        // about the tools, not judgements, so they are added here.
        #expect(ToolCatalog.closure(over: ["branch_hours"]) == [
            "get_location", "find_nearest_branch", "branch_hours"
        ])
        #expect(ToolCatalog.closure(over: ["find_nearest_atm"]) == ["get_location", "find_nearest_atm"])
        // Same shape for the spending chain.
        #expect(ToolCatalog.closure(over: ["search_transactions"]) == [
            "resolve_date_range", "search_transactions"
        ])
    }

    @Test("A complete plan is left exactly as the router wrote it")
    func closureLeavesCompletePlansAlone() {
        #expect(ToolCatalog.closure(over: ["get_location", "find_nearest_atm"]) == [
            "get_location", "find_nearest_atm"
        ])
        #expect(ToolCatalog.closure(over: ["account_balance"]) == ["account_balance"])
        // Named twice, run once.
        #expect(ToolCatalog.closure(over: ["get_location", "get_location"]) == ["get_location"])
    }

    @Test("A plan that only computes is emptied rather than run")
    func closureDropsArithmeticWithNothingToComputeOn() {
        // calculator works on figures another tool fetched. Alone, there
        // are none — an empty plan escalates, which is the honest outcome.
        #expect(ToolCatalog.closure(over: ["calculator"]).isEmpty)

        // With anything at all to compute from, it stays.
        #expect(ToolCatalog.closure(over: ["account_balance", "calculator"]) == [
            "account_balance", "calculator"
        ])
    }
}
