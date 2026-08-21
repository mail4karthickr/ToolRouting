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
struct CardNumberArgument {
    @Guide(description: """
        Which card's number to return. When the question names a card, use THAT card — "my \
        credit card number" is credit, "my debit card" is debit. Use `all` when it names \
        none, as in "I need my card number"; that returns both numbers.
        """)
    var card: CardType
}

/// The limits tool's own argument, and the split from `CardNumberArgument`
/// IS the fix.
///
/// One `CardArgument` served both card tools until 2026-08-19, so both
/// inherited a guide whose only worked examples were card NUMBER
/// questions. A limits question matched neither, and "limit" collocates
/// with "credit limit" more strongly than with anything else in this
/// domain — so on a question naming no card the model reached for
/// `credit`, got the one branch of the client with no withdrawal limit in
/// it, and reported a spending limit instead. Reproducible, four runs out
/// of four (eval sample 7).
///
/// A shared argument type is a shared PROMPT. Two tools whose parameters
/// happen to have the same shape do not have the same question to answer
/// about them, and the one with no examples of its own borrows the
/// other's.
@Generable
struct CardLimitsArgument {
    @Guide(description: """
        Which card's limits to return. `all` is the DEFAULT and the right answer whenever the \
        question does not name a card: it returns the credit limit, the daily spending limit \
        and the daily ATM withdrawal limit together, so it covers any limit question. Name a \
        card ONLY when the question does — "my credit card limit" is credit, "the limit on my \
        debit card" is debit. NAMING A KIND OF LIMIT IS NOT NAMING A CARD: which limit is \
        asked about tells you nothing about which card holds it, so those questions are still \
        `all`.
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

    /// Every field optional, and every default lives HERE rather than in a
    /// string the model has to remember and retype. "Leave this at some
    /// sentinel value for no filter" was the earlier design, and it broke:
    /// asked for Starbucks with no time period named, the model wrote
    /// `startDate: "2026-07-01"` — the literal example the OLDER-edge
    /// guide text led with, not the "far in the past" case the same text
    /// also described. A required field always gets a value, so an unsure
    /// model reaches for the nearest example rather than the right
    /// behaviour. An optional field just gets omitted, which is a
    /// question the type system answers instead of the model.
    @Generable
    struct MerchantSearch {
        @Guide(description: "The merchant name, e.g. Starbucks. Omit when the question names no merchant.")
        var merchant: String? = nil

        @Guide(description: "Which spending category to filter to. Omit when the question names no category.")
        var category: TransactionCategory? = nil

        @Guide(description: "Which account to filter to. Omit when the question names no account.")
        var account: AccountType? = nil

        /// NEITHER FIELD DOES CALENDAR ARITHMETIC, and neither is ever
        /// filled from today's date. They carry across the two dates
        /// `resolve_date_range` returned, the way `find_nearest_atm`
        /// carries across the coordinates `get_location` returned.
        ///
        /// That tool always runs first — it has an `allTime` period for a
        /// question naming none — so there is always a real pair to copy
        /// and never a reason to work one out. MEASURED, when there was:
        /// asked for "starbucks spend last two months" with no date tool
        /// in the plan, this filled both fields itself from the date in
        /// the turn, and nothing in the answer showed where they came from.
        @Guide(description: """
            The OLDER edge of the window: the FIRST of the two dates resolve_date_range \
            returned, copied character for character. Never work a date out yourself.
            """)
        var startDate: String? = nil

        @Guide(description: """
            The MORE RECENT edge of the window: the SECOND of the two dates \
            resolve_date_range returned, copied character for character.
            """)
        var endDate: String? = nil
    }

    func call(arguments: MerchantSearch) async throws -> String {
        guard let start = Self.resolveDate(arguments.startDate, fallback: .distantPast, edge: .start) else {
            return "Could not read a date from '\(arguments.startDate ?? "")'. Copy it exactly as resolve_date_range returned it, e.g. 2026-08-01."
        }
        guard let end = Self.resolveDate(arguments.endDate, fallback: .distantFuture, edge: .end) else {
            return "Could not read a date from '\(arguments.endDate ?? "")'. Copy it exactly as resolve_date_range returned it, e.g. 2026-08-01."
        }

        let merchant = arguments.merchant ?? ""
        let transactions = try await client.searchTransactions(
            merchant: merchant,
            category: arguments.category ?? .all,
            accountType: arguments.account ?? .all,
            startDate: min(start, end),
            endDate: max(start, end)
        )
        guard !transactions.isEmpty else {
            return "No transactions found\(merchant.isEmpty ? "" : " for \(merchant)")."
        }
        let clauses = transactions.map(ListTransactionsTool.clause(for:))
        // NO TOTAL — deliberately. This tool used to add the figures up
        // itself, which meant a plain "how much did I spend at X"
        // question never needed calculator at all: the one tool that
        // "obviously" answered it also silently did the arithmetic. Each
        // matching transaction stands on its own here; a total across
        // more than one is calculator's job, same as any other figure no
        // tool hands back directly.
        guard clauses.count > 1 else { return "You spent \(clauses[0])." }
        return "Matching transactions: \(ToolOutput.list(clauses))."
    }

    /// Which edge of the window a date is, because a day is a RANGE and
    /// `2026-07-31` names all of it.
    enum Edge {
        case start
        case end
    }

    /// `nil` means the field was omitted and resolves straight to
    /// `fallback` rather than a parse attempt. A PRESENT value still gets
    /// checked: omitting is trusted, typing something is not.
    private static func resolveDate(_ text: String?, fallback: Date, edge: Edge) -> Date? {
        guard let text else { return fallback }
        return parseDate(text, edge: edge)
    }

    /// `yyyy-MM-dd` in the CURRENT CALENDAR, with an end date meaning the
    /// last moment of its day.
    ///
    /// This was `Date(text, strategy: .iso8601.year().month().day())`, and
    /// it was wrong twice over. MEASURED: "how much did i spnd at walmart
    /// last mnth" resolved the window correctly to 2026-07-01 to
    /// 2026-07-31 and then returned two of the three July charges — the
    /// $73.45 on the 31st was silently dropped.
    ///
    /// `.iso8601` reads a bare date as MIDNIGHT UTC. So the end of the
    /// window landed at the first instant of its final day and excluded
    /// everything that happened during it, and the start landed 5½ hours
    /// into the day in a UTC+5:30 zone, which can drop an early
    /// transaction at the other edge. `DateRangeTool` computes both edges
    /// correctly — 00:00:00 and 23:59:59 in the calendar's own zone — and
    /// all of that precision is thrown away by rendering to `yyyy-MM-dd`
    /// and parsing it back. This restores it on the way in.
    ///
    /// A dropped transaction is the worst shape of wrong: the total is
    /// smaller, every figure in it is real, and nothing anywhere says a
    /// row is missing.
    private static func parseDate(_ text: String, edge: Edge) -> Date? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              let startOfDay = Calendar.current.date(
                from: DateComponents(year: year, month: month, day: day)
              )
        else { return nil }

        guard edge == .end else { return startOfDay }
        guard let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: startOfDay) else {
            return startOfDay
        }
        return nextDay.addingTimeInterval(-1)
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

    @Generable
    struct BalanceRequest {
        @Guide(description: """
            Which account's balance to return. Use `all` when the question names no account — "what's my balance?" names none, and `all` returns checking, savings and the credit card together. Name one ONLY when the question does: "my savings balance" is savings.
            """)
        var account: AccountType
    }

    func call(arguments: BalanceRequest) async throws -> String {
        try await client.accountBalance(accountType: arguments.account.apiValue)
    }
}

struct RoutingNumberTool: Tool {
    let client: any BankAPIClient
    var name: String { catalogEntry("routing_number").displayName }
    var description: String { catalogEntry("routing_number").description }
    /// NO ARGUMENT, and that is a fact about routing numbers rather than a
    /// simplification. A routing number identifies the BANK, not one of the
    /// customer's accounts — every account here shares 011000000. Asking the
    /// model which account it wants is a question with no right answer: it
    /// costs prompt tokens, and any value it picks changes nothing.
    typealias Arguments = NoArguments

    func call(arguments: NoArguments) async throws -> String {
        try await client.routingNumber()
    }
}

struct AccountNumberTool: Tool {
    let client: any BankAPIClient
    var name: String { catalogEntry("account_number").displayName }
    var description: String { catalogEntry("account_number").description }

    @Generable
    struct NumberRequest {
        @Guide(description: """
            Which account's number to return. Use `all` when the question names no account. Name one ONLY when the question does: "my savings account number" is savings.
            """)
        var account: AccountType
    }

    func call(arguments: NumberRequest) async throws -> String {
        try await client.accountNumber(accountType: arguments.account.apiValue)
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

    @Generable
    struct InterestRequest {
        @Guide(description: """
            Which account's interest to report. Interest is earned on deposit accounts, so a question that names no account is asking about savings or about everything — use `all` rather than guessing one.
            """)
        var account: AccountType
    }

    func call(arguments: InterestRequest) async throws -> String {
        try await client.interestEarned(accountType: arguments.account.apiValue)
    }
}

struct FeesAndChargesTool: Tool {
    let client: any BankAPIClient
    var name: String { catalogEntry("fees_and_charges").displayName }
    var description: String { catalogEntry("fees_and_charges").description }

    @Generable
    struct FeesRequest {
        @Guide(description: """
            Which account's fees to list. Use `all` when the question names no account — "what fees did I pay" names none and is asking for all of them.
            """)
        var account: AccountType
    }

    func call(arguments: FeesRequest) async throws -> String {
        let fees = try await client.feesAndCharges(accountType: arguments.account.apiValue)
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
    typealias Arguments = CardNumberArgument

    func call(arguments: CardNumberArgument) async throws -> String {
        try await client.cardNumber(cardType: arguments.card.apiValue)
    }
}

struct CardLimitsTool: Tool {
    let client: any BankAPIClient
    var name: String { catalogEntry("card_limits").displayName }
    var description: String { catalogEntry("card_limits").description }
    typealias Arguments = CardLimitsArgument

    func call(arguments: CardLimitsArgument) async throws -> String {
        try await client.cardLimits(cardType: arguments.card.apiValue)
    }
}

// MARK: - Payments

struct PendingPaymentsTool: Tool {
    let client: any BankAPIClient
    var name: String { catalogEntry("pending_payments").displayName }
    var description: String { catalogEntry("pending_payments").description }

    @Generable
    struct PendingRequest {
        @Guide(description: """
            Which account's pending payments to list. Use `all` when the question names no account; pending payments are rarely asked about per-account.
            """)
        var account: AccountType
    }

    func call(arguments: PendingRequest) async throws -> String {
        let payments = try await client.pendingPayments(accountType: arguments.account.apiValue)
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

    @Generable
    struct ScheduledRequest {
        @Guide(description: """
            Which account's scheduled payments to list. Use `all` when the question names no account; scheduled payments are rarely asked about per-account.
            """)
        var account: AccountType
    }

    func call(arguments: ScheduledRequest) async throws -> String {
        let payments = try await client.scheduledPayments(accountType: arguments.account.apiValue)
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
        case "resolve_date_range": DateRangeTool()
        case "calculator": CalculatorTool()
        default: nil
        }
    }

    static func allTools(client: any BankAPIClient) -> [any Tool] {
        ToolCatalog.all.compactMap { tool(named: $0.displayName, client: client) }
    }
}
