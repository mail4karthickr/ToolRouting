import Foundation

// MARK: - What the user waited for
//
// Two numbers, both measured from the moment the user hit send:
//
//   timeToFirstToken  send → the first character on screen
//   total             send → the last one
//
// Deliberately separate from the per-stage durations in `RoutingTrace`.
// The trace explains where the time went INSIDE the pipeline; this is
// the wait the user actually felt, and it is the pair that makes
// streaming legible. Streaming does nothing for `total` — the same
// tokens take the same time to generate — and everything for
// `timeToFirstToken`, which is the whole reason to stream at all. A
// build that reports one without the other can't show that trade.
//
// Note what is inside `timeToFirstToken` here: retrieval, LLM selection,
// AND every tool round trip the agent makes before it starts writing.
// That is the honest number for a two-stage router — the user waits for
// all of it — and it is why the figure is larger than a bare chat app's.
// The generation-only slice lives on `RoutingTrace.ExecutionStage`, and
// the difference between the two is the price of routing.
//
// Both are optional: nil means it never happened. A turn that escalated
// to the cloud never generated a local token, and a failed one never
// finished.

struct ResponseTiming {
    var timeToFirstToken: Duration?
    var total: Duration?

    /// Compact enough for the answer footer: "first token 412ms · 1.9s".
    /// Nil when nothing was measured, so the caller can omit the row
    /// rather than print an empty separator.
    var label: String? {
        var parts: [String] = []
        if let timeToFirstToken {
            parts.append("first token \(timeToFirstToken.traceLabel)")
        }
        if let total {
            parts.append(total.traceLabel)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
