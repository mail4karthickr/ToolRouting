/*
Catalog invariants that hold without a model.

These are structural checks on `ToolCatalog` — no MLX, no Apple Intelligence,
no judge, no network. They run in milliseconds on any destination, which is
the point: the defect they guard against was found by a 6-minute device eval
and a Claude judge, and it did not need to be.

WHAT THIS ENFORCES. `ToolIndex` embeds a tool's description and EACH of its
example queries as separate vectors, then scores the tool by its best match
(`RoutableToolSpec.embeddingTexts`). So an argument value named only in the
description has to win on one vector blended across every other value the
description mentions, while a value with its own example gets a vector of
its own.

That asymmetry is not theoretical. `account_balance` accepts checking,
savings, credit card and all; its description named all four, but only
savings and the unqualified case had examples. "What's my credit card
balance?" therefore had to beat `card_limits`, whose FIRST example is
"What's my credit limit?" — one word apart. It lost, Stage 2 could not name
a tool retrieval never returned, and the assistant told a customer their
credit card balance was $10,000 (the limit; the balance was $1,204.87).
Eval 2026-08-12 sample 14, wrong on four runs out of four.

`card_number` accepts the same shape of argument, covers all three of its
values with real examples, and did not exhibit the bug. That contrast is
what makes this a rule rather than a patch: the fix is one example per
argument VALUE — a finite set — not one example per failing phrasing, which
is an infinite set and would only ever be overfitting to the last eval.
*/

import Foundation
import Testing
@testable import ToolRoutingStrategies

/// One tool whose argument is a closed set, and the word that signals each
/// value. Matching is a case-insensitive substring so that "saving" covers
/// both "savings" and "my saving account".
struct ArgumentCoverage: Sendable, CustomStringConvertible {
    let tool: String
    let values: [String]

    var description: String { tool }
}

@Suite("Tool catalog")
struct ToolCatalogCoverageTests {
    /// Kept by hand rather than parsed out of `argumentHint`, because the
    /// hint is prose written for a model and a regex over it would be a
    /// second thing to get wrong. Add a row when a tool gains a closed-set
    /// argument; the test then holds you to covering every value.
    static let enumeratedArguments: [ArgumentCoverage] = [
        ArgumentCoverage(tool: "account_balance", values: ["checking", "saving", "credit"]),
        ArgumentCoverage(tool: "account_number", values: ["checking", "saving"]),
        ArgumentCoverage(tool: "routing_number", values: ["checking", "saving"]),
        ArgumentCoverage(tool: "card_number", values: ["debit", "credit"]),
        ArgumentCoverage(tool: "card_limits", values: ["debit", "credit"]),
        ArgumentCoverage(tool: "fees_and_charges", values: ["checking"]),
        // resolve_date_range's period is a closed set, and it is the
        // argument that decides which transactions come back. "this
        // month" and "last month" are one word apart and resolve to
        // windows that do not overlap, so a period without its own vector
        // has to win on the description blended across all of them.
        ArgumentCoverage(
            tool: "resolve_date_range",
            values: [
                "this month", "last month", "this week", "last week",
                "this year", "last year", "today", "yesterday",
                "days", "weeks", "months", "June"
            ]
        )
    ]

    @Test(
        "Every argument value has an example query of its own",
        arguments: enumeratedArguments
    )
    func everyArgumentValueHasItsOwnExample(entry: ArgumentCoverage) throws {
        let tool = try #require(
            ToolCatalog.byName[entry.tool],
            "No ToolCatalog entry named '\(entry.tool)' — the table above is stale."
        )

        for value in entry.values {
            let covered = tool.exampleQueries.contains {
                $0.localizedCaseInsensitiveContains(value)
            }
            // Deliberately NOT satisfied by the description: that is one
            // vector for every value at once, which is the failure mode
            // this test exists to catch.
            #expect(
                covered,
                """
                \(entry.tool) accepts '\(value)' but no example query mentions it, \
                so that value has no embedding vector of its own and must win on \
                the blended description. Add one example using the word.
                Examples today: \(tool.exampleQueries)
                """
            )
        }
    }

    /// The companion rule to the one above, and the reason `notFor` exists
    /// as a separate field: it reaches the LLM prompt but is excluded from
    /// `RoutableToolSpec.embeddingTexts`, so it can repel a query at
    /// selection without attracting it at retrieval. A tool that names a
    /// rival's subject in its own DESCRIPTION gets pulled toward exactly
    /// the queries it means to disown.
    @Test("card_limits disowns the balance without embedding the word")
    func cardLimitsRepelsBalanceQueriesWithoutAttractingThem() throws {
        let cardLimits = try #require(ToolCatalog.byName["card_limits"])

        #expect(
            cardLimits.notFor.localizedCaseInsensitiveContains("balance"),
            "card_limits should rule out balance queries in notFor — it holds limits, not the amount owed."
        )
        #expect(
            !cardLimits.routableSpec.embeddingTexts.contains {
                $0.localizedCaseInsensitiveContains("balance")
            },
            """
            'balance' leaked into card_limits' embedded text (description or an \
            example). That makes it MORE attractive to the balance queries it is \
            supposed to lose — keep the exclusion in notFor, which is not embedded.
            """
        )
    }
}
