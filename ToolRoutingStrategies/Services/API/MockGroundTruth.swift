import Foundation

// MARK: - Ground truth from the mock API
//
// Turns a routed plan into the text the tools would actually return, by
// calling MockBankAPIClient for real. This is what lets a GENERATED
// question have trustworthy expectations: a model can invent a plausible
// question, but it cannot know that the savings balance is $8,120.55 —
// only the API knows that, so the API is asked.
//
// The alternative, letting the generator write the expected figures
// itself, produces a dataset that agrees with a hallucination. A
// groundedness check against invented ground truth is worse than no
// check, because it reports success.
//
// Used by the synthetic-data CLI at authoring time and by the evals at
// grading time, so both see identical values.

enum MockGroundTruth {
    /// What the tools return for `plan`, concatenated in plan order.
    ///
    /// `arguments` runs parallel to `tools`; a missing or empty entry
    /// falls back to the tool's most common argument, which keeps a
    /// generated sample usable when the model omitted one.
    static func toolOutput(
        tools: [String],
        arguments: [String],
        client: any BankAPIClient = MockBankAPIClient()
    ) async -> String {
        var chunks: [String] = []
        for (index, tool) in tools.enumerated() {
            let argument = index < arguments.count ? arguments[index] : ""
            if let output = await output(for: tool, argument: argument, client: client) {
                chunks.append(output)
            }
        }
        return chunks.joined(separator: "\n")
    }

    /// Every distinct number appearing in `text`, normalized for
    /// comparison: "$8,120.55" and "8,120.55" both become "8,120.55".
    ///
    /// This is the vocabulary a grounded answer is allowed to draw on. An
    /// answer containing a number outside this set invented it.
    static func figures(in text: String) -> Set<String> {
        let pattern = /[0-9][0-9,]*(?:\.[0-9]+)?/
        return Set(
            text.matches(of: pattern)
                .map { String($0.output) }
                // The comma class is there for thousands separators, so
                // it also swallows sentence punctuation: "your score is
                // 742, and…" matches "742,". Left alone, every figure
                // followed by a comma would look invented.
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ",")) }
                // Bare single digits ("1 of 3", "for 7 days") are noise
                // rather than facts, and flagging them would drown the
                // signal in false positives.
                .filter { $0.count > 1 }
        )
    }

    // MARK: Per-tool

    private static func output(
        for tool: String,
        argument: String,
        client: any BankAPIClient
    ) async -> String? {
        do {
            switch tool {
            case "account_balance":
                return try await client.accountBalance(accountType: fallback(argument, "all"))
            case "routing_number":
                return "Routing number: \(try await client.routingNumber(accountType: fallback(argument, "checking")))"
            case "account_number":
                return "Account number: \(try await client.accountNumber(accountType: fallback(argument, "checking")))"
            case "card_number":
                return "Card number: \(try await client.cardNumber(cardType: fallback(argument, "debit")))"
            case "card_limits":
                return try await client.cardLimits(cardType: fallback(argument, "credit"))
            case "credit_score":
                return "Credit score: \(try await client.creditScore())"
            case "reward_points":
                return "\(try await client.rewardPoints().formatted()) reward points"
            case "interest_earned":
                return try await client.interestEarned(accountType: fallback(argument, "savings"))
            case "fees_and_charges":
                return try await client.feesAndCharges(accountType: fallback(argument, "all")).joined(separator: "\n")
            case "pending_payments":
                return try await client.pendingPayments(accountType: fallback(argument, "all")).joined(separator: "\n")
            case "scheduled_payments":
                return try await client.scheduledPayments(accountType: fallback(argument, "all")).joined(separator: "\n")
            case "bank_statement":
                return try await client.bankStatement(month: fallback(argument, "last month"), accountType: "checking")
            case "dispute_status":
                return try await client.disputeStatus(merchant: fallback(argument, "all"))
            case "branch_hours":
                return try await client.branchHours(branch: fallback(argument, "Main St"))
            case "get_location":
                return try await client.currentLocation()
            case "find_branch":
                return try await client.findBranches(near: fallback(argument, "current location")).joined(separator: "\n")
            case "find_atm":
                return try await client.findATMs(near: fallback(argument, "current location")).joined(separator: "\n")
            case "convert_currency":
                return try await client.convertCurrency(amount: fallback(argument, "$100"), to: "EUR")
            case "list_transactions":
                let days = Int(argument) ?? 7
                let transactions = try await client.listTransactions(days: days)
                return transactions.map(Self.line(for:)).joined(separator: "\n")
            case "search_transactions":
                let transactions = try await client.searchTransactions(merchant: fallback(argument, "Starbucks"))
                guard !transactions.isEmpty else { return nil }
                let total = transactions.reduce(Decimal.zero) { $0 + $1.amount }
                return transactions.map(Self.line(for:)).joined(separator: "\n")
                    + "\nTotal: \(total.formatted(.currency(code: "USD")))"
            // "none" and anything unrecognized have no output to derive.
            default:
                return nil
            }
        } catch {
            return nil
        }
    }

    private static func line(for transaction: Transaction) -> String {
        let amount = transaction.amount.formatted(.currency(code: "USD"))
        let date = transaction.date.formatted(.dateTime.month(.abbreviated).day())
        return "\(date) · \(transaction.merchant) · \(transaction.account) · \(amount)"
    }

    private static func fallback(_ argument: String, _ standIn: String) -> String {
        argument.trimmingCharacters(in: .whitespaces).isEmpty ? standIn : argument
    }
}
