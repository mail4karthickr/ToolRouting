/*
The shape of what tools hand the model, tested where it is cheap.

Every judge score this project has lost to "reads like a data dump" was
lost to a PAYLOAD, not to a prompt: rows joined by newlines get pasted
back as rows, `Label: $amount` gets pasted back with its colon, and a
count in front of a list comes back as a total the model worked out
itself. The instructions cannot reach any of that — the one time they
were asked to, the model started merging figures across rows instead.

So the shapes are asserted here, in milliseconds, instead of being
rediscovered six minutes at a time through a judged eval run.
*/

import Testing
@testable import ToolRoutingStrategies

@Suite("Tool output shape")
struct ToolOutputTests {
    // MARK: The finders

    /// The closest one in full, the rest by name only.
    ///
    /// Both halves are load-bearing and were measured on opposite
    /// failures: spelling every row out in full got all three recited
    /// back ("atm near me", Naturalness 3), and dropping the others
    /// entirely would have the tool decide what the customer may know.
    @Test("A finder answers with the closest, and names the rest")
    func nearestLeadsWithTheClosest() {
        let sentence = ToolOutput.nearest(
            [
                "Market Square ATM, 0.1 miles away and open 24 hours",
                "Main St Branch ATM, 0.4 miles away and open 24 hours",
                "QuickCash Mart, 0.6 miles away and open until 11 pm"
            ],
            kind: "ATM",
            empty: "No ATMs nearby."
        )

        #expect(sentence == """
            The closest ATM is Market Square ATM, 0.1 miles away and open 24 hours. \
            Main St Branch ATM and QuickCash Mart are also nearby.
            """)

        // The runners-up keep their names and lose their figures: those
        // are what got recited.
        #expect(!sentence.contains("0.4 miles"))
        #expect(!sentence.contains("until 11 pm"))
    }

    @Test("A single result needs no also-nearby clause")
    func nearestWithOneResult() {
        let sentence = ToolOutput.nearest(
            ["Market Square ATM, 0.1 miles away and open 24 hours"],
            kind: "ATM",
            empty: "No ATMs nearby."
        )
        #expect(sentence == "The closest ATM is Market Square ATM, 0.1 miles away and open 24 hours.")
    }

    @Test("Nothing nearby says so plainly")
    func nearestWithNoResults() {
        #expect(ToolOutput.nearest([], kind: "ATM", empty: "No ATMs nearby.") == "No ATMs nearby.")
    }

    /// `nearest` finds the name by splitting at the first comma, which is
    /// a promise about how the client writes a row. If a row ever leads
    /// with something else, this is what says so.
    @Test("A row's name is what precedes its detail")
    func rowNamesAreReadable() async throws {
        let client = MockBankAPIClient()
        let atms = try await client.findNearestATMs(latitude: 37.7749, longitude: -122.4194)
        let branches = try await client.findNearestBranches(latitude: 37.7749, longitude: -122.4194)

        #expect(ToolOutput.name(inRow: atms[0]) == "Market Square ATM")
        #expect(ToolOutput.name(inRow: branches[0]) == "Main St Branch (BR-4417)")
    }

    // MARK: Lists

    /// A complete list carries no count, because a count in front of one
    /// comes back as a total the model computed: "three scheduled
    /// payments totaling $2,345.89", a figure that cannot exist because
    /// one of the three is a statement balance.
    @Test("A complete list leads with what it is, never with how many")
    func sentenceCarriesNoCount() async throws {
        let client = MockBankAPIClient()
        let scheduled = try await ScheduledPaymentsTool(client: client)
            .call(arguments: .init(account: .all))

        #expect(scheduled.contains("$1,850"))
        #expect(!scheduled.contains("3 "))
        #expect(!scheduled.contains("three"))
    }

    /// Pending and scheduled are different lists from different tools,
    /// and the reply has repeatedly reported one as the other. The status
    /// lives in the lead, because a payment's own clause says what it is
    /// and when — never which list it came from.
    @Test("Pending output says pending, scheduled says scheduled")
    func paymentListsAreDistinguishable() async throws {
        let client = MockBankAPIClient()
        let pending = try await PendingPaymentsTool(client: client)
            .call(arguments: .init(account: .all))
        let scheduled = try await ScheduledPaymentsTool(client: client)
            .call(arguments: .init(account: .all))

        #expect(pending.contains("pending"))
        #expect(pending.contains("processing"))
        #expect(scheduled.contains("scheduled"))
        #expect(!scheduled.contains("pending"))
    }

    // MARK: No tables anywhere

    /// The middot is the tell. Every payload that has ever been pasted
    /// through verbatim was separated by one, or by a newline, and the
    /// last of them — `search_transactions` — lost its rows on
    /// 2026-08-13. This is the guard against the next one arriving.
    @Test(
        "No tool hands the model a table",
        arguments: [
            ("account_balance", "all"), ("card_limits", "all"), ("card_number", "all"),
            ("fees_and_charges", "all"), ("pending_payments", "all"), ("scheduled_payments", "all"),
            ("search_transactions", "Amazon"), ("list_transactions", "7"),
            ("find_nearest_atm", ""), ("find_nearest_branch", "")
        ]
    )
    func noToolReturnsRows(tool: String, argument: String) async throws {
        let output = await MockGroundTruth.toolOutput(tools: [tool], arguments: [argument])
        #expect(!output.contains("·"), "\(tool) returned middot-separated fields: \(output)")
        #expect(!output.contains("\n"), "\(tool) returned more than one line: \(output)")
    }
}
