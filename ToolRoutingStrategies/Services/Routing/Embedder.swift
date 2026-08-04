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

    private func loadedContainer() async throws -> MLXEmbedders.ModelContainer {
        if let container { return container }
        let loaded = try await MLXEmbedders.loadModelContainer(configuration: configuration)
        container = loaded
        return loaded
    }

    func embed(_ texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        let container = try await loadedContainer()

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
    }
}
