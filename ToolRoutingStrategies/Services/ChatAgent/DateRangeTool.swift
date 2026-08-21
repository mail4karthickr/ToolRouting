import Foundation
import FoundationModels

// MARK: - Date range (utility, no client)

/// Turns a period a question NAMES — "this month", "the last 3 months",
/// "June" — into the concrete `yyyy-MM-dd` window `search_transactions`
/// takes.
///
/// THE ARITHMETIC MOVED OUT OF THE MODEL, and that is the whole point.
/// It used to live in `SearchTransactionsTool.MerchantSearch`'s `@Guide`
/// text — "last month is the 1st of the PREVIOUS calendar month; a week of
/// a month is days 1-7, 8-14…" — which asked a 3B on-device model to do
/// calendar arithmetic in the same breath as picking a merchant, a
/// category and an account. That costs twice: it gets the window wrong,
/// and when the answer is wrong there is no way to tell WHICH of the four
/// decisions was the wrong one. A separate call puts the resolved window
/// in the routing trace as its own checkable artifact, and `Calendar`
/// computes it instead of a language model predicting date tokens.
///
/// A STEP-1 TOOL, exactly like `get_location`, and that shape is the fix.
///
/// It was briefly folded into `SearchTransactionsTool` as an argument,
/// because as a routed tool it was never retrieved: "last two months
/// starbucks spend" scored search_transactions 0.75, calculator 0.75,
/// reward_points 0.72, and this below all of them. The merge cured the
/// retrieval and cost the arguments — the model fills a four-field struct
/// well and an eight-field one badly, and the merged tool produced
/// `lastNDays` for "months" and a count of 8 for "two".
///
/// The retrieval problem had a fix already in this codebase, on the chain
/// that works. `get_location` is not embedded against location words; its
/// example queries ARE THE ATM QUERIES — "nearest atm", "atm near me" —
/// so the phrasing that retrieves `find_nearest_atm` retrieves it too.
/// MEASURED: "Where's the nearest ATM?" returns both in the top five.
/// This tool's examples were "this month" and "last month", which is not
/// how anyone asks; they are the SPENDING phrasings now, for the same
/// reason.
///
/// `today` is injected rather than read from `.now` inside, so a test can
/// anchor it to a fixed date and assert exact windows.
struct DateRangeTool: Tool {
    /// Read from the catalog like every other tool, so the text the router
    /// selects on and the text the executing model reads are the same
    /// string. (`catalogEntry` is file-private to Tools.swift.)
    private static var entry: ToolDefinition {
        guard let definition = ToolCatalog.byName["resolve_date_range"] else {
            preconditionFailure("No ToolCatalog entry named 'resolve_date_range'")
        }
        return definition
    }

    var name: String { Self.entry.displayName }
    var description: String { Self.entry.description }

    let today: Date
    let calendar: Calendar

    init(today: Date = .now, calendar: Calendar = .current) {
        self.today = today
        self.calendar = calendar
    }

    // MARK: - Arguments the model writes


    @Generable
    enum Period {
        /// Today only.
        case today
        /// Yesterday only.
        case yesterday
        /// The current calendar week so far, up to today.
        case thisWeek
        /// The whole of the previous calendar week.
        case lastWeek
        /// The current calendar month so far, from the 1st up to today.
        case thisMonth
        /// The whole of the previous calendar month, its 1st to its last day.
        case lastMonth
        /// The current calendar year so far, from January 1st up to today.
        case thisYear
        /// The whole of the previous calendar year.
        case lastYear
        /// A number of days back, ending today, as in "the last 30 days". Set `count`.
        case lastNDays
        /// A number of weeks back, ending today, as in "the last 2 weeks". Set `count`.
        case lastNWeeks
        /// A number of months back, ending today, as in "the last 3 months". Set `count`.
        case lastNMonths
        /// A month named in the question: "June", "December", "March 2025". Set `month`.
        case namedMonth
        /// THE QUESTION NAMES NO PERIOD — "what did I spend at Starbucks?",
        /// "show my Amazon purchases". Every transaction the user has, with
        /// no window at all. THE DEFAULT: pick this unless the question
        /// actually names a time, and never narrow a question that did not
        /// ask to be narrowed.
        ///
        /// POSITION IN THIS LIST DOES NOT DECIDE IT, and it was worth
        /// checking: moved to first, this case still lost — "what did I
        /// spend at Starbucks?" came back `thisMonth` instead of `today`,
        /// and "how much did I spend yesterday?" broke from `yesterday`
        /// to `lastWeek`. Reordering moved which samples failed without
        /// changing how many, so the order is back to the readable one.
        /// It is what makes the dependency unconditional —
        /// search_transactions always has this tool ahead of it, exactly
        /// as find_nearest_atm always has get_location, so there is no
        /// path on which it invents a date because no tool gave it one.
        case allTime
    }

    /// NO OPTIONAL FIELDS, AND A FLAT `Period`. Both halves are MEASURED,
    /// and they pull against each other, so neither is a free choice.
    ///
    /// The fields were `count: Int?` and `month: String?`, with `@Guide`
    /// text naming the periods that needed them. Against 14 questions the
    /// model simply left them out: "the last 30 days" and "the last 3
    /// months" arrived with no count and cost a second round trip to
    /// correct, "in June" and "June or July" arrived with no month and
    /// were never corrected, and "the past two weeks" retried until the
    /// transcript hit the 8192-token context limit and the turn died. An
    /// optional field is a field the model can forget.
    ///
    /// THE OBVIOUS FIX MADE IT WORSE. Moving the values onto the cases —
    /// `case lastNDays(days: Int)`, `case namedMonth(month: String)` —
    /// makes omission impossible, and it wrecked the case selection that
    /// was already working: "this month" came back as
    /// `namedMonth("thismonth")`, "the last 30 days" as `lastNWeeks(4)`,
    /// "the last 3 months" as `lastNWeeks(3)`, "yesterday" as `lastWeek`
    /// plus `today`. Six of fourteen, against five. A flat enum is a
    /// choice between names; an enum with associated values is an object
    /// to construct, and this model discriminates the first far better
    /// than the second.
    ///
    /// So the enum stays flat and the fields stay siblings — but REQUIRED,
    /// each with a documented value meaning "this period does not take
    /// one". A required field always gets written, which is what was
    /// missing; a wrong value on a period that ignores it costs nothing,
    /// because the resolver never reads it.
    @Generable
    struct RangeRequest {
        @Guide(description: "Which period the question names.")
        var period: Period

        @Guide(description: """
            The number in the period — the 30 in "the last 30 days", the 3 in "the last 3 \
            months". Write it exactly as the question says it, in the unit the question \
            uses, and never convert one unit into another: "the past six weeks" is 6 \
            weeks, never 42 days. lastNDays, lastNWeeks and lastNMonths ALWAYS need it. \
            Every other period takes no number: write 0.
            """)
        var count: Int

        @Guide(description: """
            The month the question names, e.g. "June". namedMonth ALWAYS needs it. Every \
            other period takes no month: write an empty string.
            """)
        var month: String

        @Guide(description: """
            The year the question names, e.g. 2025 in "June 2025". Write 0 when the \
            question names no year — a bare month name means the most recent month by \
            that name, which is worked out for you.
            """)
        var year: Int

        init(period: Period, count: Int = 0, month: String = "", year: Int = 0) {
            self.period = period
            self.count = count
            self.month = month
            self.year = year
        }
    }

    // MARK: - Result

    /// `start` is the first moment of its day and `end` the LAST moment of
    /// its day, not midnight. A window ending at midnight excludes
    /// everything that happened on its final day, which is every one of
    /// today's transactions in a "this month" question.
    struct ResolvedRange: Equatable {
        let start: Date
        let end: Date
        let label: String
    }

    /// A `problem` is a sentence the model reads and corrects, never a
    /// thrown error that ends the turn — same contract as `CalculatorTool`.
    enum Resolution: Equatable {
        case range(ResolvedRange)
        case problem(String)
    }

    /// The window rendered for a reader — "last month: 2026-07-01 to
    /// 2026-07-31". Two dates and a name, nothing else: every number in a
    /// tool result is one `calculator` has been told it may copy, so a day
    /// count or a transaction hint here would be a figure waiting to be
    /// added to something.
    static func describe(_ range: ResolvedRange, calendar: Calendar) -> String {
        "\(range.label): \(stamp(range.start, calendar)) to \(stamp(range.end, calendar))"
    }

    func call(arguments: RangeRequest) async throws -> String {
        switch Self.resolve(arguments, today: today, calendar: calendar) {
        case .range(let range):
            return Self.describe(range, calendar: calendar)
        case .problem(let message):
            return message
        }
    }

    // MARK: - Resolution

    static func resolve(_ request: RangeRequest, today: Date, calendar: Calendar) -> Resolution {
        // THE PERIOD CASE DECIDES, and `count`/`month`/`year` are read
        // only by the cases that use them. That is not an oversight, it is
        // MEASURED: a rule letting a non-empty `month` outrank the case
        // was tried here and broke six samples that had been passing.
        //
        // The guides tell the model to leave `month` empty and `count` 0
        // on periods that take neither. It does not. It fills every
        // required field with something plausible read off the turn's
        // date — "How much have I spent this week?" arrives as
        // `thisWeek, count: 1, month: "August", year: 2026`, and "What
        // have I spent today?" as `today, count: 1, month: "August"`. The
        // same reflex that writes the current YEAR into `year` writes the
        // current MONTH into `month`.
        //
        // So a filled field is not evidence of anything, and the case
        // beside it is: across 21 questions the period case was right 20
        // times while `month` was noise on nearly all of them. Required
        // fields bought us an answer where there was an omission; they did
        // not buy a second opinion. Read them where the case asks for
        // them, nowhere else.
        //
        // WITH ONE EXCEPTION, AND IT IS THE NOISE ITSELF THAT LICENSES IT.
        // The junk months are echoes of the turn's date — "August" in
        // August, "July" beside a `lastMonth` — so every one of them lands
        // ON OR BEFORE the current month. A date cannot echo a month that
        // has not happened yet. So a month AHEAD of today did not come
        // from the date; it came from the question, and it is the one
        // value in this struct that the model cannot have filled in
        // reflexively.
        //
        // MEASURED, and it is the whole of what was still failing: "What
        // did I spend at Walmart in December?" arrives as `lastMonth …
        // month: "December"` and "at Amazon in November?" as `lastNMonths,
        // count: 1 … month: "November"` — the month read correctly both
        // times, the case wrong both times. Such a month is last year's,
        // by the same rule `namedMonth` already applies to a bare name.
        let written = request.month.trimmingCharacters(in: .whitespacesAndNewlines)
        if let number = monthNumber(written), number > calendar.component(.month, from: today) {
            return named(written, year: request.year > 0 ? request.year : nil, today: today, calendar)
        }

        // NO COUNT-BASED PROMOTION HERE, and there was one. It turned a
        // plain period arriving with a count of 2 or more into its
        // counted form — `lastMonth` with count 2 became `lastNMonths(2)`
        // — on the premise that nothing about a date makes a model write
        // a 2, so a 2 must have come from the question.
        //
        // THE PREMISE IS FALSE. MEASURED: "How much did I spend at Amazon
        // last week?" arrived as `lastWeek` with count 7 — seven being
        // the days in a week, noise of exactly the kind `month: "August"`
        // is — and the rule promoted a correct `lastWeek` into a wrong
        // `lastNWeeks(7)`, a seven-week window for a one-week question.
        //
        // It cannot be told apart from the arguments: "last two months"
        // as `lastMonth` count 2 and "last week" as `lastWeek` count 7
        // are the same shape. So the rule goes, and the principle below
        // holds without exception — the case decides, and count is read
        // only where the case asks for it.

        switch request.period {
        case .allTime:
            // A floor well before any transaction, rather than
            // `distantPast`, so the window still renders as a readable
            // yyyy-MM-dd pair for the tool that copies it across.
            guard let start = calendar.date(from: DateComponents(year: 2000, month: 1, day: 1)) else {
                return .problem(unreadable)
            }
            return .range(through(today, from: start, label: "all time", calendar))

        case .today:
            return .range(wholeDay(today, label: "today", calendar))

        case .yesterday:
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today) else {
                return .problem(unreadable)
            }
            return .range(wholeDay(yesterday, label: "yesterday", calendar))

        case .thisWeek:
            return soFar(.weekOfYear, label: "this week", today: today, calendar)

        case .lastWeek:
            return previous(.weekOfYear, back: .weekOfYear, label: "last week", today: today, calendar)

        case .thisMonth:
            return soFar(.month, label: "this month", today: today, calendar)

        case .lastMonth:
            return previous(.month, back: .month, label: "last month", today: today, calendar)

        case .thisYear:
            return soFar(.year, label: "this year", today: today, calendar)

        case .lastYear:
            return previous(.year, back: .year, label: "last year", today: today, calendar)

        case .lastNDays:
            switch checked(request.count, unit: "days", limit: 3650) {
            case .problem(let message):
                return .problem(message)
            case .some(let days):
                // One day back is TODAY, and gets today's label — "the
                // last 1 days" is not something anyone writes.
                guard days > 1 else { return .range(wholeDay(today, label: "today", calendar)) }
                // N days INCLUDING today, so "the last 7 days" spans seven
                // dates rather than eight. `list_transactions` counts back
                // differently (N days before now, today on top); these are
                // separate tools with separate contracts, and this one is
                // the literal reading of the phrase.
                guard let start = calendar.date(byAdding: .day, value: -(days - 1), to: today) else {
                    return .problem(unreadable)
                }
                return .range(through(today, from: start, label: "the last \(days) days", calendar))
            }

        case .lastNWeeks:
            switch checked(request.count, unit: "weeks", limit: 520) {
            case .problem(let message):
                return .problem(message)
            case .some(let weeks):
                // 7N DATES ENDING TODAY, not N calendar weeks ending
                // today. Week-aligned, "the last 3 weeks" ran from the
                // Sunday two weeks back — 2026-08-02 to 2026-08-21, which
                // is 20 days, not 21. See the note on lastNMonths: a
                // window asked for in weeks has to be that many weeks long.
                guard let start = calendar.date(byAdding: .day, value: -(weeks * 7 - 1), to: today) else {
                    return .problem(unreadable)
                }
                let label = weeks == 1 ? "the last week" : "the last \(weeks) weeks"
                return .range(through(today, from: start, label: label, calendar))
            }

        case .lastNMonths:
            switch checked(request.count, unit: "months", limit: 120) {
            case .problem(let message):
                return .problem(message)
            case .some(let months):
                // N MONTHS BACK FROM TODAY, so the window is N months
                // long. It used to count calendar months TOUCHED —
                // starting at the 1st of the month N-1 back — and that is
                // short by one partial month every time: "the last 6
                // months" came out as 2026-03-01 to 2026-08-21, which is 5
                // months and 20 days. Found in use, and the objection was
                // simply that March to August is not six months.
                //
                // The window no longer aligns to month boundaries, which
                // is the cost: an average over "the last 3 months" divides
                // a span that starts mid-month. That was the trade
                // deliberately taken — the alternative, the N most recent
                // COMPLETE months, is tidy for averages and silently drops
                // everything spent this month, which is the part a
                // customer asking "how much have I spent" cares about most.
                guard let start = calendar.date(byAdding: .month, value: -months, to: today) else {
                    return .problem(unreadable)
                }
                let label = months == 1 ? "the last month" : "the last \(months) months"
                return .range(through(today, from: start, label: label, calendar))
            }

        case .namedMonth:
            // 0 is the documented "no year named" value, so it becomes the
            // absent year the most-recent rule keys off.
            return named(request.month, year: request.year > 0 ? request.year : nil, today: today, calendar)
        }
    }

    // MARK: - Periods

    private static func wholeDay(_ date: Date, label: String, _ calendar: Calendar) -> ResolvedRange {
        ResolvedRange(start: calendar.startOfDay(for: date), end: endOfDay(date, calendar), label: label)
    }

    /// The current week, month or year up to TODAY — never to the unit's
    /// own end, which is a window running into the future.
    private static func soFar(
        _ unit: Calendar.Component, label: String, today: Date, _ calendar: Calendar
    ) -> Resolution {
        guard let interval = calendar.dateInterval(of: unit, for: today) else {
            return .problem(unreadable)
        }
        return .range(through(today, from: interval.start, label: label, calendar))
    }

    /// The whole of the week, month or year before this one.
    private static func previous(
        _ unit: Calendar.Component, back step: Calendar.Component,
        label: String, today: Date, _ calendar: Calendar
    ) -> Resolution {
        guard let current = calendar.dateInterval(of: unit, for: today),
              let inPrevious = calendar.date(byAdding: step, value: -1, to: current.start),
              let interval = calendar.dateInterval(of: unit, for: inPrevious) else {
            return .problem(unreadable)
        }
        // `DateInterval.end` is the first moment of the NEXT unit, so a
        // second before it is the last moment of this one's final day.
        return .range(
            ResolvedRange(start: interval.start, end: interval.end.addingTimeInterval(-1), label: label)
        )
    }

    private static func named(
        _ month: String, year requested: Int?, today: Date, _ calendar: Calendar
    ) -> Resolution {
        let written = month.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !written.isEmpty else {
            return .problem("Which month? Name it, e.g. 'June', or ask for thisMonth or lastMonth instead.")
        }
        guard let number = monthNumber(written) else {
            return .problem("Could not read a month from '\(written)'. Use a name like 'June' or a number from 1 to 12.")
        }

        let thisYear = calendar.component(.year, from: today)
        let thisMonth = calendar.component(.month, from: today)
        // A bare month name means the most recent one that has already
        // started: asked in August, "December" is LAST December, not the
        // one four months away.
        let mostRecent = number <= thisMonth ? thisYear : thisYear - 1

        // THE CURRENT YEAR IS TREATED AS NO YEAR AT ALL, and that is the
        // fix for the one question in this dataset that stayed broken
        // through three rewordings of the guides.
        //
        // MEASURED: "Show me what I spent in December", asked with "Today's
        // date: 2026-08-21" in the turn, reached this tool as namedMonth
        // "December" with year 2026 — the model read the year off the turn
        // and filled the field with it rather than the 0 the guide asks
        // for. This then refused with "December 2026 hasn't started yet",
        // which is true and useless.
        //
        // A model echoing the current year is indistinguishable from a user
        // who named no year, so the two are answered the same way. Any
        // OTHER year is a deliberate statement and is honoured, including a
        // genuinely future one, which still gets the refusal below.
        let year: Int
        if let requested, requested != thisYear {
            year = requested
        } else {
            year = mostRecent
        }
        let label = "\(monthNames[number - 1].capitalized) \(year)"

        guard let first = calendar.date(from: DateComponents(year: year, month: number, day: 1)),
              let interval = calendar.dateInterval(of: .month, for: first) else {
            return .problem(unreadable)
        }
        guard interval.start <= today else {
            return .problem("\(label) hasn't started yet — today is \(stamp(today, calendar)).")
        }
        // Capped at today, so the CURRENT month named by name resolves the
        // same as `thisMonth` rather than running into the future.
        let end = min(interval.end.addingTimeInterval(-1), endOfDay(today, calendar))
        return .range(ResolvedRange(start: interval.start, end: end, label: label))
    }

    // MARK: - Pieces

    private static func through(
        _ today: Date, from start: Date, label: String, _ calendar: Calendar
    ) -> ResolvedRange {
        ResolvedRange(
            start: calendar.startOfDay(for: start),
            end: endOfDay(today, calendar),
            label: label
        )
    }

    private static func endOfDay(_ date: Date, _ calendar: Calendar) -> Date {
        guard let next = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date)) else {
            return date
        }
        return next.addingTimeInterval(-1)
    }

    private enum Count {
        case some(Int)
        case problem(String)
    }

    /// 0 is the documented "this period takes no number" value, so on a
    /// period that DOES take one it means the model skipped it — asking
    /// for the number is the useful reply, not complaining about the zero.
    private static func checked(_ count: Int, unit: String, limit: Int) -> Count {
        guard count >= 1 else {
            return .problem("How many \(unit)? Say the number the question asks for, e.g. 3 for 'the last 3 \(unit)'.")
        }
        guard count <= limit else {
            return .problem("\(count) \(unit) is further back than this resolves. Ask for \(limit) \(unit) or fewer.")
        }
        return .some(count)
    }

    /// `yyyy-MM-dd` built from the calendar's own components rather than
    /// an ISO format style, which renders in GMT and so names the wrong
    /// DAY either side of midnight in every other zone. The window has to
    /// agree with the calendar that computed it.
    private static func stamp(_ date: Date, _ calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// English only, like the rest of the app, and matched by prefix so
    /// "Jun", "june" and "Sept" all land. Deliberately not
    /// `Calendar.monthSymbols`, which is nil-locale dependent — the tool
    /// takes whatever calendar it is handed, including one built in a test.
    private static let monthNames = [
        "january", "february", "march", "april", "may", "june",
        "july", "august", "september", "october", "november", "december"
    ]

    private static func monthNumber(_ text: String) -> Int? {
        let written = text.lowercased()
        if let digits = Int(written), (1...12).contains(digits) { return digits }
        guard written.count >= 3 else { return nil }
        return monthNames.firstIndex { $0.hasPrefix(written) }.map { $0 + 1 }
    }

    private static let unreadable = "Could not work out that period from today's date. Name a plainer one, e.g. thisMonth or lastMonth."
}
