/*
The location-scope policy, tested where it is cheap to test.

`find_nearest_atm` and `find_nearest_branch` take coordinates, and
`get_location` yields exactly one pair — where the user is standing. So a
request about ATMs or branches somewhere the user is NOT has no tool that
serves it and no chain that reaches it, and HybridRouter escalates the
whole request rather than answering it from the wrong city.

Deciding that is `LLMRouter.namesAPlace(in:)`, which reads the wording and
nothing else. No model, no device, no MLX: this suite is pure string
handling, so the rule that used to cost a six-minute eval run to check now
costs milliseconds — and every phrasing the dataset contains is asserted
here rather than sampled through nine end-to-end runs.

The two halves matter equally. A missed place answers a question about
Chicago with San Francisco ATMs; a false one escalates "how late is the
nearest branch open?" to the cloud, which is how the first two attempts
at this rule lost working samples.
*/

import Testing
@testable import ToolRoutingStrategies

@Suite("Location scope")
struct PlaceScopeTests {
    /// The user's own location, however it is worded. These must NOT
    /// escalate — every one of them is a request the chain serves.
    @Test(
        "A request about where the user is names no place",
        arguments: [
            "Find the nearest ATM",
            "atm near me",
            "Where's the closest branch?",
            "How late is the nearest branch open?",
            "Find the nearest ATM and tell me my daily withdrawal limit",
            "Find a branch near me, its hours, and the nearest ATM",
            // A named BRANCH is not a named place: both are reachable
            // from the user's own coordinates, and escalating them was
            // what the earlier versions of this rule got wrong.
            "What time does the Main St branch close?",
            "Is the airport branch open on Saturday?",
            "How late is the Main St Branch open on Saturday?",
            // A location request carrying an unrelated proper noun. The
            // month and the merchant are why `notPlaces` exists.
            "Find the nearest ATM and tell me what I spent at Amazon in August"
        ]
    )
    func staysOnDevice(_ query: String) {
        #expect(!LLMRouter.namesAPlace(in: query), "\"\(query)\" should not read as a named place")
    }

    /// Somewhere the user is not. Every one of these must escalate — the
    /// chain cannot reach any of them, and answering from the device's
    /// own coordinates would be answering about the wrong city.
    @Test(
        "A request naming somewhere else is caught",
        arguments: [
            "Any ATMs in Chicago?",
            "Find ATMs in Chicago",
            "Is there a branch in Chicago?",
            "Find a branch downtown and tell me its hours",
            "cash machine near 94103",
            "ATMs around Union Square",
            // The one that has cost the most: a named place buried in a
            // request whose other two parts are perfectly serviceable.
            // All-or-nothing — the whole request goes to the cloud.
            "What ATMs are near Chicago, what's my withdrawal limit, and my checking balance?"
        ]
    )
    func escalates(_ query: String) {
        #expect(LLMRouter.namesAPlace(in: query), "\"\(query)\" names a place the tools cannot reach")
    }
}
