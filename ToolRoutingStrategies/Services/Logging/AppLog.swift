import Foundation
import Puppy

// MARK: - File logging
//
// A durable, on-device record of what every stage did with a request.
// The pipeline's failures are not crashes — they are a shortlist that
// missed, a selection that escalated, a tool the agent never called —
// and none of those leave a trace once the app quits. Xcode's console
// only helps while the debugger is attached, which is exactly not the
// case when something goes wrong on a device in someone's hand.
//
// So every line goes to a FILE as well as the console, written with
// `synchronize()` on each append (Puppy's default `FlushMode.always`),
// so a log that ends mid-request still holds everything up to the moment
// it stopped.
//
// WHERE IT LIVES
//   <Documents>/Logs/routing.log        the current file
//   <Documents>/Logs/routing.log.1…5    rotated archives, 5 MB each
//
// Documents rather than Caches or a temp directory, because the point is
// to get it OFF the device: the app target sets UIFileSharingEnabled and
// LSSupportsOpeningDocumentsInPlace, so the folder shows up in Files ▸ On
// My iPhone ▸ ToolRoutingStrategies, and the log sheet in the app has a
// share button on the same file.
//
// WHY PUPPY (github.com/sushichop/Puppy, 0.9.x). It is the smallest
// package that does the one thing needed: rotating file output, pure
// Swift, `Sendable` throughout, no ObjC runtime, per-logger serial queues
// so the format work happens off the caller's thread. `os.Logger` writes
// to the unified log, which cannot be handed to someone as a file;
// CocoaLumberjack brings an ObjC dependency for the same feature set.

nonisolated enum AppLog {

    // MARK: File locations

    /// The folder every log file lives in.
    static let directoryURL = URL.documentsDirectory.appending(
        path: "Logs",
        directoryHint: .isDirectory
    )

    /// The file being written right now. Rotated archives sit beside it
    /// with a `.1`…`.5` extension, newest first.
    static let fileURL = directoryURL.appending(path: "routing.log", directoryHint: .notDirectory)

    /// Current file plus every archive, newest first — what a "send me
    /// the logs" request should actually collect.
    static var allFileURLs: [URL] {
        let archives = (try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        )) ?? []
        return [fileURL] + archives
            .filter { $0 != fileURL && $0.deletingPathExtension().lastPathComponent == "routing" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: Sinks

    /// Console AND file, both at `.trace`, both in the same format.
    ///
    /// A `let` on an enum is initialized lazily and exactly once, so the
    /// first log call anywhere in the app opens the file — no bootstrap
    /// step to forget, and `start()` below is a banner rather than a
    /// prerequisite.
    ///
    /// File output failing (a full disk, a protected-data class that
    /// hasn't unlocked yet) degrades to console-only rather than
    /// trapping: losing the log is bad, taking the app down with it is
    /// worse.
    fileprivate static let puppy: Puppy = {
        var puppy = Puppy()
        puppy.add(ConsoleLogger(
            "com.karthick.ToolRoutingStrategies.console",
            logLevel: .trace,
            logFormat: LogLineFormatter()
        ))

        do {
            let file = try FileRotationLogger(
                "com.karthick.ToolRoutingStrategies.file",
                logLevel: .trace,
                logFormat: LogLineFormatter(),
                fileURL: fileURL,
                filePermission: "600",
                rotationConfig: RotationConfig(
                    suffixExtension: .numbering,
                    maxFileSize: 5 * 1024 * 1024,
                    maxArchivedFilesCount: 5
                )
            )
            puppy.add(file)
        } catch {
            print("[AppLog] file logging unavailable, console only: \(error)")
        }
        return puppy
    }()

    // MARK: Lifecycle

    /// Opens the file and writes the launch banner.
    ///
    /// Each launch is delimited, because the first question anyone asks
    /// of a log is "which run is this". The path is printed to the plain
    /// console too — it is the fastest way to `cat` the file out of a
    /// simulator container.
    static func start() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"

        Log.app.info("──────── launch ── v\(version) (\(build)) ── \(ProcessInfo.processInfo.operatingSystemVersionString) ────")
        Log.app.info("log file: \(fileURL.path())")
        print("[AppLog] writing to \(fileURL.path())")
    }

    /// Blocks until every sink has drained. For the moment before the app
    /// is suspended, where an in-flight line would otherwise be lost.
    @discardableResult
    static func flush(timeout: Double = 1.0) -> Bool {
        puppy.flush(timeout) == .success
    }

    // MARK: Reading and clearing

    /// The tail of the current file, for the in-app viewer.
    ///
    /// Reads the whole file and drops the front: these are ≤5 MB and the
    /// viewer is a debugging affordance, so simple beats incremental.
    static func tail(maxCharacters: Int = 200_000) -> String {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return "No log file yet at \(fileURL.path())"
        }
        guard text.count > maxCharacters else { return text }
        return "… (truncated to the last \(maxCharacters) characters)\n"
            + String(text.suffix(maxCharacters))
    }

    /// Empties the current file and deletes the archives, so the next
    /// reproduction starts from nothing.
    ///
    /// Truncates rather than removing the file: `FileRotationLogger`
    /// opened it at init and appends by path on every write, so an empty
    /// file keeps working while a deleted one would need the logger
    /// rebuilt.
    static func clear() {
        try? Data().write(to: fileURL, options: .atomic)
        for url in allFileURLs where url != fileURL {
            try? FileManager.default.removeItem(at: url)
        }
        Log.app.info("──────── log cleared ────────")
    }
}

// MARK: - Line format
//
//   2026-08-12 10:23:45.187 I [stage2] #7 selected [account_balance] in 1.62s · LLMRouter.swift:340
//
// Fixed-width level and a bracketed category so a 5 MB file stays
// greppable: `grep '\[stage1\]'` for retrieval, `grep '#7'` for one
// request end to end.

private struct LogLineFormatter: LogFormattable {
    /// `Date.ISO8601FormatStyle` is a Sendable value type, unlike
    /// `DateFormatter` — and this one instance is shared by the console
    /// and file loggers, which format on two different queues.
    private static let time = Date.ISO8601FormatStyle(timeZone: .current)
        .year().month().day()
        .dateSeparator(.dash)
        .dateTimeSeparator(.space)
        .time(includingFractionalSeconds: true)
        .timeSeparator(.colon)

    func formatMessage(
        _ level: LogLevel,
        message: String,
        tag: String,
        function: String,
        file: String,
        line: UInt,
        swiftLogInfo: [String: String],
        label: String,
        date: Date,
        threadID: UInt64
    ) -> String {
        "\(date.formatted(Self.time)) \(Self.symbol(level)) [\(tag)] \(message) · \(fileName(file)):\(line)"
    }

    /// One character, so the level never shifts the columns after it.
    private static func symbol(_ level: LogLevel) -> String {
        switch level {
        case .trace, .verbose: "T"
        case .debug: "D"
        case .info: "I"
        case .notice: "N"
        case .warning: "W"
        case .error: "E"
        case .critical: "C"
        }
    }
}

// MARK: - Request correlation
//
// Every line a single question produces carries the same `#n`, so one
// request can be pulled out of a file holding a dozen. The stages don't
// pass an ID around to get this: `HybridRouter` wraps its run in
// `LogContext.$requestID`, and a task-local is inherited by everything
// that runs inside it — Stage 2's selection, Stage 3's streaming loop,
// each tool's `call` — without a single signature changing.

nonisolated enum LogContext {
    @TaskLocal static var requestID: Int?

    /// `#n ` for the request in flight, empty outside one (prewarm, app
    /// startup, index builds).
    static var prefix: String {
        requestID.map { "#\($0) " } ?? ""
    }
}

// MARK: - Categories
//
// One value per stage, and the names are the greps: `stage1` retrieval,
// `stage2` selection, `stage3` execution, `hybrid` the policy decisions
// that sit between them.

nonisolated struct Log: Sendable {
    let category: String

    private init(_ category: String) {
        self.category = category
    }

    /// Launch, lifecycle, log-file management.
    static let app = Log("app")
    /// The chat screen and the view model: what was asked, what was shown.
    static let ui = Log("ui")
    /// The cascade itself — every policy decision between the stages.
    static let hybrid = Log("hybrid")
    /// Stage 1, MiniLM retrieval.
    static let stage1 = Log("stage1")
    /// Stage 2, LLM selection.
    static let stage2 = Log("stage2")
    /// Stage 3, the tool-executing agent.
    static let stage3 = Log("stage3")
    /// Individual tool invocations, with their arguments and results.
    static let tools = Log("tools")
    /// The persisted embedding index: cache hits, rebuilds.
    static let index = Log("index")
    /// The embedding model: weight loading, warmup, embed calls.
    static let embedder = Log("embedder")

    // MARK: Levels
    //
    // `@autoclosure` so an expensive interpolation — a transcript dump, a
    // full ranking — is only built if something is going to write it.

    func trace(_ message: @autoclosure () -> String, function: String = #function, file: String = #fileID, line: UInt = #line) {
        write(.trace, message(), function, file, line)
    }

    func debug(_ message: @autoclosure () -> String, function: String = #function, file: String = #fileID, line: UInt = #line) {
        write(.debug, message(), function, file, line)
    }

    func info(_ message: @autoclosure () -> String, function: String = #function, file: String = #fileID, line: UInt = #line) {
        write(.info, message(), function, file, line)
    }

    func warning(_ message: @autoclosure () -> String, function: String = #function, file: String = #fileID, line: UInt = #line) {
        write(.warning, message(), function, file, line)
    }

    func error(_ message: @autoclosure () -> String, function: String = #function, file: String = #fileID, line: UInt = #line) {
        write(.error, message(), function, file, line)
    }

    private func write(_ level: LogLevel, _ message: String, _ function: String, _ file: String, _ line: UInt) {
        AppLog.puppy.logMessage(
            level,
            // The request ID is read HERE, on the calling task, because
            // the formatter runs later on the logger's own queue where the
            // task-local is long gone.
            message: LogContext.prefix + message,
            tag: category,
            function: function,
            file: file,
            line: line
        )
    }
}

// MARK: - Helpers for log payloads

extension String {
    /// Keeps a tool result or a model answer readable in the file: one
    /// line, and bounded.
    ///
    /// Multi-line payloads are the norm here — a transaction list, a
    /// statement — and a log line that spans twelve rows breaks every
    /// `grep` around it.
    func loggable(_ limit: Int = 600) -> String {
        let flattened = split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: " ⏎ ")
        return flattened.count > limit
            ? String(flattened.prefix(limit)) + "… (+\(flattened.count - limit) chars)"
            : flattened
    }
}

extension Duration {
    /// `1.62s` — the unit every timing in this log is written in.
    var logged: String {
        String(format: "%.3fs", Double(components.seconds) + Double(components.attoseconds) * 1e-18)
    }
}
