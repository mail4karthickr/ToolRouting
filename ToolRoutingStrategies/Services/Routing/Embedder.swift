import Foundation
import MLX
import MLXEmbedders
import Tokenizers

// MARK: - Embedder abstraction
//
// Any sentence-embedding backend (MLX, NLEmbedding, …) the routers can
// score similarity with. `modelID` participates in the index fingerprint
// so swapping models invalidates persisted vectors automatically.

nonisolated protocol Embedder: Sendable {
    var modelID: String { get }
    var dimension: Int { get }
    /// Embeds each text into an L2-normalized vector, so cosine
    /// similarity reduces to a plain dot product.
    func embed(_ texts: [String]) async throws -> [[Float]]
    /// Pays the model's one-time startup cost now instead of inside the
    /// first real request. See the MLX implementation for why building
    /// the index is not enough to cover this.
    func warm() async throws
}

extension Embedder {
    /// Backends with no startup cost need not implement it.
    func warm() async throws {}
}

// MARK: - MLX implementation
//
// all-MiniLM-L6-v2 (384-d, ~23M params): the small bi-encoder end of the
// quality/latency curve — upgrade (e.g. bge_small) only if Recall@k
// evidence from the eval demands it. Weights download from the Hub on
// first use and are cached by the Hub layer afterwards.
//
// MLX needs Apple-silicon Metal: run on device or a Mac, not the
// iOS simulator.

actor MLXEmbedder: Embedder {
    nonisolated let modelID = "sentence-transformers/all-MiniLM-L6-v2"
    nonisolated let dimension = 384

    private let configuration: MLXEmbedders.ModelConfiguration = .minilm_l6
    private var container: MLXEmbedders.ModelContainer?
    /// The load in flight, so concurrent callers share one.
    private var loading: Task<MLXEmbedders.ModelContainer, Error>?

    /// Loads the model once, even when several callers ask at once.
    ///
    /// The task matters because an actor is REENTRANT at every `await`:
    /// with a plain `if container == nil` check, a prewarm and a fast
    /// first question would both see nil, both call
    /// `loadModelContainer`, and pay the cost twice — which is exactly
    /// the situation prewarming creates.
    private func loadedContainer() async throws -> MLXEmbedders.ModelContainer {
        if let container { return container }
        if let loading {
            Log.embedder.debug("joining the load already in flight")
            return try await loading.value
        }

        // The one multi-second cost in Stage 1, and the one that decides
        // whether prewarming worked: this line appearing DURING a request
        // rather than at launch is the whole diagnosis.
        Log.embedder.info("loading \(modelID) (downloads from the Hub on first use)")
        let clock = ContinuousClock()
        let start = clock.now

        let configuration = configuration
        let task = Task { try await MLXEmbedders.loadModelContainer(configuration: configuration) }
        loading = task
        defer { loading = nil }

        do {
            let loaded = try await task.value
            container = loaded
            Log.embedder.info("model loaded in \((clock.now - start).logged)")
            return loaded
        } catch {
            Log.embedder.error("model load FAILED after \((clock.now - start).logged): \(error)")
            throw error
        }
    }

    /// Loads the weights AND runs one forward pass.
    ///
    /// Both halves are needed. `loadModelContainer` maps the weights and
    /// builds the tokenizer; the first inference is what compiles the
    /// Metal pipelines, and on device that is the larger share. Warming
    /// with a load alone would move a couple of seconds and leave the
    /// rest in the user's first question.
    ///
    /// Worth being explicit about why the index build does not already
    /// cover this: `ToolIndexStore.loadOrBuild` returns straight from the
    /// on-disk cache whenever the catalog is unchanged, and that path
    /// never calls `embed`. So on every launch after the first — the
    /// common case — the model stayed unloaded until the user asked
    /// something, and the whole cost landed on Stage 1 of their first
    /// request.
    func warm() async throws {
        _ = try await embed(["warm up"])
    }

    func embed(_ texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        let clock = ContinuousClock()
        let start = clock.now
        let container = try await loadedContainer()
        let loaded = clock.now

        defer {
            // Two numbers, because they answer different questions: a
            // slow embed is Metal work to tune, a slow load is a cold
            // model that prewarm was supposed to have paid for.
            Log.embedder.debug("""
                embed \(texts.count) text(s): wait \((loaded - start).logged), \
                forward \((clock.now - loaded).logged)
                """)
        }

        return await container.perform { (model: EmbeddingModel, tokenizer: Tokenizer, pooling: Pooling) -> [[Float]] in
            let encoded = texts.map { tokenizer.encode(text: $0, addSpecialTokens: true) }
            let maxLength = encoded.map(\.count).max() ?? 1
            let padID = tokenizer.eosTokenId ?? 0

            let padded = stacked(encoded.map { tokens in
                MLXArray(tokens + Array(repeating: padID, count: maxLength - tokens.count))
            })
            let mask = (padded .!= padID)
            let tokenTypes = MLXArray.zeros(like: padded)

            let pooled = pooling(
                model(padded, positionIds: nil, tokenTypeIds: tokenTypes, attentionMask: mask),
                normalize: true,
                applyLayerNorm: true
            )
            pooled.eval()
            return pooled.map { $0.asArray(Float.self) }
        }
    }

    /// Memory-pressure hook: drops the loaded model; the next embed
    /// reloads it from the on-disk cache.
    func unload() {
        container = nil
        loading?.cancel()
        loading = nil
    }
}
