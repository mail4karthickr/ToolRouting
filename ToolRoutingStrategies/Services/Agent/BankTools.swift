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

// MARK: - Output shape
//
// A tool whose data is a handful of rows has a choice about how it hands
// them over, and the choice decides what the model does with them.
//
// MEASURED, 2026-08-12. Rows joined by newlines read as a table, and the
// model reproduces tables: `list_transactions` was pasted back verbatim,
// middots and all, on two samples (Naturalness 2 each), and
// `fees_and_charges` came back as a markdown bullet list on a third
// (Naturalness 3). Rows joined into a SENTENCE read as an answer, which
// is what the reply has to be — and the reply is one or two sentences of
// plain language by product requirement, not by preference.
//
// This is the same argument `search_transactions` already makes with its
// precomputed `Total:` line: work the model would otherwise have to do
// in its own context is cheaper and safer done here, on the real data.
//
// THE ROWS THEMSELVES PASS THROUGH UNTOUCHED. They are the mock's ground
// truth and the dataset's expected answers quote their wording, so this
// changes the SHAPE of the output and nothing about its content — no
// figure, label, or date is rewritten on the way past.
enum ToolOutput {
    /// Rows as one sentence: a lead that counts them, then the rows.
    static func sentence(_ rows: [String], lead: (Int) -> String, empty: String) -> String {
        rows.isEmpty ? empty : "\(lead(rows.count)): \(list(rows))."
    }

    /// Joins clauses the way a person would say them. Hand-rolled rather
    /// than `ListFormatter` so the string the judge grades against is the
    /// same one on every locale a test machine happens to run in.
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

    /// The window as ONE SENTENCE, not a table of rows.
    ///
    /// MEASURED, 2026-08-12, on the failing-sample run. This used to
    /// return one `12 Aug · Starbucks · Checking · -$6.45` row per
    /// transaction, and the model did the only two things it can do with
    /// eight rows of table:
    ///
    ///   pasted them   samples 2 and 3 reproduced the rows line for line,
    ///                 middot separators and account tags included.
    ///                 Naturalness 2 on both — "raw tool output pasted
    ///                 through", which is the definition of the 2.
    ///   folded them   sample 1 wrote them out as prose and misattributed
    ///                 a date doing it: Amazon reported on 12 Aug where
    ///                 the row said 11 Aug. Faithfulness 2.
    ///
    /// Neither is fixable from the instructions, and the attempt is
    /// already recorded in ToolExecutionAgent: telling the model to
    /// summarise made it merge figures ACROSS rows and cost Faithfulness
    /// on three samples that had been working. The row-shaped payload was
    /// the cause, so the payload is what changed.
    ///
    /// Same move `search_transactions` below already makes with its
    /// `Total:` line, and for the same reason — a value the model would
    /// otherwise have to derive is cheaper and safer computed here, where
    /// it is arithmetic on the real data rather than a small model
    /// re-reading its own context.
    ///
    /// WHAT IS GONE: per-row detail beyond the three named. A question
    /// about one merchant is `search_transactions`, which still returns
    /// every matching row, and the count keeps this honest — the reply
    /// says how many there were, so nothing is hidden by being unnamed.
    static func summary(of transactions: [Transaction], days: Int) -> String {
        guard !transactions.isEmpty else {
            return "No transactions in the last \(days) days."
        }
        // Sorted rather than assumed: "most recent" has to be true of the
        // three this names, and the client's order is its own business.
        //
        // BY DAY, then by the client's own order, and both halves of that
        // matter. Comparing raw instants sorts two transactions that
        // print the SAME DATE by the microsecond their `Date` happened to
        // be constructed at, which is invisible in the output and
        // reversed the fixture order — Amazon and Shell Gas Station are
        // both 11 Aug and both land in the top three, so it decided which
        // of them this sentence names second purely by fixture
        // construction time. Truncating to the day makes the comparison
        // match what the reader sees; the index keeps the tie resolved
        // the same way on every run, since `sorted(by:)` promises no
        // stability of its own.
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
            let noun = recent.count == 1 ? "transaction" : "transactions"
            return "\(recent.count) \(noun) in the last \(days) days: \(named)."
        }
        return "\(recent.count) transactions in the last \(days) days, "
            + "the most recent being \(named)."
    }

    /// How many transactions the summary names. Three because that is
    /// what "recent activity includes …" carries in one readable
    /// sentence; the count before it is what makes naming a subset
    /// truthful rather than a silent truncation.
    private static let namedInSummary = 3

    /// One transaction as a clause inside a sentence, rather than a row
    /// in a table. Money IN reads "from" so a paycheck is not described
    /// as a purchase, and the sign lives in that word rather than in a
    /// minus the model has to interpret.
    static func clause(for transaction: Transaction) -> String {
        let amount = abs(transaction.amount).formatted(.currency(code: "USD"))
        let date = transaction.date.formatted(.dateTime.month(.abbreviated).day())
        let preposition = transaction.amount < 0 ? "at" : "from"
        return "\(amount) \(preposition) \(transaction.merchant) on \(date)"
    }

    /// The row form, kept for `search_transactions`, where the rows ARE
    /// the answer: that tool is asked about one merchant and returns a
    /// handful of matches, so there is no dump to provoke.
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
            lead: { "\($0) \($0 == 1 ? "fee" : "fees") and charges" },
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
        // "pending payment" in the lead, not "payment", because the rows
        // themselves do not always say which list they came from: the
        // PG&E row reads "(scheduled for the 1st)" while sitting in the
        // PENDING list, and sample 7 has twice been marked down for
        // reporting scheduled items as pending. The lead is the only
        // place that distinction survives.
        return ToolOutput.sentence(
            payments,
            lead: { "\($0) pending \($0 == 1 ? "payment" : "payments")" },
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
            lead: { "\($0) scheduled \($0 == 1 ? "payment" : "payments")" },
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

// MARK: - Call logging
//
// Wraps a tool so its invocation is written to the log as it happens,
// rather than reconstructed from the transcript after the turn.
//
// The two are not equivalent. The transcript is read once the generation
// FINISHES, so a turn that hangs inside `client.listTransactions` or
// throws mid-chain leaves no record of the call at all — which is
// precisely the run worth having a log for. This writes a line when the
// call goes out, and another when it comes back, so an interrupted turn
// still shows which tool it was sitting in.
//
// Forwarding is total: `name`, `description` and `parameters` are the
// wrapped tool's, so what the model is shown and what it dispatches to
// are unchanged. Only `call` gains anything.

private struct LoggedTool<Wrapped: Tool>: Tool {
    let wrapped: Wrapped

    var name: String { wrapped.name }
    var description: String { wrapped.description }
    var parameters: GenerationSchema { wrapped.parameters }
    var includesSchemaInInstructions: Bool { wrapped.includesSchemaInInstructions }

    func call(arguments: Wrapped.Arguments) async throws -> Wrapped.Output {
        let clock = ContinuousClock()
        let start = clock.now
        Log.tools.debug("→ \(wrapped.name)(\(String(describing: arguments).loggable()))")
        do {
            let output = try await wrapped.call(arguments: arguments)
            Log.tools.info("← \(wrapped.name) \((clock.now - start).logged): \(String(describing: output).loggable())")
            return output
        } catch {
            // The agent surfaces a tool failure as a degraded answer, so
            // without this the cause never appears anywhere.
            Log.tools.error("✗ \(wrapped.name) threw after \((clock.now - start).logged): \(error)")
            throw error
        }
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
    ///
    /// Everything handed out is wrapped in `LoggedTool`, so there is one
    /// place that decides tools are logged rather than twenty `call`
    /// bodies that each have to remember.
    static func tool(named displayName: String, client: any BankAPIClient) -> (any Tool)? {
        guard let tool = implementation(named: displayName, client: client) else { return nil }
        return logged(tool)
    }

    /// Opens the existential: `tool` arrives as `any Tool` and binds to
    /// `T`, which is what `LoggedTool` needs to forward the associated
    /// `Arguments` and `Output` types.
    private static func logged<T: Tool>(_ tool: T) -> any Tool {
        LoggedTool(wrapped: tool)
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
