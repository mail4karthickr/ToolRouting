import SwiftUI

// MARK: - Tool Category
//
// Groups tools into capability areas. The router's instructions list
// tools under these headers so the model can reason "this is a payments
// question" before picking a specific tool — a lightweight form of
// hierarchical (two-stage) routing.

enum ToolCategory: String, CaseIterable {
    case accounts = "Accounts"
    case transactions = "Transactions"
    case payments = "Payments"
    case cards = "Cards"
    case locations = "Branches & ATMs"
    case money = "Fees, Interest & Currency"
    case creditAndRewards = "Credit & Rewards"
}

// MARK: - Tool Definition (display metadata + prompt text in one place)

struct ToolDefinition: Identifiable {
    let displayName: String
    let category: ToolCategory
    let description: String
    /// Negative examples — when NOT to use the tool. Sharpens decision
    /// boundaries and reduces false positives from shallow keyword matching.
    let notFor: String
    let argumentHint: String
    /// Example queries, used by BOTH stages: the embedding index embeds
    /// them alongside the description (description + examples beats
    /// description alone), and the LLM router lists them under the tool
    /// so selection sees the same set of matching requests that
    /// retrieval scored against.
    let exampleQueries: [String]
    let icon: String
    let color: Color
    /// One routing example injected into the LLM router's instructions.
    /// Reserved for tools that evals show misrouting — keep rare, since
    /// the instructions are attention-budget constrained.
    var promptExample: String? = nil

    var id: String { displayName }
}
