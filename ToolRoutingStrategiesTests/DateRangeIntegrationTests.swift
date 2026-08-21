/*
Does the MODEL reach the right window, through the tool that actually
carries it?

`DateRangeToolTests` asserts the arithmetic: given `lastMonth`, Calendar
returns 2026-07-01 to 2026-07-31. That leaves the half the split exists to
de-risk untested — whether a 3B on-device model, handed a question in
English, picks `lastMonth` at all rather than `lastNDays` with a 30 in it.

THE PERIOD IS AN ARGUMENT OF search_transactions NOW, so that is what this
binds. It was briefly a routed tool of its own and the routing is what
failed — "last two months starbucks spend" ranked the date tool below
reward_points, so it was never shortlisted, never selected, and
search_transactions filled in a window itself. This suite moved with the
period: same 22 questions, now asked of the tool that owns it.

WHAT IS ASSERTED IS THE WINDOW THE TOOL RESOLVED, not the reply. The reply
is the model's prose and belongs to the eval; the window is a fact. The
recorder keeps the arguments too — a wrong window can be a wrong period
case or a wrong count beside a right one, and those have different fixes.

THE TURN IS SHAPED LIKE THE PRODUCTION ONE, date and all, because
`AgentPrompt.request` puts today's date in every turn it builds and a
mapping measured without it is measured against a prompt this app never
sends.

Needs Apple Intelligence, and it is slow — one model round trip per
sample. Cases live in date_range_qa.json; add to that file, not this one.
*/

import Foundation
import Testing
import FoundationModels
@testable import ToolRoutingStrategies

struct DateRangeSample: Codable, Sendable {
    let question: String
    let expectedRanges: [String]
}

/// Wraps the real `resolve_date_range` and keeps every window it returned,
/// so the test can assert on the tool's own output rather than parsing it
/// back out of the model's prose. The ARGUMENTS are kept too — a wrong
/// window can be a wrong period case or a wrong count beside a right one,
/// and those have different fixes.
private final class RecordingDateRangeTool: Tool, @unchecked Sendable {
    typealias Arguments = DateRangeTool.RangeRequest

    let name: String
    let description: String

    private let inner: DateRangeTool
    private let lock = NSLock()
    private var recorded: [(window: String, arguments: String)] = []

    init(today: Date, calendar: Calendar) {
        self.inner = DateRangeTool(today: today, calendar: calendar)
        self.name = inner.name
        self.description = inner.description
    }

    var windows: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded.map(\.window)
    }

    var calls: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded.map { "\($0.arguments) → \($0.window)" }
    }

    func call(arguments: DateRangeTool.RangeRequest) async throws -> String {
        let output = try await inner.call(arguments: arguments)
        let described = """
            period: \(arguments.period), count: \(arguments.count), \
            month: "\(arguments.month)", year: \(arguments.year)
            """
        lock.lock()
        recorded.append((output, described))
        lock.unlock()
        return output
    }
}

@Suite("Date range — bound to a session", .serialized)
struct DateRangeIntegrationTests {

    static let samples: [DateRangeSample] = {
        guard let url = #bundle.url(forResource: "date_range_qa", withExtension: "json") else {
            fatalError("""
                Missing required resource: date_range_qa.json. \
                Ensure it is included in the ToolRoutingStrategiesTests target.
                """)
        }
        let all: [DateRangeSample]
        do {
            all = try JSONDecoder().decode([DateRangeSample].self, from: Data(contentsOf: url))
        } catch {
            fatalError("Could not decode date_range_qa.json: \(error)")
        }
        return filtered(all)
    }()

    /// Narrows the run to the questions being worked on. Every sample is a
    /// model round trip, so fixing one failure by re-running all of them
    /// costs half a minute a try and buries the one line you are reading.
    ///
    ///     TEST_RUNNER_DATE_RANGE_ONLY="December|two weeks" xcodebuild test …
    ///
    /// The `TEST_RUNNER_` prefix is what xcodebuild strips and forwards to
    /// the test process; matching is case-insensitive substring, `|`
    /// separating alternatives. ALWAYS finish with an unfiltered run — a
    /// guide edit that fixes the sample you are watching is perfectly
    /// capable of breaking two you are not.
    private static func filtered(_ samples: [DateRangeSample]) -> [DateRangeSample] {
        let wanted = (ProcessInfo.processInfo.environment["DATE_RANGE_ONLY"] ?? "")
            .split(separator: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !wanted.isEmpty else { return samples }
        return samples.filter { sample in
            wanted.contains { sample.question.localizedCaseInsensitiveContains($0) }
        }
    }

    /// The same model configuration `ChatAgent` answers with, so a mapping
    /// that holds here holds there.
    private static let model = SystemLanguageModel(
        useCase: .general,
        guardrails: .permissiveContentTransformations
    )

    /// Deliberately NOT `AgentPrompt.system`. That block is nine paragraphs
    /// about how to word a banking reply, and none of it is about periods —
    /// including it would test the whole Stage 3 prompt rather than this
    /// mapping.
    private static let instructions = """
        You work out the dates a spending question covers. Call \
        resolve_date_range for every period the question names, so a \
        question comparing two periods calls it twice, then say what it \
        returned. A question naming no period still needs one call, with \
        allTime. Never work a date out yourself.
        """

    /// Shared with `DateRangeToolTests` on purpose: the unit test and this
    /// one describe the same Friday, so an expected window can be read
    /// across both files.
    private static var today: Date { DateRangeToolTests.today }
    private static var calendar: Calendar { DateRangeToolTests.calendar }

    /// `AgentPrompt.request(for:tools:)`'s single-tool turn, rebuilt rather
    /// than called: that builder reads `Date.now`, and every expected
    /// window here is anchored to 2026-08-21, so calling it would make the
    /// fixture correct only on the day it was written. The SHAPE is copied
    /// line for line; if that builder's wording changes, this follows it.
    private static func turn(for question: String) -> String {
        """
        Today's date: \(todayStamp)
        Customer's question: "\(question)"

        Call resolve_date_range before writing anything, then answer the question \
        above using only the figures it returned.
        """
    }

    private static var todayStamp: String {
        let parts = calendar.dateComponents([.year, .month, .day], from: today)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private func ask(
        _ question: String
    ) async throws -> (windows: [String], calls: [String], reply: String) {
        let recorder = RecordingDateRangeTool(today: Self.today, calendar: Self.calendar)
        let session = LanguageModelSession(
            model: Self.model,
            tools: [recorder],
            instructions: Self.instructions
        )
        // Greedy rather than the 0.3 `ChatAgent` answers with: this is a
        // mapping test, and a sample that passes on one run and fails on
        // the next tells you nothing about the mapping.
        let response = try await session.respond(
            to: Self.turn(for: question),
            options: GenerationOptions(sampling: .greedy)
        )
        return (recorder.windows, recorder.calls, response.content)
    }

    @Test(
        "The question's period reaches the tool as the right window",
        .enabled(if: SystemLanguageModel.default.isAvailable),
        arguments: samples
    )
    func resolvesThePeriodTheQuestionNames(_ sample: DateRangeSample) async throws {
        let (windows, calls, reply) = try await ask(sample.question)

        #expect(
            !windows.isEmpty,
            "resolve_date_range was never called for \"\(sample.question)\": \(reply)"
        )
        // Order-insensitive: "this month versus last month" is the same
        // pair of windows whichever the model resolves first.
        #expect(
            Set(windows) == Set(sample.expectedRanges),
            """
            \"\(sample.question)\"
            expected \(sample.expectedRanges)
            resolved \(windows)
            called   \(calls)
            reply: \(reply)
            """
        )
        #expect(
            windows.count == sample.expectedRanges.count,
            "expected \(sample.expectedRanges.count) window(s), got \(windows.count): \(windows)"
        )
    }

    @Test(
        "A question naming no period resolves allTime rather than a guess",
        .enabled(if: SystemLanguageModel.default.isAvailable)
    )
    func noPeriodMeansAllTime() async throws {
        // `allTime` is what makes the dependency unconditional, so this is
        // the case that keeps search_transactions from ever needing a date
        // no tool gave it. A narrower window here would silently cut a
        // question that asked about everything.
        let (windows, calls, reply) = try await ask("What did I spend at Starbucks?")
        #expect(
            windows == ["all time: 2000-01-01 to 2026-08-21"],
            "resolved \(calls) — reply: \(reply)"
        )
    }
}
