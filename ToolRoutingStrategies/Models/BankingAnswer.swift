import FoundationModels

// MARK: - Banking answer sample
//
// The value type shared by the end-to-end evaluation and the synthetic
// data generator. It lives in the app target rather than the test target
// because the command-line generator cannot import tests — the same
// reason BookTracker keeps BookTags beside its app code.
//
// @Generable so SampleGenerator can produce these; Codable so they can be
// written to and read from JSON.

/// Serves as both the expectation and the observed outcome, so one type
/// covers both sides of a sample.
///
/// On the EXPECTED side: the tools that should run and a reference
/// answer. On the SUBJECT side: the tools that did run and what the
/// assistant actually replied.
@Generable
struct BankingAnswer: Codable, Sendable {
    /// Tools the plan should select (expected) or did select (subject).
    var tools: [String] = []
    /// Whether the expected order is part of the contract.
    var orderMatters: Bool = true

    /// The answer, on BOTH sides — this is what the cascade produces, so
    /// it is what an expectation has to be about.
    ///
    /// EXPECTED: a reference answer written from the real tool output.
    /// Not the only acceptable wording — there are many ways to say the
    /// same thing — but a correct one, which makes it usable two ways:
    /// the figures in it are the figures a good answer must contain, and
    /// the judge sees it as the standard to compare against.
    ///
    /// SUBJECT: what the assistant actually replied.
    var answer: String = ""

    /// What the tools actually return, from MockBankAPIClient. Filled in
    /// on the SUBJECT side at evaluation time (see the evaluation's
    /// `subject(from:)`), never stored in a dataset and never written by
    /// a model — it is derived from the API every run, so it cannot go
    /// stale against the mock and cannot be hallucinated.
    ///
    /// Every number an answer is entitled to use lives in here.
    var toolOutput: String = ""

    /// Parallel to `tools`: the argument each one should be called with
    /// ("savings", "Starbucks", "7"). Only used to derive `toolOutput` —
    /// the router extracts its own arguments at run time.
    var arguments: [String] = []

    /// The router's own explanation — the model's `reasoning` sentence,
    /// and the policy note when one fired. Subject side only.
    ///
    /// ENCODED but not required when decoding, which is the whole point:
    /// datasets never carry it, and every eval report does. Without it a
    /// failed sample shows the wrong tools and no account of why they
    /// were chosen, and diagnosing one means reproducing it by hand in
    /// the app to read the same sentence off the trace sheet.
    var note: String = ""

    /// Tools the agent actually invoked. Recorded for diagnosis; where it
    /// differs from `tools` the agent skipped or added a step.
    var executedTools: [String] = []

    /// Decoding is deliberately tolerant: any missing key falls back to
    /// the property's default. Swift's synthesized decoder throws
    /// instead, which turns one added property into a dataset that
    /// silently loads zero samples — the eval then reports -1 for every
    /// metric rather than an error.
    init(
        tools: [String] = [],
        orderMatters: Bool = true,
        answer: String = "",
        toolOutput: String = "",
        arguments: [String] = [],
        note: String = "",
        executedTools: [String] = []
    ) {
        self.tools = tools
        self.orderMatters = orderMatters
        self.answer = answer
        self.toolOutput = toolOutput
        self.arguments = arguments
        self.note = note
        self.executedTools = executedTools
    }

    enum CodingKeys: String, CodingKey {
        case tools, orderMatters, answer, toolOutput, arguments, executedTools, note
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tools = try c.decodeIfPresent([String].self, forKey: .tools) ?? []
        orderMatters = try c.decodeIfPresent(Bool.self, forKey: .orderMatters) ?? true
        answer = try c.decodeIfPresent(String.self, forKey: .answer) ?? ""
        toolOutput = try c.decodeIfPresent(String.self, forKey: .toolOutput) ?? ""
        arguments = try c.decodeIfPresent([String].self, forKey: .arguments) ?? []
        executedTools = try c.decodeIfPresent([String].self, forKey: .executedTools) ?? []
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
    }
}
