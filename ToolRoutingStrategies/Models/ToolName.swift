import FoundationModels

// MARK: - Tool identity (single source of truth)
//
// On-device routing layer for a hybrid banking assistant:
//   • App tools = read-only GET operations the app executes directly
//     against the bank's APIs (the raw prompt never leaves the device;
//     only the structured API call does)
//   • none = no local tool serves this request — it involves an action
//     (POST), an uncovered capability, or a MIX of the two. The request
//     leaves the on-device path and is answered by the cloud model.
//
// Each case carries the tool's parameters as typed associated values, so
// a routed call is a complete, ready-to-execute selection — no free-text
// argument parsing.

@Generable
enum ToolName {
    case listTransactions(days: Int)
    case searchTransactions(merchant: String)
    case routingNumber(account: AccountType)
    case accountNumber(account: AccountType)
    case cardNumber(card: CardType)
    case bankStatement(month: String, account: AccountType)
    case creditScore
    case getLocation
    case findNearestBranch(latitude: Double, longitude: Double)
    case findNearestATM(latitude: Double, longitude: Double)
    case feesAndCharges(account: AccountType)
    case accountBalance(account: AccountType)
    case convertCurrency(amount: String, to: String)
    case pendingPayments(account: AccountType)
    case scheduledPayments(account: AccountType)
    case cardLimits(card: CardType)
    case rewardPoints
    case disputeStatus(merchant: String)
    case branchHours(branchID: String)
    case interestEarned(account: AccountType)
    /// No local tool matches: the request (or a sub-task of it) can't be
    /// served on device, so it goes to the cloud model. Not a failure state.
    case none
}

@Generable
enum AccountType {
    case checking
    case savings
    case creditCard
    case all
}

/// Which card a card tool is being asked about.
///
/// `all` exists because most card questions don't name a card — "what's my
/// card limit?" names none, and the honest answer covers both. Before it
/// was a case, the agent still asked for "all": `CardArgument.card` was a
/// free-text String, the model filled it with a value the guide never
/// offered, and `MockBankAPIClient.cardLimits` — a ternary on
/// `contains("credit")` — quietly routed it to the DEBIT branch. The
/// customer asked for their card limit, had a $10,000 credit limit, and
/// was told $1,000. Nothing was invented and nothing errored; the answer
/// was just missing the number they asked for (eval 2026-08-12, sample 12,
/// wrong on four runs out of four).
///
/// As an enum the option set is a fact about the grammar rather than a
/// hint in a `@Guide`: guided decoding cannot emit a fourth value, so no
/// caller downstream has to guess what an unrecognized one meant.
@Generable
enum CardType {
    case debit
    case credit
    /// Every card the customer holds. The right choice when the question
    /// doesn't name one.
    case all
}

extension CardType {
    /// What `BankAPIClient` takes.
    ///
    /// The API layer stays on `String` so it does not depend on the
    /// `@Generable` types — but the string now comes from a closed set
    /// rather than from the model, which is what makes the `all` branch in
    /// the client reachable and unambiguous.
    var apiValue: String {
        switch self {
        case .debit: "debit"
        case .credit: "credit"
        case .all: "all"
        }
    }
}

// MARK: - Display helpers

extension ToolName {
    /// Stable identity matching ToolDefinition.displayName, independent
    /// of the associated parameter values.
    var displayName: String {
        switch self {
        case .listTransactions: "list_transactions"
        case .searchTransactions: "search_transactions"
        case .routingNumber: "routing_number"
        case .accountNumber: "account_number"
        case .cardNumber: "card_number"
        case .bankStatement: "bank_statement"
        case .creditScore: "credit_score"
        case .getLocation: "get_location"
        case .findNearestBranch: "find_nearest_branch"
        case .findNearestATM: "find_nearest_atm"
        case .feesAndCharges: "fees_and_charges"
        case .accountBalance: "account_balance"
        case .convertCurrency: "convert_currency"
        case .pendingPayments: "pending_payments"
        case .scheduledPayments: "scheduled_payments"
        case .cardLimits: "card_limits"
        case .rewardPoints: "reward_points"
        case .disputeStatus: "get_dispute_status"
        case .branchHours: "branch_hours"
        case .interestEarned: "interest_earned"
        case .none: "none"
        }
    }

    /// The tool's parameters rendered for display.
    var argumentSummary: String? {
        switch self {
        case .listTransactions(let days): "days: \(days)"
        case .searchTransactions(let merchant): "merchant: \(merchant)"
        case .routingNumber(let account): "account: \(account)"
        case .accountNumber(let account): "account: \(account)"
        case .cardNumber(let card): "card: \(card)"
        case .bankStatement(let month, let account): "month: \(month), account: \(account)"
        case .creditScore: nil
        case .getLocation: nil
        case .findNearestBranch(let latitude, let longitude): "latitude: \(latitude), longitude: \(longitude)"
        case .findNearestATM(let latitude, let longitude): "latitude: \(latitude), longitude: \(longitude)"
        case .feesAndCharges(let account): "account: \(account)"
        case .accountBalance(let account): "account: \(account)"
        case .convertCurrency(let amount, let to): "amount: \(amount), to: \(to)"
        case .pendingPayments(let account): "account: \(account)"
        case .scheduledPayments(let account): "account: \(account)"
        case .cardLimits(let card): "card: \(card)"
        case .rewardPoints: nil
        case .disputeStatus(let merchant): "merchant: \(merchant)"
        case .branchHours(let branchID): "branchID: \(branchID)"
        case .interestEarned(let account): "account: \(account)"
        case .none: nil
        }
    }

    /// True when the plan says no on-device tool serves the request.
    var isNone: Bool {
        if case .none = self { return true }
        return false
    }
}
