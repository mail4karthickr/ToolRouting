import Foundation
import FoundationModels

private func catalogEntry(_ displayName: String) -> ToolDefinition {
    guard let definition = ToolCatalog.byName[displayName] else {
        preconditionFailure("No ToolCatalog entry named '\(displayName)'")
    }
    return definition
}

// MARK: - Shared arguments

@Generable
struct AccountArgument {
    @Guide(description: "Which account: checking, savings, credit card, or all")
    var account: String
}

@Generable
struct CardArgument {
    @Guide(description: """
        Which card the question is about. When it names one, use THAT card — "my credit card \
        number" is credit, "my debit card" is debit. Use `all` ONLY when the question names no \
        card at all, as in "what's my card limit?".
        """)
    var card: CardType
}

@Generable
struct NoArguments {}

// MARK: - Output shape

enum ToolOutput {
    static func sentence(_ rows: [String], lead: String, empty: String) -> String {
        rows.isEmpty ? empty : "\(lead) \(list(rows))."
    }

    static func nearest(_ rows: [String], kind: String, empty: String) -> String {
        guard let closest = rows.first else { return empty }
        let rest = rows.dropFirst().map(name(inRow:))
        guard !rest.isEmpty else { return "The closest \(kind) is \(closest)." }
        let plural = rest.count == 1 ? "is" : "are"
        return "The closest \(kind) is \(closest). \(list(rest)) \(plural) also nearby."
    }

    static func name(inRow row: String) -> String {
        String(row.prefix(while: { $0 != "," })).trimmingCharacters(in: .whitespaces)
    }

    static func list(_ clauses: some Collection<String>) -> String {
        let items = Array(clauses)
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) and \(items[1])"
        default: return items.dropLast().joined(separator: ", ") + ", and \(items[items.count - 1])"
        }
    }
}

// MARK: - Transactions

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
        return Self.summary(of: transactions, days: arguments.days)
    }

    static func summary(of transactions: [Transaction], days: Int) -> String {
        guard !transactions.isEmpty else {
            return "No transactions in the last \(days) days."
        }
        let calendar = Calendar.current
        let recent = transactions.enumerated()
            .sorted { left, right in
                let leftDay = calendar.startOfDay(for: left.element.date)
                let rightDay = calendar.startOfDay(for: right.element.date)
                return leftDay == rightDay
                    ? left.offset < right.offset
                    : leftDay > rightDay
            }
            .map(\.element)
        let named = ToolOutput.list(recent.prefix(namedInSummary).map(Self.clause(for:)))
        guard recent.count > namedInSummary else {
            return "Recent activity in the last \(days) days includes \(named)."
        }
        return "Recent activity in the last \(days) days includes \(named)."
    }

    private static let namedInSummary = 3

    static func clause(for transaction: Transaction) -> String {
        let amount = abs(transaction.amount).formatted(.currency(code: "USD"))
        let date = transaction.date.formatted(.dateTime.month(.abbreviated).day())
        let preposition = transaction.amount < 0 ? "at" : "from"
        return "\(amount) \(preposition) \(transaction.merchant) on \(date)"
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
        let clauses = transactions.map(ListTransactionsTool.clause(for:))
        let total = transactions.reduce(Decimal.zero) { $0 + $1.amount }
        guard transactions.allSatisfy({ $0.amount < 0 }) else {
            return "Matching transactions: \(ToolOutput.list(clauses)), "
                + "\(total.formatted(.currency(code: "USD"))) in total."
        }
        guard transactions.count > 1 else { return "You spent \(clauses[0])." }
        return "You spent \(ToolOutput.list(clauses)), "
            + "\(abs(total).formatted(.currency(code: "USD"))) in total."
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
        @Guide(description: "Which account the statement is for. Use `all` when the question does not name one — 'get my June statement' names no account.")
        var account: AccountType
    }

    func call(arguments: StatementRequest) async throws -> String {
        try await client.bankStatement(
            month: arguments.month,
            accountType: arguments.account.apiValue
        )
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
        return ToolOutput.sentence(
            fees,
            lead: "You paid",
            empty: "No fees on this account."
        )
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
        return ToolOutput.sentence(
            payments,
            lead: "These payments are pending and still processing:",
            empty: "Nothing pending."
        )
    }
}

struct ScheduledPaymentsTool: Tool {
    let client: any BankAPIClient
    var name: String { catalogEntry("scheduled_payments").displayName }
    var description: String { catalogEntry("scheduled_payments").description }
    typealias Arguments = AccountArgument

    func call(arguments: AccountArgument) async throws -> String {
        let payments = try await client.scheduledPayments(accountType: arguments.account)
        return ToolOutput.sentence(
            payments,
            lead: "These payments are scheduled to go out:",
            empty: "Nothing scheduled."
        )
    }
}

// MARK: - Locations

struct GetLocationTool: Tool {
    let client: any BankAPIClient
    var name: String { catalogEntry("get_location").displayName }
    var description: String { catalogEntry("get_location").description }
    typealias Arguments = NoArguments

    func call(arguments: NoArguments) async throws -> String {
        let location = try await client.currentLocation()
        return "Latitude \(location.latitude), longitude \(location.longitude)"
    }
}

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
        return ToolOutput.nearest(
            branches,
            kind: "branch",
            empty: "No branches near \(arguments.latitude), \(arguments.longitude)."
        )
    }
}

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
        return ToolOutput.nearest(
            atms,
            kind: "ATM",
            empty: "No ATMs near \(arguments.latitude), \(arguments.longitude)."
        )
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
        "Your credit score is \(try await client.creditScore())."
    }
}

struct RewardPointsTool: Tool {
    let client: any BankAPIClient
    var name: String { catalogEntry("reward_points").displayName }
    var description: String { catalogEntry("reward_points").description }
    typealias Arguments = NoArguments

    func call(arguments: NoArguments) async throws -> String {
        let points = try await client.rewardPoints()
        return "You have \(points.formatted()) reward points."
    }
}

// MARK: - Arithmetic (not bound — no session hands this to the model)

final class ComputeTool: Tool, @unchecked Sendable {
    let name = "compute"
    let description = """
        Calculate a figure from numbers other tools have already returned: \
        a total, a difference, a percentage, or a comparison. Use this \
        whenever the answer needs a number no tool returned directly. \
        Never do the arithmetic yourself.
        """

    @Generable
    enum Operation {
        case sum
        case difference
        case percentage
        case compare
    }

    @Generable
    enum Style {
        case currency
        case percent
        case plain
    }

    @Generable
    struct Arguments {
        @Guide(description: "What to calculate")
        var operation: Operation

        @Guide(description: """
            The figures to use, copied character for character from the tool \
            results, for example ["$2,340.12", "$1,850.00"]
            """)
        var operands: [String]

        @Guide(description: "How to format the result: currency, percent, or plain")
        var style: Style

        @Guide(description: "What the result means, for example 'total spent at Amazon'")
        var label: String

        init(operation: Operation, operands: [String], style: Style, label: String) {
            self.operation = operation
            self.operands = operands
            self.style = style
            self.label = label
        }
    }

    func call(arguments: Arguments) async throws -> String {
        var values: [Decimal] = []
        for operand in arguments.operands {
            guard let value = Self.parse(operand) else {
                return """
                    Could not read a number from '\(operand)'. Pass a figure exactly \
                    as a tool returned it.
                    """
            }
            values.append(value)
        }

        switch arguments.operation {
        case .sum:
            guard !values.isEmpty else { return "No figures to add." }
            return format(values.reduce(0, +), arguments)

        case .difference:
            guard values.count == 2 else {
                return "A difference needs exactly two figures; \(values.count) were given."
            }
            return format(values[0] - values[1], arguments)

        case .percentage:
            guard values.count == 2 else {
                return "A percentage needs exactly two figures; \(values.count) were given."
            }
            guard values[1] != 0 else { return "Cannot take a percentage of zero." }
            return format(values[0] / values[1] * 100, arguments)

        case .compare:
            guard values.count == 2 else {
                return "A comparison needs exactly two figures; \(values.count) were given."
            }
            let surplus = values[0] - values[1]
            let covers = surplus >= 0
            return """
                \(arguments.label): \(money(values[0])) \(covers ? "is enough to cover" : "falls short of") \
                \(money(values[1])), a \(covers ? "surplus" : "shortfall") of \(money(abs(surplus))).
                """
        }
    }

    private static func parse(_ text: String) -> Decimal? {
        let digits = text.filter { $0.isNumber || $0 == "." || $0 == "-" }
        guard digits.contains(where: \.isNumber) else { return nil }
        return Decimal(string: digits)
    }

    private func format(_ value: Decimal, _ arguments: Arguments) -> String {
        switch arguments.style {
        case .currency:
            "\(arguments.label): \(money(value))"
        case .percent:
            "\(arguments.label): \(value.formatted(.number.precision(.fractionLength(0...1))))%"
        case .plain:
            "\(arguments.label): \(value.formatted(.number.precision(.fractionLength(0...2))))"
        }
    }

    private func money(_ value: Decimal) -> String {
        value.formatted(.currency(code: "USD"))
    }
}

// MARK: - Registry

enum BankToolRegistry {
    static func tool(named displayName: String, client: any BankAPIClient) -> (any Tool)? {
        implementation(named: displayName, client: client)
    }

    private static func implementation(named displayName: String, client: any BankAPIClient) -> (any Tool)? {
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

    static func allTools(client: any BankAPIClient) -> [any Tool] {
        ToolCatalog.all.compactMap { tool(named: $0.displayName, client: client) }
    }
}
