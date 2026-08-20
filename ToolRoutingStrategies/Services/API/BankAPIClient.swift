import Foundation

// MARK: - Bank API layer
//
// One function per read-only GET endpoint the app tools cover. Tools are
// thin wrappers that parse model arguments, call one of these functions,
// and hand the result back to the model as text.

protocol BankAPIClient: Sendable {
    func listTransactions(days: Int) async throws -> [Transaction]
    /// The one method on this protocol typed on the `@Generable` enums
    /// rather than the `String` they'd otherwise resolve to — every other
    /// method here takes `accountType`/`cardType` as `String` so a real,
    /// non-Swift bank API implementing this protocol never has to depend
    /// on `@Generable` types. `category`/`accountType` use `.all` for no
    /// filter.
    ///
    /// `startDate`/`endDate` are real, already-parsed, already-ordered
    /// `Date` values — `SearchTransactionsTool` is what turns the model's
    /// free-text `yyyy-MM-dd` arguments into these (with a corrective
    /// reply if parsing fails), so by the time a call reaches here there
    /// is nothing left to validate.
    func searchTransactions(
        merchant: String, category: TransactionCategory, accountType: AccountType,
        startDate: Date, endDate: Date
    ) async throws -> [Transaction]
    func routingNumber() async throws -> String
    func accountNumber(accountType: String) async throws -> String
    func cardNumber(cardType: String) async throws -> String
    func bankStatement(month: String, accountType: String) async throws -> String
    func creditScore() async throws -> Int
    func currentLocation() async throws -> DeviceLocation
    /// Coordinates only, and deliberately so: `get_location` is the sole
    /// source of them, which is what forces it to run first. A request
    /// naming a city or zip has no endpoint here and escalates.
    ///
    /// Each line LEADS WITH THE BRANCH ID, because `branchHours` takes one
    /// and this is the only call that hands them out.
    func findNearestBranches(latitude: Double, longitude: Double) async throws -> [String]
    /// Same contract as `findNearestBranches`, for the same reason.
    func findNearestATMs(latitude: Double, longitude: Double) async throws -> [String]
    func feesAndCharges(accountType: String) async throws -> [String]
    func accountBalance(accountType: String) async throws -> String
    func convertCurrency(amount: String, to currency: String) async throws -> String
    func pendingPayments(accountType: String) async throws -> [String]
    func scheduledPayments(accountType: String) async throws -> [String]
    func cardLimits(cardType: String) async throws -> String
    func rewardPoints() async throws -> Int
    func disputeStatus(merchant: String) async throws -> String
    /// Keyed by ID rather than name for the same reason the finders take
    /// coordinates: a name is something the model can guess, an ID is
    /// something it can only have got from `findNearestBranches`.
    func branchHours(branchID: String) async throws -> String
    func interestEarned(accountType: String) async throws -> String
}
