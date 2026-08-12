import Foundation

// MARK: - Mock Bank API
//
// Stands in for the bank's real GET APIs while the tools are being
// implemented one by one.

struct MockBankAPIClient: BankAPIClient {
    func listTransactions(days: Int) async throws -> [Transaction] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: .now) ?? .now
        return Self.transactions.filter { $0.date >= cutoff }
    }

    func searchTransactions(merchant: String) async throws -> [Transaction] {
        Self.transactions.filter { $0.merchant.localizedCaseInsensitiveContains(merchant) }
    }

    func routingNumber(accountType: String) async throws -> String {
        "011000000"
    }

    func accountNumber(accountType: String) async throws -> String {
        accountType.localizedCaseInsensitiveContains("sav") ? "4471 9082 7789" : "4471 9082 3341"
    }

    /// Same `all` case as `cardLimits`, for the same reason: this was a
    /// ternary where every non-"credit" value meant debit, so a request for
    /// every card number returned one card's.
    func cardNumber(cardType: String) async throws -> String {
        switch cardType.lowercased() {
        case let type where type.contains("credit"):
            return "5412 8834 1290 0044"
        case let type where type.contains("debit"):
            return "4532 7712 0034 9921"
        default:
            return "Debit: 4532 7712 0034 9921 · Credit: 5412 8834 1290 0044"
        }
    }

    /// An explicit `all`, like `accountBalance` and `cardLimits`.
    ///
    /// This used to interpolate whatever arrived straight into the
    /// sentence, so there was no value meaning "every account" — "the all
    /// account is ready" is not an answer. Faced with a question naming no
    /// account, the agent called the tool once per account instead, which
    /// its own instructions forbid. Giving the argument an `all` is what
    /// makes the single call possible.
    func bankStatement(month: String, accountType: String) async throws -> String {
        switch accountType.lowercased() {
        case let type where type.contains("sav"):
            return "The \(month) statement for the savings account is ready and available under Documents."
        case let type where type.contains("credit"):
            return "The \(month) statement for the credit card account is ready and available under Documents."
        case let type where type.contains("check"):
            return "The \(month) statement for the checking account is ready and available under Documents."
        default:
            return "The \(month) statements for the checking, savings and credit card accounts are all ready and available under Documents."
        }
    }

    func creditScore() async throws -> Int {
        742
    }

    func currentLocation() async throws -> DeviceLocation {
        DeviceLocation(
            latitude: 37.7749,
            longitude: -122.4194
        )
    }

    func findNearestATMs(latitude: Double, longitude: Double) async throws -> [String] {
        [
            "Market Square ATM — 0.1 mi, 24 h",
            "Main St Branch ATM — 0.4 mi, 24 h",
            "QuickCash Mart — 0.6 mi, until 11 pm"
        ]
    }

    func findNearestBranches(latitude: Double, longitude: Double) async throws -> [String] {
        Self.branches.map { "\($0.id) · \($0.name) — \($0.detail)" }
    }

    func feesAndCharges(accountType: String) async throws -> [String] {
        [
            "Monthly service fee: $12.00",
            "Overdraft fee: $34.00",
            "Domestic wire transfer: $25.00",
            "Out-of-network ATM: $3.00"
        ]
    }

    func accountBalance(accountType: String) async throws -> String {
        switch accountType.lowercased() {
        case let type where type.contains("sav"):
            return "Savings: $8,120.55"
        case let type where type.contains("credit"):
            return "Credit Card: $1,204.87 balance of a $10,000 limit"
        case let type where type.contains("check"):
            return "Checking: $2,340.12"
        default:
            return "Checking: $2,340.12 · Savings: $8,120.55 · Credit Card: $1,204.87 of $10,000 limit"
        }
    }

    func convertCurrency(amount: String, to currency: String) async throws -> String {
        // Returns the CONVERTED total, not just the rate. Handing back a
        // rate alone invites the model to do the multiplication itself,
        // which is how an unverifiable figure ends up in an answer about
        // someone's money.
        let rate = 0.92
        let digits = amount.filter { $0.isNumber || $0 == "." }
        guard let value = Double(digits) else {
            return "Could not read an amount from '\(amount)'."
        }
        let converted = (value * rate).formatted(.number.precision(.fractionLength(0...2)))
        return "\(amount) is \(converted) \(currency) at today's rate of \(rate) \(currency) per USD."
    }

    func pendingPayments(accountType: String) async throws -> [String] {
        [
            "Netflix — $15.49 (processing)",
            "PG&E Electricity — $96.40 (scheduled for the 1st)"
        ]
    }

    func scheduledPayments(accountType: String) async throws -> [String] {
        [
            "Rent transfer — $1,850 (scheduled for the 1st)",
            "Credit card autopay — statement balance (scheduled for the 5th)",
            "Gym membership — $45 (scheduled for the 12th)"
        ]
    }

    /// AN EXPLICIT `all`, like `accountBalance` above and unlike the ternary
    /// this replaced.
    ///
    /// That ternary was `contains("credit") ? credit : debit`, so every
    /// value that was not the word "credit" — including "all" — silently
    /// meant DEBIT. The agent asking for every limit got the debit pair
    /// back and answered "$1,000 and $3,000" to a customer holding a
    /// $10,000 credit limit. No error, no invented figure, just the
    /// requested number missing. See `CardType.all`.
    func cardLimits(cardType: String) async throws -> String {
        switch cardType.lowercased() {
        case let type where type.contains("credit"):
            return "Credit limit: $10,000 · Daily spending limit: $5,000"
        case let type where type.contains("debit"):
            return "Daily ATM withdrawal limit: $1,000 · Daily spending limit: $3,000"
        default:
            return "Credit limit: $10,000 · Daily spending limit: $5,000 · Daily ATM withdrawal limit: $1,000"
        }
    }

    func rewardPoints() async throws -> Int {
        18_420
    }

    /// Disputes that actually exist, keyed by merchant.
    ///
    /// One entry, deliberately: a customer with a dispute on every
    /// merchant they have ever paid is not a customer, and the point of
    /// this fixture is that MOST lookups come back empty.
    private static let openDisputes = [
        "amazon": "Dispute for the Amazon charge is under review; provisional credit issued on Jul 21."
    ]

    /// STILL DETERMINISTIC, NOW CONDITIONAL — and the distinction matters.
    ///
    /// This used to answer "under review; provisional credit issued" for
    /// ANY merchant, so asking about a shop the user had never disputed
    /// invented a dispute for them. In an app about someone's money that
    /// is the worst kind of mock: it makes a wrong tool call look like a
    /// complete, plausible answer, which is exactly what happened to eval
    /// sample 9 — a request to OPEN a dispute was answered with a
    /// confident status for one that was never raised.
    ///
    /// The fix is not randomness. Varying the reply per call would break
    /// the evals outright: HybridRouterTests compares every figure against
    /// MockGroundTruth (which calls this same method), and
    /// HybridRouterReliabilityTests exists to measure whether a run is
    /// reproducible at all. Moving data would make a score change
    /// meaningless. What was missing is that the answer should depend on
    /// the ARGUMENT — same input, same output; different input, different
    /// output.
    func disputeStatus(merchant: String) async throws -> String {
        let wanted = merchant.trimmingCharacters(in: .whitespaces).lowercased()

        if wanted.isEmpty || wanted == "all" {
            let every = Self.openDisputes.values.sorted()
            return every.isEmpty ? "No disputes on record." : every.joined(separator: "\n")
        }
        guard let dispute = Self.openDisputes.first(where: { wanted.contains($0.key) })?.value else {
            return "No dispute on record for \(merchant)."
        }
        return dispute
    }

    /// The branches this customer has near them, nearest first.
    ///
    /// The IDs are the point. `branchHours` takes one, and
    /// `findNearestBranches` is the only call that hands them out, so the
    /// chain holds for the same reason the coordinate pair holds it for
    /// the finders: a branch NAME is something a model can produce from
    /// the question alone, an ID is not.
    private static let branches: [(id: String, name: String, detail: String)] = [
        ("BR-4417", "Main St Branch", "0.4 mi, open until 5 pm"),
        ("BR-2290", "Market Square Branch", "1.2 mi, open until 6 pm"),
        ("BR-8801", "Airport Branch", "5.6 mi, open until 8 pm")
    ]

    /// Conditional on the ARGUMENT, like `disputeStatus` above and for the
    /// same reason: answering with plausible hours for an ID the bank
    /// never issued is how a skipped `find_nearest_branch` turns into a
    /// confident wrong answer instead of a visible failure.
    func branchHours(branchID: String) async throws -> String {
        let wanted = branchID.trimmingCharacters(in: .whitespaces).uppercased()
        guard let branch = Self.branches.first(where: { $0.id.uppercased() == wanted }) else {
            return "No branch has ID '\(branchID)'. Call find_nearest_branch first to get one."
        }
        return "\(branch.name) (\(branch.id)): Mon–Fri 9 am–5 pm, Sat 9 am–1 pm, closed Sunday."
    }

    func interestEarned(accountType: String) async throws -> String {
        "Savings earned $27.14 interest last month at 4.05% APY."
    }

    // MARK: Mock data

    private static let transactions: [Transaction] = {
        let calendar = Calendar.current

        func daysAgo(_ days: Int) -> Date {
            calendar.date(byAdding: .day, value: -days, to: .now) ?? .now
        }

        return [
            Transaction(date: daysAgo(0), merchant: "Starbucks", category: "Dining", account: "Checking", amount: -6.45),
            Transaction(date: daysAgo(1), merchant: "Amazon", category: "Shopping", account: "Credit Card", amount: -82.19),
            Transaction(date: daysAgo(1), merchant: "Shell Gas Station", category: "Gas", account: "Credit Card", amount: -48.30),
            Transaction(date: daysAgo(2), merchant: "Whole Foods Market", category: "Groceries", account: "Checking", amount: -114.62),
            Transaction(date: daysAgo(3), merchant: "Payroll — ACME Corp", category: "Income", account: "Checking", amount: 2450.00),
            Transaction(date: daysAgo(4), merchant: "Netflix", category: "Entertainment", account: "Credit Card", amount: -15.49),
            Transaction(date: daysAgo(5), merchant: "Monthly Service Fee", category: "Bank Fees", account: "Checking", amount: -12.00),
            Transaction(date: daysAgo(6), merchant: "Uber", category: "Transport", account: "Credit Card", amount: -23.75),
            Transaction(date: daysAgo(8), merchant: "Transfer to Savings", category: "Transfers", account: "Checking", amount: -500.00),
            Transaction(date: daysAgo(8), merchant: "Transfer from Checking", category: "Transfers", account: "Savings", amount: 500.00),
            Transaction(date: daysAgo(10), merchant: "Apple.com", category: "Subscriptions", account: "Credit Card", amount: -9.99),
            Transaction(date: daysAgo(12), merchant: "PG&E — Electricity", category: "Utilities", account: "Checking", amount: -96.40)
        ]
    }()
}
