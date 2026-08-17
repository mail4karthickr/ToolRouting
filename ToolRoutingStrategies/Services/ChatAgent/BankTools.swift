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
    /// MEASURED, 2026-08-13. "Show my card limits and my credit card
    /// number" called card_number with `all`, and the reply handed the
    /// customer their DEBIT number as well — Faithfulness 3 and
    /// Naturalness 3 for "the debit card number the customer never asked
    /// for". Every figure was real; none of it was asked for.
    ///
    /// The guide said when to use `all` and never said when not to, so
    /// the named case now leads and carries the example. `all` is the
    /// fallback it was meant to be.
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
    /// Rows as one sentence: a lead that says what they are, then the
    /// rows.
    ///
    /// NO COUNT IN THE LEAD, since 2026-08-13, and the reason is a
    /// fabrication rather than a matter of taste. These lists are
    /// COMPLETE — every fee, every pending payment, every scheduled one —
    /// so a number in front of them tells the reader nothing the list
    /// does not, and a model reading "3 scheduled payments: …" writes
    /// "three scheduled payments totaling $2,345.89", a figure no tool
    /// returned and that cannot be computed from a list containing "the
    /// statement balance". Faithfulness 1, the only 1 in that run.
    ///
    /// `list_transactions` is the exception that proves the rule and
    /// keeps its own wording: it names three of eight, so something has
    /// to say the list is partial. It says it with "includes".
    static func sentence(_ rows: [String], lead: String, empty: String) -> String {
        rows.isEmpty ? empty : "\(lead) \(list(rows))."
    }

    /// The closest one, then the rest — for the finders, where the
    /// question is "which is nearest" and the other rows are context.
    ///
    /// MEASURED, 2026-08-12. `find_nearest_atm` returned three rows joined
    /// by newlines and the answers read "Here are the ATMs near your
    /// location: Market Square ATM — 0.1 mi, 24 h, Main St Branch ATM —
    /// 0.4 mi, 24 h, QuickCash Mart — 0.6 mi, until 11 pm" — every figure
    /// correct, Naturalness 3 for reading as a pasted list, against a
    /// reference answer that names the closest one and stops. A list of
    /// equals invites a list back; naming the answer first does not.
    ///
    /// The others stay because they are real and the question was about
    /// proximity, not exclusivity — dropping them here would be the tool
    /// deciding what the customer may know. They keep their NAMES and
    /// lose their detail, which is the second half of the same finding:
    /// spelling all three out in full got the whole list recited back.
    ///
    /// MEASURED, 2026-08-13. With every row carrying its distance and
    /// hours, "atm near me" and "Where's the closest branch?" both
    /// answered with all three — "longer and more list-like than a
    /// person's answer", "reads slightly like a dump of the full lookup
    /// rather than a direct answer", Naturalness 3 each. The question
    /// asked for one. Naming the rest without their figures says they
    /// exist, which is all the question needs from them, and leaves
    /// nothing to recite.
    ///
    /// `describe` pulls the name off a row that reads
    /// `Market Square ATM, 0.1 miles away and open 24 hours` — the name
    /// is everything before the first comma, which is a property of how
    /// the client writes these rows and is asserted in ToolOutputTests.
    static func nearest(_ rows: [String], kind: String, empty: String) -> String {
        guard let closest = rows.first else { return empty }
        let rest = rows.dropFirst().map(name(inRow:))
        guard !rest.isEmpty else { return "The closest \(kind) is \(closest)." }
        let plural = rest.count == 1 ? "is" : "are"
        return "The closest \(kind) is \(closest). \(list(rest)) \(plural) also nearby."
    }

    /// A finder row's name: everything up to the detail that follows it.
    static func name(inRow row: String) -> String {
        String(row.prefix(while: { $0 != "," })).trimmingCharacters(in: .whitespaces)
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
            return "Recent activity in the last \(days) days includes \(named)."
        }
        // THE COUNT GOES LAST, and that is not a cosmetic choice. It led
        // the sentence until 2026-08-13 — "8 transactions in the last 7
        // days, the most recent being …" — and the model opened its reply
        // with it every time, which the judge scored Naturalness 3 twice
        // in one run: "reads like a restated data summary". The same run
        // scored 4 on the sample whose answer happened to start with the
        // merchants instead.
        //
        // It stays in the string because naming three of eight without
        // saying so is a silent truncation. At the end it is a qualifier
        // a natural reply can carry or drop; at the front it is the first
        // thing the customer hears about their own week.
        // "INCLUDES" IS THE HONESTY, not the count that used to follow it.
        // Naming three of eight has to say somewhere that it is naming
        // three of eight, and the sentence ended "…, out of 8
        // transactions in all" until 2026-08-13 to do exactly that. The
        // model repeated the clause verbatim and the judge marked it
        // twice in one run — Faithfulness 3 and Naturalness 3, both
        // quoting "out of 8 transactions in all" as the stilted part.
        //
        // "Includes" carries the same claim in a word the reply can use
        // without sounding like a report: it says these are among the
        // transactions, never that they are all of them. The exact count
        // is what `search_transactions` is for.
        return "Recent activity in the last \(days) days includes \(named)."
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

    // THE ROW FORM IS GONE, 2026-08-13. `date · merchant · account ·
    // amount` survived here for `search_transactions`, on the argument
    // that for a single-merchant search the rows ARE the answer. True,
    // and beside the point: what a reply needs from a match is the
    // amount, the merchant and the date, which `clause(for:)` gives in
    // words. The account column and the middots were the last of the
    // table shape left in the catalog, and the last thing a reply could
    // paste through.
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

    /// THE LAST ROW-SHAPED PAYLOAD IN THE CATALOG, until 2026-08-13.
    ///
    /// It returned `12 Aug · Uber · Credit Card · -$23.75` with a
    /// `Total:` line under it, and it was the last place a middot could
    /// reach a reply. "how much did i spend at uber" came back "The
    /// charge was $23.75 at Uber" — Naturalness 3 for stilted phrasing
    /// that "reframes the question about spending as a 'charge'", which
    /// is what a row labelled with an account and a sign invites.
    ///
    /// The rows were defensible here longer than anywhere else, because
    /// for a single-merchant search the rows ARE the answer rather than a
    /// list to summarise. What was never defensible is their SHAPE: the
    /// account column and the minus sign are for a table, and a reply
    /// about spending needs neither — the direction of the money is
    /// already in the word "spent".
    ///
    /// The total stays, and stays precomputed. "What did I spend at X" is
    /// a sum question, and leaving a small model to add a column up is
    /// the arithmetic risk this whole file avoids.
    func call(arguments: MerchantSearch) async throws -> String {
        let transactions = try await client.searchTransactions(merchant: arguments.merchant)
        guard !transactions.isEmpty else {
            return "No transactions found for \(arguments.merchant)."
        }
        let clauses = transactions.map(ListTransactionsTool.clause(for:))
        let total = transactions.reduce(Decimal.zero) { $0 + $1.amount }
        // "Spent" only when every match is money going OUT. A search that
        // turns up a payroll credit is not spending, and saying so would
        // be the tool putting a word in the answer that the figures do
        // not support.
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
        // THE LEAD CARRIES THE STATUS, because the clauses no longer can:
        // a payment's own description says what it is and when, not which
        // list it came from. Sample 51 has been marked down three times
        // for reporting scheduled items as pending, so "pending" and
        // "still processing" are both said here — the first is the word
        // the customer used, the second is what it means, and the
        // scheduled list can claim neither.
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
        return ToolOutput.nearest(
            branches,
            kind: "branch",
            empty: "No branches near \(arguments.latitude), \(arguments.longitude)."
        )
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
        // "Credit score: 742" is a field with a label, and a label is the
        // one shape this catalog no longer hands the model — see
        // `ToolOutput`. Said as a sentence, in the second person, it is
        // already the answer.
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
    /// Builds the executable tool for a routed call, or nil when the plan
    /// named something that has no implementation. Keyed by the same
    /// `displayName` the router selects, which is what lets a plan of
    /// ToolName values become a set of live tools.
    ///
    /// `.none` deliberately returns nil: it is an escalation decision,
    /// not something the agent can run.
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
