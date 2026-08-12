import Foundation

// MARK: - Progress from a run in flight
//
// The pipeline is slow enough that a spinner is a lie of omission: a
// hybrid turn spends time in retrieval, then in LLM selection, then in
// tool calls, and only then starts writing. Reporting each of those, and
// then the answer as it is written, turns one long opaque wait into a
// sequence of short explained ones.
//
// Shared by the router and the agent rather than each defining its own
// progress type. There is one consumer (the chat), it wants one
// vocabulary, and a second enum whose only job is to be mapped onto this
// one would be ceremony.
//
// Callbacks carrying these are non-escaping and called on whatever actor
// the router runs on — the main actor for everything in this app — so the
// UI can mutate its state directly in the handler without hopping.

enum RoutingUpdate {
    /// Stage 1 started: embedding search over the catalog.
    case retrieving
    /// Stage 2 started: the LLM is choosing from the shortlist.
    case selecting
    /// Stage 3 started: the selected tools are bound and the agent is
    /// running them. Nothing is written until they return, so this is
    /// usually the longest gap before the first token.
    case answering
    /// The answer SO FAR — cumulative, not a delta. Each one supersedes
    /// the last, so a consumer assigns rather than appends.
    case answerPartial(String)
}
