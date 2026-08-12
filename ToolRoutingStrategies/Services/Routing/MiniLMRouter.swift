import Foundation

// MARK: - Sample 2: Embedding-based routing (MLX / MiniLM)
//
// Pure semantic retrieval: the query and every tool's texts live in the
// same embedding space, and routing is a nearest-neighbor lookup. No
// generation happens at all — so routing is fast and deterministic, but
// the router can only CLASSIFY: it cannot extract parameters, decompose
// multi-step requests, or order dependent chains. Those limits are the
// point of this sample — the eval quantifies them, and the hybrid
// (retrieval → LLM) sample addresses them.

@MainActor
final class MiniLMRouter: ToolRouter {
    let strategyName = "MiniLM Embedding Router"

    struct Config {
        /// Below this best-match similarity the router ABSTAINS — the
        /// embedding stage's only "none of the above" mechanism (an
        /// embedding model can't understand an escalation class; "none"
        /// as an explicit option belongs to LLM-based selection).
        /// Calibrated against the eval per design doc §6.5 — tune with
        /// evidence, not vibes.
        var similarityThreshold: Float = 0.45
    }

    private let embedder = MLXEmbedder()
    private let config = Config()
    private var indexTask: Task<ToolIndex, Error>?
    private var warmTask: Task<Void, Never>?

    // MARK: Index

    private func activeIndexTask() -> Task<ToolIndex, Error> {
        if let indexTask { return indexTask }
        let embedder = embedder
        let specs = ToolCatalog.all.map(\.routableSpec)
        Log.stage1.info("index task started for \(specs.count) tools, \(specs.flatMap(\.embeddingTexts).count) texts")
        let task = Task.detached(priority: .userInitiated) {
            try await ToolIndexStore.loadOrBuild(specs: specs, embedder: embedder)
        }
        indexTask = task
        return task
    }

    /// Kicks off the model download / index build ahead of the first
    /// request. Idempotent; a failed build is retried on the next route.
    ///
    /// TWO tasks, not one, and the second is the one that matters in
    /// practice. Building the index only loads the embedding model when
    /// there is no cached index to read — so from the second launch
    /// onwards the index task returns in milliseconds having touched
    /// nothing, and the model was still cold when the user asked their
    /// first question. That is where a measured 6.4s Stage 1 came from,
    /// once per launch, on a stage whose steady-state cost is ~20ms.
    ///
    /// They run concurrently because they are independent: the index task
    /// reads a file, the warm task loads weights. On a first-ever launch
    /// both want the model and the embedder's own load task dedupes them.
    func prewarm() {
        _ = activeIndexTask()

        guard warmTask == nil else { return }
        let embedder = embedder
        // Failure is dropped on purpose: this is an optimisation, and a
        // model that could not be warmed will be loaded — and its error
        // reported — by the request that actually needs it.
        //
        // Logged even so, and at `warning`: a warm that quietly failed is
        // exactly what a 6-second first Stage 1 looks like from outside.
        warmTask = Task.detached(priority: .userInitiated) {
            let clock = ContinuousClock()
            let start = clock.now
            do {
                try await embedder.warm()
                Log.stage1.info("embedder warm ✓ \((clock.now - start).logged)")
            } catch {
                Log.stage1.warning("embedder warm failed after \((clock.now - start).logged): \(error)")
            }
        }
    }

    // MARK: Retrieval (Stage 1 of the hybrid; article's `retrieve_candidates`)

    /// A tool surfaced by similarity search, with its confidence.
    struct RetrievedTool: Sendable {
        let toolName: String
        let score: Float
    }

    /// The shortlist plus the full ranking behind it.
    struct Retrieval: Sendable {
        /// What Stage 2 gets to see.
        let shortlist: [RetrievedTool]
        /// EVERY tool in the index, ranked — including the ones that lost.
        /// Retrieval is the pipeline's recall ceiling, and a tool missing
        /// from the shortlist is unrecoverable downstream, so the losers
        /// are the diagnostic: a near miss is a threshold to tune, an
        /// also-ran at 0.2 is a tool description to rewrite.
        let ranked: [RetrievedTool]
    }

    /// The similarity floor a tool must clear to be shortlisted.
    var similarityThreshold: Float { config.similarityThreshold }

    /// Threshold-filtered top-k tools by similarity. The result is a
    /// SHORTLIST ranked by score — never an execution plan: ordering,
    /// dependencies, and multi-tool composition belong to the LLM stage.
    /// An empty result is the abstention signal ("NO MATCH": nothing
    /// cleared the threshold).
    func retrieve(_ query: String, topK: Int = 4) async throws -> [RetrievedTool] {
        try await rank(query, topK: topK).shortlist
    }

    /// `retrieve`, keeping the tools it discarded. Same work, same
    /// scores — only the reporting differs, so the shortlist a caller
    /// gets here is identical to the one `retrieve` would return.
    func rank(_ query: String, topK: Int = 4) async throws -> Retrieval {
        let clock = ContinuousClock()
        let start = clock.now

        let index: ToolIndex
        do {
            index = try await activeIndexTask().value
        } catch {
            indexTask = nil // e.g. offline during first model download — retry next time
            Log.stage1.error("index unavailable after \((clock.now - start).logged): \(error)")
            throw error
        }
        let indexReady = clock.now

        guard let queryVector = try await embedder.embed([query]).first else {
            Log.stage1.error("query embedding cancelled")
            throw CancellationError()
        }
        let embedded = clock.now

        // Score per tool = max dot product over its entries (vectors are
        // normalized, so dot product IS cosine similarity).
        var bestByTool: [String: Float] = [:]
        for entry in index.entries {
            let score = zip(entry.vector, queryVector).reduce(into: Float.zero) { $0 += $1.0 * $1.1 }
            bestByTool[entry.toolName] = max(bestByTool[entry.toolName] ?? -1, score)
        }

        let ranked = bestByTool
            .sorted { $0.value > $1.value }
            .map { RetrievedTool(toolName: $0.key, score: $0.value) }

        let shortlist = Array(ranked.filter { $0.score >= config.similarityThreshold }.prefix(topK))

        // The split matters when Stage 1 is slow: waiting on the index
        // (a first-launch build, or weights still downloading) and
        // embedding the query are seconds and milliseconds respectively,
        // and only one of them is fixable by tuning this stage.
        Log.stage1.debug("""
            rank: index \((indexReady - start).logged), embed \((embedded - indexReady).logged), \
            score \((clock.now - embedded).logged) over \(index.entries.count) vectors
            """)
        // The FULL ranking, losers included, at debug. This is the recall
        // ceiling for the request: whatever is missing here cannot be
        // recovered downstream, and a tool sitting just below the cut is
        // the difference between a threshold to tune and a description to
        // rewrite.
        Log.stage1.debug("""
            ranked (cut \(config.similarityThreshold), topK \(topK)): \
            \(ranked.map { "\($0.toolName)=\(String(format: "%.3f", $0.score))" }.joined(separator: " "))
            """)

        if shortlist.isEmpty {
            Log.stage1.warning("shortlist EMPTY — best \(ranked.first.map { "\($0.toolName)=\(String(format: "%.3f", $0.score))" } ?? "none")")
        }

        return Retrieval(shortlist: shortlist, ranked: ranked)
    }

    // MARK: Routing

    /// Article-exact selection (argmax-or-none): similarity search is a
    /// one-shot CLASSIFIER — top-1 tool, or abstain (empty calls) when
    /// nothing clears the threshold. What to do with an abstain (e.g.
    /// forward to the backend) is the caller's policy, not the router's.
    func route(_ query: String) async throws -> RoutingResult {
        guard let best = try await retrieve(query, topK: 1).first,
              let tool = ToolName.withDefaultArguments(named: best.toolName, query: query)
        else {
            return RoutingResult(strategyName: strategyName, reasoning: nil, calls: [])
        }

        return RoutingResult(
            strategyName: strategyName,
            reasoning: nil, // embedding routers classify; they cannot generate
            calls: [RoutedCall(tool: tool, confidence: Double(best.score))]
        )
    }
}

// MARK: - Default parameters

extension ToolName {
    /// Embedding routers select a tool but cannot extract its parameters
    /// from the request — that's the LLM's job in the hybrid sample.
    /// Neutral defaults keep the routed call renderable and executable;
    /// free-text arguments fall back to the raw query.
    static func withDefaultArguments(named displayName: String, query: String) -> ToolName? {
        switch displayName {
        case "list_transactions": .listTransactions(days: 7)
        case "search_transactions": .searchTransactions(merchant: query)
        case "routing_number": .routingNumber(account: .checking)
        case "account_number": .accountNumber(account: .checking)
        case "card_number": .cardNumber(card: .all)
        case "bank_statement": .bankStatement(month: "last month", account: .checking)
        case "credit_score": .creditScore
        case "get_location": .getLocation
        // The embedding router selects names without arguments, so these
        // are placeholder pairs that keep the call renderable — the
        // hybrid path gets real coordinates from get_location instead.
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
        // Placeholder, like the coordinate pairs above: the embedding
        // router names tools without arguments, and a real ID only exists
        // once find_nearest_branch has run.
        case "branch_hours": .branchHours(branchID: "")
        case "interest_earned": .interestEarned(account: .all)
        // No case for "none": the index only holds real tools, so an
        // unrecognized name means abstain (nil → empty calls → cloud).
        default: nil
        }
    }
}
