import SwiftUI

@main
struct ToolRoutingStrategiesApp: App {
    @Environment(\.scenePhase) private var scenePhase

    /// Writes the launch banner. The file itself opens on the first line
    /// logged anywhere, so this is a delimiter between runs rather than a
    /// bootstrap step — but it is also what puts the log's path in the
    /// console, which is how you find it on a simulator.
    init() {
        AppLog.start()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .onChange(of: scenePhase) { _, phase in
            Log.app.debug("scene phase → \(phase)")
            // Every line is written with an fsync already; this only
            // covers a line still queued on a logger's serial queue when
            // the app leaves the foreground.
            if phase != .active { AppLog.flush() }
        }
    }
}
