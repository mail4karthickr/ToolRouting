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

    func cardNumber(cardType: String) async throws -> String {
        cardType.localizedCaseInsensitiveContains("credit") ? "5412 8834 1290 0044" : "4532 7712 0034 9921"
    }

    func bankStatement(month: String, accountType: String) async throws -> String {
        "The \(month) statement for the \(accountType) account is ready and available under Documents."
    }

    func creditScore() async throws -> Int {
        742
    }

    func currentLocation() async throws -> String {
        "Market Square, San Francisco, CA 94103"
    }

    func findATMs(near location: String) async throws -> [String] {
        [
            "Market Square ATM — 0.1 mi, 24 h",
            "Main St Branch ATM — 0.4 mi, 24 h",
            "QuickCash Mart — 0.6 mi, until 11 pm"
        ]
    }

    func findBranches(near location: String) async throws -> [String] {
        [
            "Main St Branch — 0.4 mi, open until 5 pm",
            "Market Square Branch — 1.2 mi, open until 6 pm",
            "Airport Branch — 5.6 mi, open until 8 pm"
        ]
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

    func cardLimits(cardType: String) async throws -> String {
        cardType.localizedCaseInsensitiveContains("credit")
            ? "Credit limit: $10,000 · Daily spending limit: $5,000"
            : "Daily ATM withdrawal limit: $1,000 · Daily spending limit: $3,000"
    }

    func rewardPoints() async throws -> Int {
        18_420
    }

    func disputeStatus(merchant: String) async throws -> String {
        "Dispute for the \(merchant) charge is under review; provisional credit issued on Jul 21."
    }

    func branchHours(branch: String) async throws -> String {
        "\(branch) branch: Mon–Fri 9 am–5 pm, Sat 9 am–1 pm, closed Sunday."
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
