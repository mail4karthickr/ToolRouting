import Foundation

@MainActor
final class MiniLMRouter {
    let strategyName = "MiniLM Embedding Router"

    struct Config {
        var similarityThreshold: Float = 0.45
    }

    private let embedder = MLXEmbedder()
    private let config = Config()
    private var indexTask: Task<ToolIndex, Error>?
    private var warmTask: Task<Void, Never>?

    struct RetrievedTool: Sendable {
        let toolName: String
        let score: Float
    }

    struct Retrieval: Sendable {
        let shortlist: [RetrievedTool]
        let ranked: [RetrievedTool]
    }

    var similarityThreshold: Float { config.similarityThreshold }

    // MARK: - Prewarm

    func prewarm() {
        _ = activeIndexTask()

        guard warmTask == nil else { return }
        let embedder = embedder
        warmTask = Task.detached(priority: .userInitiated) {
            try? await embedder.warm()
        }
    }

    // MARK: - Retrieval

    func retrieve(_ query: String, topK: Int = 4) async throws -> [RetrievedTool] {
        try await rank(query, topK: topK).shortlist
    }

    func rank(_ query: String, topK: Int = 4) async throws -> Retrieval {
        let index: ToolIndex
        do {
            index = try await activeIndexTask().value
        } catch {
            indexTask = nil
            throw error
        }

        guard let queryVector = try await embedder.embed([query]).first else {
            throw CancellationError()
        }

        var bestByTool: [String: Float] = [:]
        for entry in index.entries {
            let score = zip(entry.vector, queryVector).reduce(into: Float.zero) { $0 += $1.0 * $1.1 }
            bestByTool[entry.toolName] = max(bestByTool[entry.toolName] ?? -1, score)
        }

        let ranked = bestByTool
            .sorted { $0.value > $1.value }
            .map { RetrievedTool(toolName: $0.key, score: $0.value) }

        let shortlist = Array(ranked.filter { $0.score >= config.similarityThreshold }.prefix(topK))

        return Retrieval(shortlist: shortlist, ranked: ranked)
    }

    // MARK: - Index

    private func activeIndexTask() -> Task<ToolIndex, Error> {
        if let indexTask { return indexTask }
        let embedder = embedder
        let specs = ToolCatalog.all.map(\.routableSpec)
        let task = Task.detached(priority: .userInitiated) {
            try await ToolIndexStore.loadOrBuild(specs: specs, embedder: embedder)
        }
        indexTask = task
        return task
    }
}

// MARK: - Default parameters

extension ToolName {
    static func withDefaultArguments(named displayName: String, query: String) -> ToolName? {
        switch displayName {
        case "list_transactions": .listTransactions(days: 7)
        case "search_transactions":
            .searchTransactions(merchant: query, category: .all, account: .all)
        case "routing_number": .routingNumber
        case "account_number": .accountNumber(account: .checking)
        case "card_number": .cardNumber(card: .all)
        case "bank_statement": .bankStatement(month: "last month", account: .checking)
        case "credit_score": .creditScore
        case "get_location": .getLocation
        case "find_nearest_branch": .findNearestBranch(latitude: 0, longitude: 0)
        case "find_nearest_atm": .findNearestATM(latitude: 0, longitude: 0)
        case "fees_and_charges": .feesAndCharges(account: .all)
        case "account_balance": .accountBalance(account: .all)
        case "convert_currency": .convertCurrency(amount: query, to: "USD")
        case "pending_payments": .pendingPayments(account: .all)
        case "scheduled_payments": .scheduledPayments(account: .all)
        case "card_limits": .cardLimits(card: .all)
        case "reward_points": .rewardPoints
        case "get_dispute_status": .disputeStatus(merchant: "all")
        case "branch_hours": .branchHours(branchID: "")
        case "interest_earned": .interestEarned(account: .all)
        case "calculator": .calculator
        case "resolve_date_range": .resolveDateRange
        default: nil
        }
    }
}
