import Foundation
import MLX
import MLXEmbedders
import Tokenizers

// MARK: - Embedder abstraction

nonisolated protocol Embedder: Sendable {
    var modelID: String { get }
    var dimension: Int { get }
    func embed(_ texts: [String]) async throws -> [[Float]]
    func warm() async throws
}

extension Embedder {
    func warm() async throws {}
}

// MARK: - MLX implementation

actor MLXEmbedder: Embedder {
    nonisolated let modelID = "sentence-transformers/all-MiniLM-L6-v2"
    nonisolated let dimension = 384

    private let configuration: MLXEmbedders.ModelConfiguration = .minilm_l6
    private var container: MLXEmbedders.ModelContainer?
    private var loading: Task<MLXEmbedders.ModelContainer, Error>?

    private func loadedContainer() async throws -> MLXEmbedders.ModelContainer {
        if let container { return container }
        if let loading {
            return try await loading.value
        }

        let configuration = configuration
        let task = Task { try await MLXEmbedders.loadModelContainer(configuration: configuration) }
        loading = task
        defer { loading = nil }

        let loaded = try await task.value
        container = loaded
        return loaded
    }

    func warm() async throws {
        _ = try await embed(["warm up"])
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

    func unload() {
        container = nil
        loading?.cancel()
        loading = nil
    }
}
