import Foundation

// MARK: - Where the device is
//
// What `get_location` returns, and the reason it now returns a type
// rather than a string.
//
// `find_nearest_atm` and `find_nearest_branch` take latitude and
// longitude. Nothing else in the catalog produces coordinates, so the
// model cannot reach either tool without calling `get_location` first —
// the dependency is a fact about the argument types instead of a rule in
// the selection prompt that the model is free to skip. It skipped it
// (eval 2026-08-12, sample 7: "Find the nearest ATM and tell me my daily
// withdrawal limit" selected find_atm and card_limits, no get_location).
//
// The flip side is that a request naming a place — "a branch in Chicago"
// — now has no tool that can serve it and escalates. That is deliberate:
// the mock ignored the place string anyway and answered with the same
// three local branches, so the old path was returning wrong results
// rather than serving the request. Wiring a real geocoder behind
// get_location is what would make named places serviceable again.

struct DeviceLocation: Equatable, Sendable {
    let latitude: Double
    let longitude: Double
}
