import FoundationModels

// MARK: - Tool identity (single source of truth)
//
// On-device routing layer for a hybrid banking assistant:
//   • App tools = read-only GET operations the app executes directly
//     against the bank's APIs (the raw prompt never leaves the device;
//     only the structured API call does)
//   • sendToBackend = the request involves an action (POST), an uncovered
//     capability, or a MIX of the two — in all cases the FULL original
//     prompt is forwarded to the server-side assistant
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
    case findBranch(location: String)
    case findATM(location: String)
    case feesAndCharges(account: AccountType)
    case accountBalance(account: AccountType)
    case convertCurrency(amount: String, to: String)
    case pendingPayments(account: AccountType)
    case scheduledPayments(account: AccountType)
    case cardLimits(card: CardType)
    case rewardPoints
    case disputeStatus(merchant: String)
    case branchHours(branch: String)
    case interestEarned(account: AccountType)
    /// Escalation: the request (or a sub-task of it) can't be served locally
    /// and must be forwarded to the backend. Not a failure state.
    case sendToBackend(request: String)
}

@Generable
enum AccountType {
    case checking
    case savings
    case creditCard
    case all
}

@Generable
enum CardType {
    case debit
    case credit
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
        case .findBranch: "find_branch"
        case .findATM: "find_atm"
        case .feesAndCharges: "fees_and_charges"
        case .accountBalance: "account_balance"
        case .convertCurrency: "convert_currency"
        case .pendingPayments: "pending_payments"
        case .scheduledPayments: "scheduled_payments"
        case .cardLimits: "card_limits"
        case .rewardPoints: "reward_points"
        case .disputeStatus: "dispute_status"
        case .branchHours: "branch_hours"
        case .interestEarned: "interest_earned"
        case .sendToBackend: "send_to_backend"
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
        case .findBranch(let location): "location: \(location)"
        case .findATM(let location): "location: \(location)"
        case .feesAndCharges(let account): "account: \(account)"
        case .accountBalance(let account): "account: \(account)"
        case .convertCurrency(let amount, let to): "amount: \(amount), to: \(to)"
        case .pendingPayments(let account): "account: \(account)"
        case .scheduledPayments(let account): "account: \(account)"
        case .cardLimits(let card): "card: \(card)"
        case .rewardPoints: nil
        case .disputeStatus(let merchant): "merchant: \(merchant)"
        case .branchHours(let branch): "branch: \(branch)"
        case .interestEarned(let account): "account: \(account)"
        case .sendToBackend(let request): request
        }
    }

    var isSendToBackend: Bool {
        if case .sendToBackend = self { return true }
        return false
    }
}
