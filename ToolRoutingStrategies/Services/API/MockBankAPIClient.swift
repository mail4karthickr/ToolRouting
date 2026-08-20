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

    /// `startDate`/`endDate` arrive already parsed and already ordered —
    /// see the note on `BankAPIClient.searchTransactions`.
    func searchTransactions(
        merchant: String, category: TransactionCategory, accountType: AccountType,
        startDate: Date, endDate: Date
    ) async throws -> [Transaction] {
        let category = category.apiValue
        let accountType = accountType.apiValue

        return Self.transactions.filter { transaction in
            transaction.merchant.localizedCaseInsensitiveContains(merchant)
                && (category == "all" || transaction.category.caseInsensitiveCompare(category) == .orderedSame)
                && (accountType == "all" || transaction.account.caseInsensitiveCompare(accountType) == .orderedSame)
                && transaction.date >= startDate && transaction.date <= endDate
        }
    }

    func routingNumber() async throws -> String {
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
            return "Your debit card number is 4532 7712 0034 9921 and your credit card number is 5412 8834 1290 0044."
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
            return "Your \(month) statement for the savings account is ready and available under Documents."
        case let type where type.contains("credit"):
            return "Your \(month) statement for the credit card account is ready and available under Documents."
        case let type where type.contains("check"):
            return "Your \(month) statement for the checking account is ready and available under Documents."
        default:
            return "Your \(month) statements for the checking, savings and credit card accounts are all ready and available under Documents."
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

    /// PROSE, NOT AN ABBREVIATED ROW. These read
    /// `Market Square ATM — 0.1 mi, 24 h` until 2026-08-13, and the model
    /// reproduced them exactly that way: "The closest ATM is Market
    /// Square ATM — 0.1 mi, 24 h. Also nearby: …", scored Naturalness 3
    /// for "reproduces the lookup result verbatim, dash-separated list
    /// and all". A row written the way a person says it is one a reply
    /// can use unchanged; `0.1 mi, 24 h` is not something anyone says.
    ///
    /// Same distances, same hours.
    func findNearestATMs(latitude: Double, longitude: Double) async throws -> [String] {
        [
            "Market Square ATM, 0.1 miles away and open 24 hours",
            "Main St Branch ATM, 0.4 miles away and open 24 hours",
            "QuickCash Mart, 0.6 miles away and open until 11 pm"
        ]
    }

    /// Nearest first, each row naming the branch before its ID.
    ///
    /// The ID leads nowhere in a reply and everywhere in the chain: it is
    /// what `branch_hours` takes, so it has to be here, but a row opening
    /// `BR-4417 ·` puts an internal identifier at the front of the one
    /// string the model is most likely to echo. In parentheses after the
    /// name it is still there to be copied into the next call and reads
    /// as a footnote rather than the subject — the same shape
    /// `branchHours` answers in.
    func findNearestBranches(latitude: Double, longitude: Double) async throws -> [String] {
        Self.branches.map { "\($0.name) (\($0.id)), \($0.detail)" }
    }

    /// CLAUSES, NOT LABELLED FIELDS — the last row-shaped payloads in the
    /// catalog, and they read as rows for the same reason
    /// `list_transactions` did: `Label: $amount` is a table cell, and a
    /// model handed table cells writes a table back.
    ///
    /// MEASURED, 2026-08-13. "What fees did I pay, what interest did I
    /// earn, and what's my savings balance?" came back as "you paid
    /// $12.00 for the monthly service fee, $34.00 for the overdraft
    /// fee, …" — every figure right, Naturalness 3 for reading as an
    /// enumeration rather than a reply. A clause can be dropped into a
    /// sentence as it stands; a field has to be rearranged into one, and
    /// rearranging is where a small model loses a qualifier.
    ///
    /// Same fees, same amounts. Only the shape of the string changed.
    func feesAndCharges(accountType: String) async throws -> [String] {
        [
            "a $12.00 monthly service fee",
            "a $34.00 overdraft fee",
            "a $25.00 domestic wire transfer fee",
            "a $3.00 out-of-network ATM fee"
        ]
    }

    /// SENTENCES, NOT A ROW OF FIELDS, and the figures are untouched.
    ///
    /// MEASURED, 2026-08-12. The `all` case returned
    /// `Checking: $2,340.12 · Savings: $8,120.55 · Credit Card: …` and the
    /// model pasted it into its reply middots and all — "Your balance is
    /// Checking: $2,340.12 · Savings: …", scored Naturalness 3 for reading
    /// "more like a data dump wrapped in a sentence than a person
    /// speaking". Same finding, and the same fix, as
    /// `ListTransactionsTool.summary`: a payload shaped like a table gets
    /// reproduced as a table, and no instruction reaches that reliably
    /// because the model is doing what the data looks like.
    ///
    /// Every amount is the amount it always was. What changed is the
    /// punctuation between them.
    /// SECOND PERSON, because the model writes back what it is given.
    ///
    /// MEASURED, 2026-08-13, on samples 20–39. These read "The credit
    /// limit is $10,000" and "Savings is $8,120.55", and the replies came
    /// back "The credit limit is $10,000, the daily spending limit is
    /// $5,000…" and "The monthly service fee was $12.00" — three
    /// Naturalness 3s in one batch, every rationale naming the same
    /// thing: "impersonal", "reads as a data readout rather than a direct
    /// answer to the customer". It is the customer's own money; the tool
    /// should say so, and then the reply says so for free.
    func accountBalance(accountType: String) async throws -> String {
        switch accountType.lowercased() {
        case let type where type.contains("sav"):
            return "Your savings balance is $8,120.55."
        case let type where type.contains("credit"):
            return "Your credit card balance is $1,204.87 of a $10,000 limit."
        case let type where type.contains("check"):
            return "Your checking balance is $2,340.12."
        default:
            return "Your checking balance is $2,340.12, your savings balance is $8,120.55, and your credit card balance is $1,204.87 of a $10,000 limit."
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

    /// Clauses, like the fees above.
    ///
    /// The PG&E row used to read "PG&E Electricity — $96.40 (scheduled
    /// for the 1st)" while sitting in the PENDING list, which is the
    /// wording that has cost sample 51 twice: an item labelled
    /// "scheduled" inside the pending list, next to a scheduled list
    /// saying the same word, is an invitation to report one as the other.
    /// The date is still here — it is real — but "due on the 1st" says it
    /// without borrowing the other list's name.
    func pendingPayments(accountType: String) async throws -> [String] {
        [
            "Netflix for $15.49",
            "PG&E Electricity for $96.40, due on the 1st"
        ]
    }

    func scheduledPayments(accountType: String) async throws -> [String] {
        [
            "a rent transfer of $1,850 on the 1st",
            "a credit card autopay for the statement balance on the 5th",
            "a gym membership of $45 on the 12th"
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
            return "Your credit limit is $10,000 and your daily spending limit is $5,000."
        case let type where type.contains("debit"):
            return "Your daily ATM withdrawal limit is $1,000 and your daily spending limit is $3,000."
        default:
            return "Your credit limit is $10,000, your daily spending limit is $5,000, and your daily ATM withdrawal limit is $1,000."
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
        ("BR-4417", "Main St Branch", "0.4 miles away and open until 5 pm"),
        ("BR-2290", "Market Square Branch", "1.2 miles away and open until 6 pm"),
        ("BR-8801", "Airport Branch", "5.6 miles away and open until 8 pm")
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
        // The ID was the ARGUMENT; echoing it back into the one string a
        // reply is built from is how "Main St Branch (BR-4417)" reached a
        // customer. The name identifies the branch to a person, and the
        // caller already knows the ID it passed in.
        return "The \(branch.name) is open 9 am to 5 pm Monday to Friday, "
            + "9 am to 1 pm on Saturday, and closed on Sunday."
    }

    func interestEarned(accountType: String) async throws -> String {
        "Your savings earned $27.14 in interest last month at 4.05% APY."
    }

    // MARK: Mock data

    /// Three months of recurring activity rather than the dozen-transaction
    /// snapshot this replaced, so a question spanning months — "compare my
    /// Starbucks spend over the last three months" — has real month-to-month
    /// variation to reason over instead of one data point.
    ///
    /// `day` offsets are chosen so the SAME slot repeats roughly a month
    /// apart (`n`, `n + 30`, `n + 60`) — recognizably "this month", "last
    /// month", "two months ago" — while `search_transactions` still returns
    /// every matching row regardless of date, unbounded. Amounts vary
    /// per-occurrence, by hand, rather than by any random source: this is
    /// grounding data other tests and MockGroundTruth compute expected
    /// figures FROM, so every figure needs to be exact and reproducible.
    private static let transactions: [Transaction] = {
        let calendar = Calendar.current

        func daysAgo(_ days: Int) -> Date {
            calendar.date(byAdding: .day, value: -days, to: .now) ?? .now
        }

        func txns(
            _ merchant: String, _ category: String, _ account: String,
            _ entries: [(day: Int, amount: Decimal)]
        ) -> [Transaction] {
            entries.map {
                Transaction(date: daysAgo($0.day), merchant: merchant, category: category, account: account, amount: $0.amount)
            }
        }

        // An array of groups, not a `+`-chained expression: Swift's type
        // checker choked on the chain ("unable to type-check this
        // expression in reasonable time") once enough merchants were
        // added, because every `+` re-opens overload resolution across
        // the whole accumulated expression. Each `txns(...)` call here
        // type-checks independently instead.
        let groups: [[Transaction]] = [
            txns("Payroll — ACME Corp", "Income", "Checking", [
                (3, 2450.00), (17, 2450.00), (33, 2450.00), (47, 2450.00), (63, 2450.00), (77, 2450.00)
            ]),
            txns("Starbucks", "Dining", "Checking", [
                (2, -6.45), (9, -5.90), (16, -7.10), (23, -6.75),
                (32, -6.20), (39, -5.50), (46, -7.05), (53, -6.60),
                (62, -6.85), (69, -5.95), (76, -7.20), (83, -6.40)
            ]),
            txns("Chipotle", "Dining", "Credit Card", [
                (5, -12.40), (19, -13.75), (35, -12.90), (49, -14.10), (65, -13.25), (79, -12.60)
            ]),
            txns("Sweetgreen", "Dining", "Credit Card", [(11, -14.85), (41, -15.20), (71, -14.50)]),
            txns("Shake Shack", "Dining", "Credit Card", [(24, -18.90), (54, -19.40), (84, -17.75)]),
            txns("Amazon", "Shopping", "Credit Card", [
                (1, -82.19), (20, -34.50), (31, -56.30), (50, -27.85), (61, -91.40), (80, -42.15)
            ]),
            txns("Walmart", "Shopping", "Checking", [
                (6, -58.20), (21, -73.45), (36, -64.10), (51, -49.75), (66, -70.90), (81, -55.30)
            ]),
            txns("Target", "Shopping", "Credit Card", [(13, -45.60), (43, -38.90), (73, -52.10)]),
            txns("Best Buy", "Shopping", "Credit Card", [(18, -249.99)]),
            txns("Whole Foods Market", "Groceries", "Checking", [
                (2, -114.62), (16, -98.30), (28, -121.45),
                (32, -105.80), (46, -110.25), (58, -99.60),
                (62, -118.90), (76, -102.40), (88, -107.15)
            ]),
            txns("Trader Joe's", "Groceries", "Checking", [
                (9, -64.30), (23, -58.75), (39, -61.20), (53, -55.90), (69, -63.45), (83, -59.80)
            ]),
            txns("Safeway", "Groceries", "Checking", [(14, -72.50), (44, -68.90), (74, -75.30)]),
            txns("Shell Gas Station", "Gas", "Credit Card", [
                (4, -48.30), (18, -52.10), (34, -45.75), (48, -50.90), (64, -49.60), (78, -53.25)
            ]),
            txns("Chevron", "Gas", "Credit Card", [(25, -46.80), (55, -44.20), (85, -47.90)]),
            txns("Uber", "Transport", "Credit Card", [
                (6, -23.75), (20, -18.40), (36, -21.90), (50, -16.75), (66, -25.30), (80, -19.60)
            ]),
            txns("Lyft", "Transport", "Credit Card", [(12, -15.20), (42, -17.85), (72, -14.60)]),
            txns("Netflix", "Entertainment", "Credit Card", [(4, -15.49), (34, -15.49), (64, -15.49)]),
            txns("Spotify", "Entertainment", "Credit Card", [(8, -10.99), (38, -10.99), (68, -10.99)]),
            txns("AMC Theatres", "Entertainment", "Credit Card", [(57, -32.50)]),
            txns("Apple.com", "Subscriptions", "Credit Card", [(10, -9.99), (40, -9.99), (70, -9.99)]),
            txns("iCloud+", "Subscriptions", "Credit Card", [(10, -2.99), (40, -2.99), (70, -2.99)]),
            txns("Adobe Creative Cloud", "Subscriptions", "Credit Card", [(15, -54.99), (45, -54.99), (75, -54.99)]),
            txns("PG&E — Electricity", "Utilities", "Checking", [(12, -96.40), (42, -89.75), (72, -104.20)]),
            txns("Comcast — Internet", "Utilities", "Checking", [(17, -79.99), (47, -79.99), (77, -79.99)]),
            txns("Monthly Service Fee", "Bank Fees", "Checking", [(5, -12.00), (35, -12.00), (65, -12.00)]),
            txns("Planet Fitness", "Health & Fitness", "Checking", [(7, -24.99), (37, -24.99), (67, -24.99)]),
            txns("CVS Pharmacy", "Health & Fitness", "Credit Card", [(19, -28.40), (49, -15.60), (79, -42.30)]),
            txns("Airbnb", "Travel", "Credit Card", [(55, -340.00)]),
            txns("Delta Airlines", "Travel", "Credit Card", [(56, -410.00)]),
            txns("Transfer to Savings", "Transfers", "Checking", [(8, -500.00), (38, -500.00), (68, -500.00)]),
            txns("Transfer from Checking", "Transfers", "Savings", [(8, 500.00), (38, 500.00), (68, 500.00)])
        ]
        return groups.flatMap { $0 }
    }()
}
