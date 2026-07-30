import Foundation

// MARK: - Bank API layer
//
// One function per read-only GET endpoint the app tools cover. Tools are
// thin wrappers that parse model arguments, call one of these functions,
// and hand the result back to the model as text.

protocol BankAPIClient: Sendable {
    func listTransactions(days: Int) async throws -> [Transaction]
    func searchTransactions(merchant: String) async throws -> [Transaction]
    func routingNumber(accountType: String) async throws -> String
    func accountNumber(accountType: String) async throws -> String
    func cardNumber(cardType: String) async throws -> String
    func bankStatement(month: String, accountType: String) async throws -> String
    func creditScore() async throws -> Int
    func currentLocation() async throws -> String
    func findBranches(near location: String) async throws -> [String]
    func findATMs(near location: String) async throws -> [String]
    func feesAndCharges(accountType: String) async throws -> [String]
    func accountBalance(accountType: String) async throws -> String
    func convertCurrency(amount: String, to currency: String) async throws -> String
    func pendingPayments(accountType: String) async throws -> [String]
    func scheduledPayments(accountType: String) async throws -> [String]
    func cardLimits(cardType: String) async throws -> String
    func rewardPoints() async throws -> Int
    func disputeStatus(merchant: String) async throws -> String
    func branchHours(branch: String) async throws -> String
    func interestEarned(accountType: String) async throws -> String
}
