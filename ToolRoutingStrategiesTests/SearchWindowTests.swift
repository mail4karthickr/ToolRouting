/*
Does the window search_transactions APPLIES match the window it was given?

The two tools hand a date range across as text — `resolve_date_range`
renders `2026-07-31`, `search_transactions` parses it back — and the round
trip used to lose the end of the last day and the time zone with it.

MEASURED, spending_chain_qa #2: "how much did i spnd at walmart last mnth"
resolved `last month: 2026-07-01 to 2026-07-31`, correctly, and then
returned two of July's three Walmart charges. The $73.45 on the 31st was
dropped, the total came out $113.85 instead of $187.30, and every figure
in the reply was real — which is what makes this the worst shape of wrong.

So what is asserted here is the BOUNDARY, on both edges, against the real
mock data. No model, no MLX: this is arithmetic and it should never need a
device to catch.
*/

import Foundation
import Testing
@testable import ToolRoutingStrategies

@Suite("Search window boundaries")
struct SearchWindowTests {

    private func search(
        merchant: String, from start: String, to end: String
    ) async throws -> String {
        try await SearchTransactionsTool(client: MockBankAPIClient()).call(
            arguments: .init(merchant: merchant, startDate: start, endDate: end)
        )
    }

    /// The fixture is built with `daysAgo(n)` from `.now`, so which
    /// calendar month a charge falls in shifts daily. These assertions are
    /// written against whatever day the suite runs on rather than a fixed
    /// date: the offsets are what is fixed.
    private func dayString(daysAgo days: Int) -> String {
        let calendar = Calendar.current
        let date = calendar.date(byAdding: .day, value: -days, to: .now) ?? .now
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    @Test("A window ending on a transaction's own day includes it")
    func endDateIncludesItsWholeDay() async throws {
        // Walmart 21 days back is $73.45. A window ending on exactly that
        // day has to contain it — under the old parse the end landed at
        // midnight UTC and the charge fell outside by hours.
        let output = try await search(
            merchant: "Walmart", from: dayString(daysAgo: 25), to: dayString(daysAgo: 21)
        )
        #expect(output.contains("73.45"), "the charge on the window's final day was dropped: \(output)")
    }

    @Test("A window starting on a transaction's own day includes it")
    func startDateIncludesItsWholeDay() async throws {
        // The other edge, and the one a UTC parse breaks in a zone ahead
        // of UTC: a start read as midnight UTC is 05:30 local, so a
        // morning transaction on the first day of the window falls out.
        let output = try await search(
            merchant: "Walmart", from: dayString(daysAgo: 21), to: dayString(daysAgo: 17)
        )
        #expect(output.contains("73.45"), "the charge on the window's first day was dropped: \(output)")
    }

    @Test("A single day window finds that day's transaction")
    func singleDayWindow() async throws {
        let day = dayString(daysAgo: 21)
        let output = try await search(merchant: "Walmart", from: day, to: day)
        #expect(output.contains("73.45"), "a one-day window found nothing on a day with a charge: \(output)")
    }

    @Test("A window excludes the day after it ends")
    func endDateStopsAtItsOwnDay() async throws {
        // Walmart 21 days back is $73.45 and 36 days back is $64.10. A
        // window ending the day BEFORE the later charge must not reach it
        // — the fix widens the end by a day, and this is what stops it
        // widening by more.
        let output = try await search(
            merchant: "Walmart", from: dayString(daysAgo: 36), to: dayString(daysAgo: 22)
        )
        #expect(output.contains("64.10"), "the earlier charge is inside the window: \(output)")
        #expect(!output.contains("73.45"), "a charge one day past the end leaked in: \(output)")
    }

    @Test("An unreadable date comes back as a sentence, not an error")
    func refusesAnUnreadableDate() async throws {
        let output = try await search(merchant: "Walmart", from: "last month", to: "2026-07-31")
        #expect(output.contains("Could not read a date"))
    }

    @Test("Omitting both dates searches everything")
    func noWindowSearchesEverything() async throws {
        let output = try await SearchTransactionsTool(client: MockBankAPIClient()).call(
            arguments: .init(merchant: "Walmart")
        )
        // All six Walmart charges in the fixture.
        for amount in ["58.20", "73.45", "64.10", "49.75", "70.90", "55.30"] {
            #expect(output.contains(amount), "\(amount) missing from an unbounded search: \(output)")
        }
    }
}
