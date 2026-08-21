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
    /// Tools that work on figures other tools already returned, rather
    /// than fetching anything of their own — calculator today, a date
    /// tool next. Not a "capability area" about the user's money the way
    /// the others are, so it groups separately instead of forcing a fit.
    case utility = "Utility"
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

    /// What has to be in the plan already for this tool to be able to run.
    ///
    /// A FACT ABOUT THE TOOL, KEPT AS DATA. Every one of these used to be
    /// a paragraph in `RouterPrompt.system` telling the model to remember
    /// a dependency — get_location before find_nearest_atm,
    /// find_nearest_branch before branch_hours — and each new tool added
    /// another. Prose does not compose: the paragraph added for
    /// resolve_date_range and the one added for calculator between them
    /// produced a plan of `[resolve_date_range, calculator]` with nothing
    /// to fetch the figures either of them needed.
    ///
    /// Held here, one dependency is declared once and enforced in Swift by
    /// `ToolCatalog.closure(over:)`, which cannot forget it.
    ///
    /// The router still CHOOSES every tool, this one included — the
    /// requirement does not hide anything from retrieval or selection. It
    /// only repairs a plan that came back impossible to run.
    var requires: Requirement = .none

    var id: String { displayName }
}

extension ToolDefinition {
    /// What a tool needs in the plan before it can run.
    enum Requirement: Equatable {
        /// Runs on its own.
        case none
        /// Needs one named tool's output — get_location before
        /// find_nearest_atm, find_nearest_branch before branch_hours.
        case tool(String)
        /// Needs SOMETHING to have been fetched first, without caring
        /// what. calculator computes from figures another tool returned,
        /// so any routed tool satisfies it and an empty plan does not.
        case anyRoutedTool
    }
}
