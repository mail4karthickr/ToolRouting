import Foundation
import FoundationModels


private func catalogEntry(_ displayName: String) -> ToolDefinition {
    guard let definition = ToolCatalog.byName[displayName] else {
        preconditionFailure("No ToolCatalog entry named '\(displayName)'")
    }
    return definition
}


@Generable
struct AccountArgument {
    @Guide(description: "Which account: checking, savings, credit card, or all")
    var account: String
}

@Generable
struct CardArgument {
    @Guide(description: "Which card the question is about. Use `all` when it does not name one — 'what's my card limit?' names no card.")
    var card: CardType
}

@Generable
struct NoArguments {}

struct ListTransactionsTool: Tool {
    let client: any BankAPIClient
    var name: String { catalogEntry("list_transactions").displayName }
    var description: String { catalogEntry("list_transactions").description }

    @Generable
    struct TransactionWindow {
        @Guide(description: "How many past days of transactions to show, e.g. 7")
        var days: Int
    }

    func call(arguments: TransactionWindow) async throws -> String {
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
    struct MerchantSearch {
        @Guide(description: "The merchant name, e.g. Starbucks")
        var merchant: String
    }

    func call(arguments: MerchantSearch) async throws -> String {
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
    var name: String { catalogEntry("get_dispute_status").displayName }
    var description: String { catalogEntry("get_dispute_status").description }

    @Generable
    struct DisputeQuery {
        @Guide(description: "The merchant of the disputed charge, or 'all'")
        var merchant: String
    }

    func call(arguments: DisputeQuery) async throws -> String {
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
    struct StatementRequest {
        @Guide(description: "The period, e.g. 'June' or 'last month'")
        var month: String
        @Guide(description: "Which account: checking, savings, or credit card")
        var account: String
    }

    func call(arguments: StatementRequest) async throws -> String {
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
        try await client.cardNumber(cardType: arguments.card.apiValue)
    }
}

struct CardLimitsTool: Tool {
    let client: any BankAPIClient
    var name: String { catalogEntry("card_limits").displayName }
    var description: String { catalogEntry("card_limits").description }
    typealias Arguments = CardArgument

    func call(arguments: CardArgument) async throws -> String {
        try await client.cardLimits(cardType: arguments.card.apiValue)
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

    /// The coordinates the next call needs. Labelled rather than a bare
    /// pair, because `find_nearest_atm(latitude:longitude:)` has to copy
    /// them across and an unlabelled pair invites a transposed one.
    func call(arguments: NoArguments) async throws -> String {
        let location = try await client.currentLocation()
        return "Latitude \(location.latitude), longitude \(location.longitude)"
    }
}

/// Branches nearest a coordinate pair.
///
/// Same shape as `FindNearestATM`, and for the same reason: the arguments
/// are `Double`s rather than a place string, so the model physically
/// cannot call this without calling `get_location` first. While this took
/// a `location: String` it could satisfy the parameter with the literal
/// "current location" and skip the chain entirely.
struct FindNearestBranchTool: Tool {
    let client: any BankAPIClient
    var name: String { catalogEntry("find_nearest_branch").displayName }
    var description: String { catalogEntry("find_nearest_branch").description }

    @Generable
    struct Coordinates {
        @Guide(description: "Latitude from get_location, e.g. 37.7749")
        var latitude: Double
        @Guide(description: "Longitude from get_location, e.g. -122.4194")
        var longitude: Double
    }

    func call(arguments: Coordinates) async throws -> String {
        let branches = try await client.findNearestBranches(
            latitude: arguments.latitude,
            longitude: arguments.longitude
        )
        return branches.isEmpty
            ? "No branches near \(arguments.latitude), \(arguments.longitude)."
            : branches.joined(separator: "\n")
    }
}

/// ATMs nearest a coordinate pair.
///
/// The arguments are `Double`s rather than a place string on purpose.
/// `get_location` is the only tool that yields coordinates, so the model
/// physically cannot call this one without calling that one first —
/// guided decoding will not invent a plausible latitude the way it would
/// happily fill `location: "current location"`.
struct FindNearestATM: Tool {
    let client: any BankAPIClient
    var name: String { catalogEntry("find_nearest_atm").displayName }
    var description: String { catalogEntry("find_nearest_atm").description }

    @Generable
    struct Coordinates {
        @Guide(description: "Latitude from get_location, e.g. 37.7749")
        var latitude: Double
        @Guide(description: "Longitude from get_location, e.g. -122.4194")
        var longitude: Double
    }

    func call(arguments: Coordinates) async throws -> String {
        let atms = try await client.findNearestATMs(
            latitude: arguments.latitude,
            longitude: arguments.longitude
        )
        return atms.isEmpty
            ? "No ATMs near \(arguments.latitude), \(arguments.longitude)."
            : atms.joined(separator: "\n")
    }
}

struct BranchHoursTool: Tool {
    let client: any BankAPIClient
    var name: String { catalogEntry("branch_hours").displayName }
    var description: String { catalogEntry("branch_hours").description }

    @Generable
    struct BranchHoursQuery {
        @Guide(description: "The branch ID from find_nearest_branch, e.g. 'BR-4417'. Not the branch name.")
        var branchID: String
    }

    func call(arguments: BranchHoursQuery) async throws -> String {
        try await client.branchHours(branchID: arguments.branchID)
    }
}

// MARK: - Money & rewards

struct ConvertCurrencyTool: Tool {
    let client: any BankAPIClient
    var name: String { catalogEntry("convert_currency").displayName }
    var description: String { catalogEntry("convert_currency").description }

    @Generable
    struct CurrencyConversion {
        @Guide(description: "A concrete amount, e.g. '$500'")
        var amount: String
        @Guide(description: "The target currency code, e.g. 'EUR'")
        var to: String
    }

    func call(arguments: CurrencyConversion) async throws -> String {
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
        case "find_nearest_branch": FindNearestBranchTool(client: client)
        case "find_nearest_atm": FindNearestATM(client: client)
        case "fees_and_charges": FeesAndChargesTool(client: client)
        case "account_balance": AccountBalanceTool(client: client)
        case "convert_currency": ConvertCurrencyTool(client: client)
        case "pending_payments": PendingPaymentsTool(client: client)
        case "scheduled_payments": ScheduledPaymentsTool(client: client)
        case "card_limits": CardLimitsTool(client: client)
        case "reward_points": RewardPointsTool(client: client)
        case "get_dispute_status": DisputeStatusTool(client: client)
        case "branch_hours": BranchHoursTool(client: client)
        case "interest_earned": InterestEarnedTool(client: client)
        default: nil
        }
    }

    /// Every tool that has an implementation, in catalog order.
    ///
    /// Exists because a session's `tools` are fixed at init and the agent
    /// now keeps ONE session for the app's lifetime: anything the model
    /// might ever be asked to call has to be bound from the start, or the
    /// call has nowhere to dispatch to.
    ///
    /// This is NOT the same as putting the whole catalog in the prompt.
    /// What the model can SEE is set per request, by rewriting the
    /// session's instructions entry with only the routed tools'
    /// definitions — see `ToolExecutionAgent.beginTurn`. Binding is about
    /// what is dispatchable; the instructions entry is about what is
    /// visible, and only the second one costs context.
    static func allTools(client: any BankAPIClient) -> [any Tool] {
        ToolCatalog.all.compactMap { tool(named: $0.displayName, client: client) }
    }
}
