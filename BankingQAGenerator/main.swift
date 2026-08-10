/*
Command-line synthetic data generator for the banking assistant's evals.

Modelled on BookTracker's BookSampleGenerator, with one addition that the
book sample does not need: a GROUND-TRUTH pass.

Tag generation is self-contained — a review and its tags are both text,
so a model can invent a valid pair. A banking Q&A cannot work that way. A
model can invent "what's my savings balance?" but it cannot know the
answer is $8,120.55, and if it guesses, the dataset ends up agreeing with
a hallucination. So generation is split in two:

    phase 1  the MODEL invents the question, the tools that answer it,
             and the argument each tool takes
    phase 2  the CODE calls MockBankAPIClient for those tools and gets
             back what they really return (MockGroundTruth)
    phase 3  the MODEL writes the reference ANSWER, given the question
             and the real tool output from phase 2

Phase 3 is the point. The eval grades an ANSWER, so the expectation has
to be an answer — but a model asked to invent one cold would invent the
balance with it. Given the real output, all it does is phrase figures it
was handed. Every number in the dataset therefore came from the same API
the app calls at run time.

USAGE
    xcodebuild -scheme BankingQAGenerator build
    <path-to-built-product>/BankingQAGenerator

    Then add the emitted synthetic_banking_qa.json to the
    ToolRoutingStrategiesTests target as a resource.

    Needs macOS 27: Evaluations.framework, which SampleGenerator and
    ModelSample come from, does not exist for macOS 26.

GENERATING THE DATASET SOMEWHERE ELSE
    Nothing requires this tool. The eval reads plain JSON, so any model
    or script can produce it as long as the shape matches — one object
    per sample, ModelSample's own encoding:

        {
          "input":  { "instructions": "null", "prompt": "<the question>" },
          "output": { "value": {
              "tools":         ["account_balance"],
              "arguments":     ["savings"],
              "orderMatters":  true,
              "answer":        "Your savings balance is $8,120.55.",
              "toolOutput":    "",
              "executedTools": []
          }}
        }

    All six keys must be present — Swift's synthesized decoder does not
    fall back to a property's default when a key is missing.

    The one rule that matters however it is generated: every figure in
    `answer` must be one the tools actually return for `tools` +
    `arguments`. The eval re-derives tool output from MockBankAPIClient
    at run time and fails any answer containing a number the bank never
    said, so a dataset with invented figures fails loudly rather than
    quietly passing. `toolOutput` is left empty for that reason — it is
    computed, never stored.

Generation runs on Private Cloud Compute — a larger model gives more
varied phrasing, and this is an offline authoring step where latency does
not matter. The system under evaluation stays entirely on-device.
*/

import Evaluations
import Foundation
import FoundationModels

// MARK: - Configuration

let targetCount = 60

let outputURL = URL(filePath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appending(path: "ToolRoutingStrategiesTests/synthetic_banking_qa.json")

// MARK: - Seeds
//
// A handful of curated questions showing the SHAPE of a sample: a
// question, the tools that answer it, the argument each takes, and a
// reference answer. Their answers are hand-written from the mock's real
// values; generated samples get theirs from phase 3.

let seeds: [ModelSample<BankingAnswer>] = [
    ModelSample(
        prompt: "What's my savings balance?",
        expected: BankingAnswer(
            tools: ["account_balance"],
            answer: "Your savings balance is $8,120.55.",
            arguments: ["savings"]
        )
    ),
    ModelSample(
        prompt: "What did I spend at Starbucks?",
        expected: BankingAnswer(
            tools: ["search_transactions"],
            answer: "You spent $6.45 at Starbucks.",
            arguments: ["Starbucks"]
        )
    ),
    ModelSample(
        prompt: "What's my daily ATM withdrawal limit?",
        expected: BankingAnswer(
            tools: ["card_limits"],
            answer: "Your daily ATM withdrawal limit is $1,000.",
            arguments: ["debit"]
        )
    ),
    ModelSample(
        prompt: "Find the nearest ATM",
        expected: BankingAnswer(
            tools: ["get_location", "find_atm"],
            answer: "The closest one is the Market Square ATM, 0.1 miles away and open 24 hours.",
            arguments: ["", "current location"]
        )
    ),
    ModelSample(
        prompt: "What's my credit score and do I have any pending payments?",
        expected: BankingAnswer(
            tools: ["credit_score", "pending_payments"],
            orderMatters: false,
            answer: "Your credit score is 742, and you have two payments processing: Netflix for $15.49 and PG&E for $96.40.",
            arguments: ["", "all"]
        )
    ),
    ModelSample(
        prompt: "Freeze my debit card",
        expected: BankingAnswer(tools: ["none"])
    )
]

let instructions = """
    You are a synthetic data generator for a banking assistant's evaluation
    suite. You produce realistic customer questions together with the tools
    that should answer them.

    The assistant has exactly these read-only tools:
    \(ToolCatalog.all.map { "- \($0.displayName): \($0.description) Argument: \($0.argumentHint)" }.joined(separator: "\n"))

    Plus one non-tool outcome, written as the single tool "none": the request
    needs an action that changes something (transfers, payments, freezing
    cards, raising limits, opening disputes), or needs something no tool above
    covers.

    Rules:
    - `prompt` is the customer's question, in their own words.
    - Vary phrasing hard: formal and terse, typo'd and lowercase, polite and
      blunt, questions and commands. Real people are inconsistent.
    - `tools` lists display names from the list above, in the order they must
      run, or exactly ["none"].
    - `arguments` runs parallel to `tools`: what each one is called with
      ("savings", "Starbucks", "7", "Main St"). Use "" where a tool takes no
      argument. This is how the real figures get looked up, so it must match
      what the question is actually asking about.
    - When a tool needs another's result, put the source first — "nearest ATM"
      is ["get_location", "find_atm"].
    - Set `orderMatters` false when the tools do not depend on each other.
    - Leave `answer` and `toolOutput` EMPTY. You do not know the customer's
      figures. A reference answer is written afterwards from the bank's own
      API, and a guess here would corrupt the dataset.
    - About a fifth of the samples should be "none".
    - Do not repeat a question already in the dataset.
    """

// MARK: - Validation
//
// Rejects anything that would quietly corrupt the dataset. Throwing a
// sample away costs one generation; a bad expectation costs a debugging
// session on a run whose numbers were wrong.

func isValid(_ sample: ModelSample<BankingAnswer>) -> Bool {
    guard let expected = sample.expected else { return false }
    guard sample.promptDescription.count >= 8 else { return false }
    guard !expected.tools.isEmpty, expected.tools.count <= 4 else { return false }
    // Ground truth is derived, never generated.
    guard expected.answer.isEmpty, expected.toolOutput.isEmpty else { return false }
    if expected.tools == ["none"] { return true }
    return expected.tools.allSatisfy { ToolCatalog.byName[$0] != nil }
}

// MARK: - Generate

print("Seeding with \(seeds.count) samples. Target: \(targetCount).")

var generated: [ModelSample<BankingAnswer>] = []

let generator = SampleGenerator<ModelSample<BankingAnswer>>(
    Prompt("""
        Generate diverse banking questions and the tools that answer them. \
        Cover every tool in the list, every phrasing register, and the \
        "none" case. Do not repeat questions already in the dataset.
        """),
    samples: seeds,
    targetCount: targetCount,
    sessionProvider: {
        LanguageModelSession(
            model: PrivateCloudComputeLanguageModel(),
            instructions: instructions
        )
    },
    validator: isValid
)

for try await sample in generator.run() {
    generated.append(sample)
}

let rejected = await generator.invalidSamples
print("Generated \(generated.count) samples, rejected \(rejected.count).")

// MARK: - Ground truth, then reference answers
//
// Phase 2 and 3. Each sample's tools are run against MockBankAPIClient,
// and the real output is handed back to the model with the question so
// it can write the answer a perfect assistant would have given.

print("Deriving ground truth and writing reference answers…")

let writer = LanguageModelSession(
    model: PrivateCloudComputeLanguageModel(),
    instructions: """
        You write the reference answer for a banking assistant's evaluation set.

        You are given a customer's question and the exact output the bank's
        tools returned for it. Write the reply a perfect assistant would give.

        Rules:
        - One or two short sentences, plain language, no greeting or sign-off.
        - Use ONLY figures that appear in the tool output, copied exactly,
          including punctuation: $8,120.55 stays $8,120.55.
        - Never round, never total, never estimate, never add a figure that is
          not in the tool output.
        - Answer every part of the question and nothing more.
        - Never mention tools, lookups, or the app.
        """
)

var finished: [ModelSample<BankingAnswer>] = []
var skipped = 0

for sample in seeds + generated {
    guard var expected = sample.expected else { continue }

    // "none" samples have no tool output by definition — the request
    // left the device. Their expectation is the empty answer, and they
    // still grade routing.
    if expected.tools == ["none"] {
        finished.append(ModelSample(prompt: sample.promptDescription, expected: expected))
        continue
    }

    let output = await MockGroundTruth.toolOutput(
        tools: expected.tools,
        arguments: expected.arguments
    )

    guard !output.isEmpty else {
        // No derivable output means no checkable expectation. Dropping
        // the sample is better than keeping one nothing can grade.
        skipped += 1
        continue
    }

    let reference = try await writer.respond(to: """
        Question: \(sample.promptDescription)

        Tool output:
        \(output)
        """).content

    // Last line of defence: the writer had the real figures in front of
    // it, so anything outside them is a fabrication, and a fabricated
    // reference answer would teach the eval to accept fabrication.
    let allowed = MockGroundTruth.figures(in: output)
    let used = MockGroundTruth.figures(in: reference)
    guard used.subtracting(allowed).isEmpty else {
        skipped += 1
        continue
    }

    expected.answer = reference
    finished.append(ModelSample(prompt: sample.promptDescription, expected: expected))
}

// MARK: - Write
//
// `toolOutput` is deliberately NOT stored: the evaluation derives it
// again from the mock on every run, so the dataset can never disagree
// with the API it is supposed to describe.

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
try encoder.encode(finished).write(to: outputURL)

let escalations = finished.filter { $0.expected?.tools == ["none"] }.count

print("""

    Wrote \(finished.count) samples to \(outputURL.path())
      \(finished.count - escalations) with a reference answer
      \(escalations) escalations ("none", routing only)
      \(skipped) dropped: no tool output, or the writer used a figure the
        tools never returned

    Next: add that file to the ToolRoutingStrategiesTests target as a
    resource, then enable the synthetic evaluation in SyntheticBankingQA.swift.

    """)
