/*
Locks the calendar arithmetic DateRangeTool does on the model's behalf.

The point of the tool is that Calendar computes the window rather than a
3B model working it out in a `@Guide` string — so what is asserted here is
every period against ONE fixed anchor date, plus the two things that
silently corrupt a spending total when they are wrong: a window ending at
midnight (which drops the whole of its last day) and a bare month name
resolving into the future.

The anchor is 2026-08-21, a FRIDAY in the middle of a month in the middle
of a year — every period has something on both sides of it. The calendar
is built here rather than taken from `.current` so the run does not depend
on the machine's time zone or first weekday.

Pure logic — no MLX, no Apple Intelligence, no network, no session.
*/

import Foundation
import Testing
@testable import ToolRoutingStrategies

@Suite("Date Range Tool")
struct DateRangeToolTests {

    // MARK: - Fixtures

    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        calendar.firstWeekday = 1 // Sunday
        return calendar
    }()

    /// Friday 2026-08-21, at midday so the anchor is not itself sitting on
    /// a day boundary.
    static let today: Date = {
        guard let date = calendar.date(
            from: DateComponents(year: 2026, month: 8, day: 21, hour: 12)
        ) else {
            fatalError("Could not build the anchor date")
        }
        return date
    }()

    private func window(
        _ period: DateRangeTool.Period, count: Int = 0, month: String = "", year: Int = 0
    ) throws -> (start: String, end: String, label: String) {
        let request = DateRangeTool.RangeRequest(period: period, count: count, month: month, year: year)
        switch DateRangeTool.resolve(request, today: Self.today, calendar: Self.calendar) {
        case .range(let range):
            return (Self.stamp(range.start), Self.stamp(range.end), range.label)
        case .problem(let message):
            Issue.record("expected a range, got: \(message)")
            throw ResolutionFailure()
        }
    }

    private func problem(
        _ period: DateRangeTool.Period, count: Int = 0, month: String = "", year: Int = 0
    ) throws -> String {
        let request = DateRangeTool.RangeRequest(period: period, count: count, month: month, year: year)
        switch DateRangeTool.resolve(request, today: Self.today, calendar: Self.calendar) {
        case .range(let range):
            Issue.record("expected a problem, got: \(range)")
            throw ResolutionFailure()
        case .problem(let message):
            return message
        }
    }

    private struct ResolutionFailure: Error {}

    private static func stamp(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    // MARK: - Days

    @Test("Today and yesterday are single days")
    func resolvesSingleDays() throws {
        let today = try window(.today)
        #expect(today.start == "2026-08-21")
        #expect(today.end == "2026-08-21")

        let yesterday = try window(.yesterday)
        #expect(yesterday.start == "2026-08-20")
        #expect(yesterday.end == "2026-08-20")
    }

    @Test("allTime spans everything up to today")
    func resolvesAllTime() throws {
        // The period for a question that names none. It exists so
        // search_transactions always has a window from this tool rather
        // than one it worked out itself — see the note on Period.allTime.
        let everything = try window(.allTime)
        #expect(everything.start == "2000-01-01")
        #expect(everything.end == "2026-08-21")
        #expect(everything.label == "all time")
    }

    // MARK: - Weeks

    @Test("This week runs from Sunday up to today, not to the end of the week")
    func resolvesThisWeek() throws {
        // Anchor is a Friday; the week containing it starts Sunday the
        // 16th. The end is TODAY — a window running to Saturday the 22nd
        // is a window into the future.
        let week = try window(.thisWeek)
        #expect(week.start == "2026-08-16")
        #expect(week.end == "2026-08-21")
    }

    @Test("Last week is the whole of the previous week")
    func resolvesLastWeek() throws {
        let week = try window(.lastWeek)
        #expect(week.start == "2026-08-09")
        #expect(week.end == "2026-08-15")
    }

    // MARK: - Months

    @Test("This month runs from the 1st up to today")
    func resolvesThisMonth() throws {
        let month = try window(.thisMonth)
        #expect(month.start == "2026-08-01")
        #expect(month.end == "2026-08-21")
    }

    @Test("Last month is the whole of the previous calendar month")
    func resolvesLastMonth() throws {
        // July has 31 days, so the last day is one the model gets wrong by
        // assuming 30.
        let month = try window(.lastMonth)
        #expect(month.start == "2026-07-01")
        #expect(month.end == "2026-07-31")
    }

    // MARK: - Years

    @Test("This year runs from January 1st up to today")
    func resolvesThisYear() throws {
        let year = try window(.thisYear)
        #expect(year.start == "2026-01-01")
        #expect(year.end == "2026-08-21")
    }

    @Test("Last year is the whole of the previous calendar year")
    func resolvesLastYear() throws {
        let year = try window(.lastYear)
        #expect(year.start == "2025-01-01")
        #expect(year.end == "2025-12-31")
    }

    // MARK: - Counted periods

    @Test("The last N days spans N dates, today included")
    func resolvesLastNDays() throws {
        let week = try window(.lastNDays, count: 7)
        #expect(week.start == "2026-08-15")
        #expect(week.end == "2026-08-21")

        // Across a month boundary, which is the case that breaks when the
        // arithmetic is done by subtracting 30 from a day number.
        let month = try window(.lastNDays, count: 30)
        #expect(month.start == "2026-07-23")
        #expect(month.end == "2026-08-21")
    }

    @Test("The last N weeks spans exactly 7N dates, ending today")
    func resolvesLastNWeeks() throws {
        // Aug 8 to Aug 21 is 14 dates. Week-ALIGNED, this started at the
        // Sunday one week back (Aug 9) and spanned 13 — a fortnight that
        // is not a fortnight.
        let weeks = try window(.lastNWeeks, count: 2)
        #expect(weeks.start == "2026-08-08")
        #expect(weeks.end == "2026-08-21")
    }

    @Test("The last N months spans exactly N months, ending today")
    func resolvesLastNMonths() throws {
        // MEASURED IN USE: this counted calendar months TOUCHED, so "the
        // last 6 months" resolved to 2026-03-01 to 2026-08-21 — five
        // months and twenty days. March to August is not six months.
        let months = try window(.lastNMonths, count: 3)
        #expect(months.start == "2026-05-21")
        #expect(months.end == "2026-08-21")
        #expect(months.label == "the last 3 months")

        let half = try window(.lastNMonths, count: 6)
        #expect(half.start == "2026-02-21")
        #expect(half.end == "2026-08-21")
    }

    @Test("A count of 12 months crosses the year boundary")
    func resolvesAcrossTheYear() throws {
        let year = try window(.lastNMonths, count: 12)
        #expect(year.start == "2025-08-21")
        #expect(year.end == "2026-08-21")
    }

    @Test("A count of 1 is a rolling month or week, not the calendar one")
    func aCountOfOneRollsBack() throws {
        // Rolling, these are honest names: "the last month" IS the month
        // up to today, and it is a different window from `lastMonth`,
        // which means July. Under the old month-aligned arithmetic the
        // same call produced 2026-08-01 to 2026-08-21 and had to be
        // relabelled "this month" to stop it reading as July.
        let month = try window(.lastNMonths, count: 1)
        #expect(month.start == "2026-07-21")
        #expect(month.end == "2026-08-21")
        #expect(month.label == "the last month")

        let week = try window(.lastNWeeks, count: 1)
        #expect(week.start == "2026-08-15")
        #expect(week.label == "the last week")

        // One day back is today, which keeps today's name.
        #expect(try window(.lastNDays, count: 1).label == "today")
    }

    // MARK: - Named months

    @Test("A month already past this year resolves to this year")
    func resolvesNamedMonthThisYear() throws {
        let june = try window(.namedMonth, month: "June")
        #expect(june.start == "2026-06-01")
        #expect(june.end == "2026-06-30")
        #expect(june.label == "June 2026")
    }

    @Test("A month still ahead this year resolves to LAST year")
    func resolvesNamedMonthLastYear() throws {
        // Asked in August, "December" is the December that happened, not
        // the one four months away.
        let december = try window(.namedMonth, month: "December")
        #expect(december.start == "2025-12-01")
        #expect(december.end == "2025-12-31")
        #expect(december.label == "December 2025")
    }

    @Test("The current month named by name stops at today")
    func capsTheCurrentNamedMonth() throws {
        let august = try window(.namedMonth, month: "August")
        #expect(august.start == "2026-08-01")
        #expect(august.end == "2026-08-21")
    }

    @Test("A year the question names wins over the most-recent rule")
    func honoursAnExplicitYear() throws {
        let june = try window(.namedMonth, month: "June", year: 2025)
        #expect(june.start == "2025-06-01")
        #expect(june.end == "2025-06-30")
    }

    @Test("Month names are read short, long, capitalised, or as a number")
    func readsMonthHowever() throws {
        #expect(try window(.namedMonth, month: "jun").start == "2026-06-01")
        #expect(try window(.namedMonth, month: "Sept").start == "2025-09-01")
        #expect(try window(.namedMonth, month: "05").start == "2026-05-01")
        #expect(try window(.namedMonth, month: " May ").start == "2026-05-01")
    }

    // MARK: - The boundary that corrupts a total

    @Test("A window ends at the LAST moment of its final day, not midnight")
    func endsAtTheEndOfTheDay() throws {
        // A window ending at 00:00 on the 21st drops every transaction
        // that happened on the 21st — which in a "this month" question is
        // all of today's spending, silently.
        let request = DateRangeTool.RangeRequest(period: .thisMonth)
        guard case .range(let month) = DateRangeTool.resolve(
            request, today: Self.today, calendar: Self.calendar
        ) else {
            Issue.record("this month did not resolve")
            return
        }

        let parts = Self.calendar.dateComponents([.hour, .minute, .second], from: month.end)
        #expect(parts.hour == 23)
        #expect(parts.minute == 59)
        #expect(parts.second == 59)
        #expect(month.end > Self.today, "the window has to include the anchor's own time of day")

        let start = Self.calendar.dateComponents([.hour, .minute, .second], from: month.start)
        #expect(start.hour == 0 && start.minute == 0 && start.second == 0)
    }

    // MARK: - Malformed calls come back as sentences

    @Test("A counted period whose count was left at 0 asks for the number")
    func asksForAMissingCount() throws {
        // 0 is the documented "this period takes no number" value, so on a
        // counted period it means the model skipped it — which it did, on
        // 3 of 14 questions, back when the field was optional. See the
        // note on `RangeRequest`.
        #expect(try problem(.lastNMonths, count: 0).contains("How many months"))
        #expect(try problem(.lastNDays, count: 0).contains("How many days"))
        #expect(try problem(.lastNWeeks, count: -3).contains("How many weeks"))
    }

    @Test("An absurd count is refused rather than resolving to a year nobody meant")
    func refusesOversizedCount() throws {
        #expect(try problem(.lastNMonths, count: 5000).contains("further back"))
    }

    @Test("An empty or unreadable month name is refused")
    func refusesUnreadableMonth() throws {
        #expect(try problem(.namedMonth, month: "").contains("Which month?"))
        #expect(try problem(.namedMonth, month: "Smarch").contains("Could not read a month"))
        #expect(try problem(.namedMonth, month: "13").contains("Could not read a month"))
    }

    @Test("A month still ahead this year outranks the period case beside it")
    func aMonthAheadOfTodayWins() throws {
        // MEASURED: both of these are real calls. The month was read
        // correctly and the case was not — and a month later in the year
        // than today cannot be an echo of today's date, which is what
        // makes it trustworthy where "August" is not. See resolve.
        let december = try window(.lastMonth, count: 1, month: "December", year: 2026)
        #expect(december.start == "2025-12-01")
        #expect(december.end == "2025-12-31")
        #expect(december.label == "December 2025")

        let november = try window(.lastNMonths, count: 1, month: "November", year: 2026)
        #expect(november.start == "2025-11-01")
        #expect(november.label == "November 2025")
    }

    @Test("A count beside a period that takes none is ignored")
    func ignoresACountThePeriodDoesNotUse() throws {
        // MEASURED: "last week" arrived as `lastWeek` with count 7 — the
        // days in a week, noise. A rule here used to promote that to
        // lastNWeeks(7); see the note in resolve for why it is gone.
        let week = try window(.lastWeek, count: 7, month: "August", year: 2026)
        #expect(week.start == "2026-08-09")
        #expect(week.end == "2026-08-15")
        #expect(week.label == "last week")

        let month = try window(.lastMonth, count: 2, month: "August", year: 2026)
        #expect(month.start == "2026-07-01")
        #expect(month.label == "last month")
    }

    @Test("This year, on a month still ahead, is read as no year at all")
    func readsTheCurrentYearAsUnspecified() throws {
        // The model reads 2026 off "Today's date: 2026-08-21" and fills the
        // field with it instead of the 0 the guide asks for — MEASURED, and
        // it is the same request as a bare "December". See the note in
        // DateRangeTool.
        let december = try window(.namedMonth, month: "December", year: 2026)
        #expect(december.start == "2025-12-01")
        #expect(december.end == "2025-12-31")
        #expect(december.label == "December 2025")

        // A month of this year that HAS come round is untouched by the rule.
        let june = try window(.namedMonth, month: "June", year: 2026)
        #expect(june.start == "2026-06-01")
    }

    @Test("A future year the question actually names is refused, not quietly rolled back")
    func refusesAFutureMonth() throws {
        // 2027 cannot be an echo of today's date, so it is a real request
        // for a month that has not happened.
        let message = try problem(.namedMonth, month: "September", year: 2027)
        #expect(message.contains("hasn't started yet"))
        #expect(message.contains("2026-08-21"))
    }

    // MARK: - How the window reaches the reply

    @Test("The window is rendered with both dates, for the reply and the trace")
    func rendersBothDates() throws {
        func described(_ period: DateRangeTool.Period, count: Int = 0) throws -> String {
            let request = DateRangeTool.RangeRequest(period: period, count: count)
            guard case .range(let range) = DateRangeTool.resolve(
                request, today: Self.today, calendar: Self.calendar
            ) else {
                Issue.record("\(period) did not resolve")
                throw ResolutionFailure()
            }
            return DateRangeTool.describe(range, calendar: Self.calendar)
        }

        #expect(try described(.lastMonth) == "last month: 2026-07-01 to 2026-07-31")
        #expect(try described(.lastNMonths, count: 3) == "the last 3 months: 2026-05-21 to 2026-08-21")
    }
}
