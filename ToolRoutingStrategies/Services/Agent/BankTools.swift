import Foundation
import FoundationModels

// MARK: - Executable tools (Stage 3)
//
// One FoundationModels `Tool` per catalog entry. These are what the
// AGENT binds to its session — the model calls them itself and sees
// their output, which is a different thing from the routing stages:
//
//   Stage 1/2  decide WHICH tools a request needs (ToolName, a plan)
//   Stage 3    actually RUN them and answer (these types)
//
// `name` and `description` are read straight from ToolCatalog so a tool
// can never describe itself one way to the router and another way to the
// agent. Arguments are @Generable, so the framework derives each tool's
// parameter schema and the model fills it in — the same guided-decoding
// guarantee the router gets.
//
// Every tool here is a read-only GET against BankAPIClient. That is the
// invariant the whole `none`/cloud split rests on: if a request needs
// anything that writes, no tool in this file can serve it, and routing
// sends it off-device instead.

// MARK: - Shared plumbing

/// Looks up a tool's catalog text, so `name`/`description` cannot drift
/// from what the router was shown. Traps on an unknown name: that means
/// the catalog and this file disagree, which is a programmer error, not
/// something to paper over at runtime.
private func catalogEntry(_ displayName: String) -> ToolDefinition {
    guard let definition = ToolCatalog.byName[displayName] else {
        preconditionFailure("No ToolCatalog entry named '\(displayName)'")
    }
    return definition
}

/// Arguments shared by the account-scoped tools.
@Generable
struct AccountArgument {
    @Guide(description: "Which account: checking, savings, credit card, or all")
    var account: String
}

/// Arguments shared by the card-scoped tools.
@Generable
struct CardArgument {
    @Guide(description: "Which card: debit or credit")
    var card: String
}

/// Arguments for tools that take no input.
@Generable
struct NoArguments {}

// MARK: - Transactions

struct ListTransactionsTool: Tool {
    let client: any BankAPIClient
    var name: String { catalogEntry("list_transactions").displayName }
    var description: String { catalogEntry("list_transactions").description }

    @Generable
    struct Arguments {
        @Guide(description: "How many past days of transactions to show, e.g. 7")
        var days: Int
    }

    func call(arguments: Arguments) async throws -> String {
        let transactions = try await client.listTransactions(days: arguments.days)
        guard !transactions.isEmpty else {
            return "No transactions in the last \(arguments.days) days."
        }
        return transactions.map(Self.line(for:)).joined(separator: "\n")
    }

    static func line(for transaction: Transaction) -> String {
        let amount = transaction.amount.formatted(.currency(code: "USD"))
        let date = transaction.date.formatted(.dateTime.month(.abbreviated).day())
        return "\(date) · \(transaction.merchant) · \(transaction.account) · \(amount)"
    }
}

struct SearchTransactionsTool: Tool {
    let client: any BankAPIClient
    var name: String { catalogEntry("search_transactions").displayName }
    var description: String { catalogEntry("search_transactions").description }

    @Generable
    struct Arguments {
        @Guide(description: "The merchant name, e.g. Starbucks")
        var merchant: String
    }

    func call(arguments: Arguments) async throws -> String {
        let transactions = try await client.searchTransactions(merchant: arguments.merchant)
        guard !transactions.isEmpty else {
            return "No transactions found for \(arguments.merchant)."
        }
        // The total is included because "what did I spend at X" is a sum
        // question; leaving the model to add up a list is a needless
        // arithmetic risk on a small model.
        let total = transactions.reduce(Decimal.zero) { $0 + $1.amount }
        return transactions.map(ListTransactionsTool.line(for:)).joined(separator: "\n")
            + "\nTotal: \(total.formatted(.currency(code: "USD")))"
    }
}

struct DisputeStatusTool: Tool {
    let client: any BankAPIClient
    var name: String { catalogEntry("dispute_status").displayName }
    var description: String { catalogEntry("dispute_status").description }

    @Generable
    struct Arguments {
        @Guide(description: "The merchant of the disputed charge, or 'all'")
        var merchant: String
    }

    func call(arguments: Arguments) async throws -> String {
        try await client.disputeStatus(merchant: arguments.merchant)
    }
}

// MARK: - Accounts

struct AccountBalanceTool: Tool {
    let client: any BankAPIClient
    var name: String { catalogEntry("account_balance").displayName }
    var description: String { catalogEntry("account_balance").description }
    typealias Arguments = AccountArgument

    func call(arguments: AccountArgument) async throws -> String {
        try await client.accountBalance(accountType: arguments.account)
    }
}

struct RoutingNumberTool: Tool {
    let client: any BankAPIClient
    var name: String { catalogEntry("routing_number").displayName }
    var description: String { catalogEntry("routing_number").description }
    typealias Arguments = AccountArgument

    func call(arguments: AccountArgument) async throws -> String {
        try await client.routingNumber(accountType: arguments.account)
    }
}

struct AccountNumberTool: Tool {
    let client: any BankAPIClient
    var name: String { catalogEntry("account_number").displayName }
    var description: String { catalogEntry("account_number").description }
    typealias Arguments = AccountArgument

    func call(arguments: AccountArgument) async throws -> String {
        try await client.accountNumber(accountType: arguments.account)
    }
}

struct BankStatementTool: Tool {
    let client: any BankAPIClient
    var name: String { catalogEntry("bank_statement").displayName }
    var description: String { catalogEntry("bank_statement").description }

    @Generable
    struct Arguments {
        @Guide(description: "The period, e.g. 'June' or 'last month'")
        var month: String
        @Guide(description: "Which account: checking, savings, or credit card")
        var account: String
    }

    func call(arguments: Arguments) async throws -> String {
        try await client.bankStatement(month: arguments.month, accountType: arguments.account)
    }
}

struct InterestEarnedTool: Tool {
    let client: any BankAPIClient
    var name: String { catalogEntry("interest_earned").displayName }
    var description: String { catalogEntry("interest_earned").description }
    typealias Arguments = AccountArgument

    func call(arguments: AccountArgument) async throws -> String {
        try await client.interestEarned(accountType: arguments.account)
    }
}

struct FeesAndChargesTool: Tool {
    let client: any BankAPIClient
    var name: String { catalogEntry("fees_and_charges").displayName }
    var description: String { catalogEntry("fees_and_charges").description }
    typealias Arguments = AccountArgument

    func call(arguments: AccountArgument) async throws -> String {
        let fees = try await client.feesAndCharges(accountType: arguments.account)
        return fees.isEmpty ? "No fees on this account." : fees.joined(separator: "\n")
    }
}

// MARK: - Cards

struct CardNumberTool: Tool {
    let client: any BankAPIClient
    var name: String { catalogEntry("card_number").displayName }
    var description: String { catalogEntry("card_number").description }
    typealias Arguments = CardArgument

    func call(arguments: CardArgument) async throws -> String {
        try await client.cardNumber(cardType: arguments.card)
    }
}

struct CardLimitsTool: Tool {
    let client: any BankAPIClient
    var name: String { catalogEntry("card_limits").displayName }
    var description: String { catalogEntry("card_limits").description }
    typealias Arguments = CardArgument

    func call(arguments: CardArgument) async throws -> String {
        try await client.cardLimits(cardType: arguments.card)
    }
}

// MARK: - Payments

struct PendingPaymentsTool: Tool {
    let client: any BankAPIClient
    var name: String { catalogEntry("pending_payments").displayName }
    var description: String { catalogEntry("pending_payments").description }
    typealias Arguments = AccountArgument

    func call(arguments: AccountArgument) async throws -> String {
        let payments = try await client.pendingPayments(accountType: arguments.account)
        return payments.isEmpty ? "Nothing pending." : payments.joined(separator: "\n")
    }
}

struct ScheduledPaymentsTool: Tool {
    let client: any BankAPIClient
    var name: String { catalogEntry("scheduled_payments").displayName }
    var description: String { catalogEntry("scheduled_payments").description }
    typealias Arguments = AccountArgument

    func call(arguments: AccountArgument) async throws -> String {
        let payments = try await client.scheduledPayments(accountType: arguments.account)
        return payments.isEmpty ? "Nothing scheduled." : payments.joined(separator: "\n")
    }
}

// MARK: - Locations

struct GetLocationTool: Tool {
    let client: any BankAPIClient
    var name: String { catalogEntry("get_location").displayName }
    var description: String { catalogEntry("get_location").description }
    typealias Arguments = NoArguments

    func call(arguments: NoArguments) async throws -> String {
        try await client.currentLocation()
    }
}

struct FindBranchTool: Tool {
    let client: any BankAPIClient
    var name: String { catalogEntry("find_branch").displayName }
    var description: String { catalogEntry("find_branch").description }

    @Generable
    struct Arguments {
        @Guide(description: "The place: a city, zip code, or address")
        var location: String
    }

    func call(arguments: Arguments) async throws -> String {
        let branches = try await client.findBranches(near: arguments.location)
        return branches.isEmpty ? "No branches near \(arguments.location)." : branches.joined(separator: "\n")
    }
}

struct FindATMTool: Tool {
    let client: any BankAPIClient
    var name: String { catalogEntry("find_atm").displayName }
    var description: String { catalogEntry("find_atm").description }

    @Generable
    struct Arguments {
        @Guide(description: "The place: a city, zip code, or address")
        var location: String
    }

    func call(arguments: Arguments) async throws -> String {
        let atms = try await client.findATMs(near: arguments.location)
        return atms.isEmpty ? "No ATMs near \(arguments.location)." : atms.joined(separator: "\n")
    }
}

struct BranchHoursTool: Tool {
    let client: any BankAPIClient
    var name: String { catalogEntry("branch_hours").displayName }
    var description: String { catalogEntry("branch_hours").description }

    @Generable
    struct Arguments {
        @Guide(description: "The branch name, e.g. 'Main St'")
        var branch: String
    }

    func call(arguments: Arguments) async throws -> String {
        try await client.branchHours(branch: arguments.branch)
    }
}

// MARK: - Money & rewards

struct ConvertCurrencyTool: Tool {
    let client: any BankAPIClient
    var name: String { catalogEntry("convert_currency").displayName }
    var description: String { catalogEntry("convert_currency").description }

    @Generable
    struct Arguments {
        @Guide(description: "A concrete amount, e.g. '$500'")
        var amount: String
        @Guide(description: "The target currency code, e.g. 'EUR'")
        var to: String
    }

    func call(arguments: Arguments) async throws -> String {
        try await client.convertCurrency(amount: arguments.amount, to: arguments.to)
    }
}

struct CreditScoreTool: Tool {
    let client: any BankAPIClient
    var name: String { catalogEntry("credit_score").displayName }
    var description: String { catalogEntry("credit_score").description }
    typealias Arguments = NoArguments

    func call(arguments: NoArguments) async throws -> String {
        "Credit score: \(try await client.creditScore())"
    }
}

struct RewardPointsTool: Tool {
    let client: any BankAPIClient
    var name: String { catalogEntry("reward_points").displayName }
    var description: String { catalogEntry("reward_points").description }
    typealias Arguments = NoArguments

    func call(arguments: NoArguments) async throws -> String {
        let points = try await client.rewardPoints()
        return "\(points.formatted()) reward points"
    }
}

// MARK: - Registry

enum BankToolRegistry {
    /// Builds the executable tool for a routed call, or nil when the plan
    /// named something that has no implementation. Keyed by the same
    /// `displayName` the router selects, which is what lets a plan of
    /// ToolName values become a set of live tools.
    ///
    /// `.none` deliberately returns nil: it is an escalation decision,
    /// not something the agent can run.
    static func tool(named displayName: String, client: any BankAPIClient) -> (any Tool)? {
        switch displayName {
        case "list_transactions": ListTransactionsTool(client: client)
        case "search_transactions": SearchTransactionsTool(client: client)
        case "routing_number": RoutingNumberTool(client: client)
        case "account_number": AccountNumberTool(client: client)
        case "card_number": CardNumberTool(client: client)
        case "bank_statement": BankStatementTool(client: client)
        case "credit_score": CreditScoreTool(client: client)
        case "get_location": GetLocationTool(client: client)
        case "find_branch": FindBranchTool(client: client)
        case "find_atm": FindATMTool(client: client)
        case "fees_and_charges": FeesAndChargesTool(client: client)
        case "account_balance": AccountBalanceTool(client: client)
        case "convert_currency": ConvertCurrencyTool(client: client)
        case "pending_payments": PendingPaymentsTool(client: client)
        case "scheduled_payments": ScheduledPaymentsTool(client: client)
        case "card_limits": CardLimitsTool(client: client)
        case "reward_points": RewardPointsTool(client: client)
        case "dispute_status": DisputeStatusTool(client: client)
        case "branch_hours": BranchHoursTool(client: client)
        case "interest_earned": InterestEarnedTool(client: client)
        default: nil
        }
    }
}
