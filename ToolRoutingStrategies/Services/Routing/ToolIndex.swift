import CryptoKit
import Foundation

// MARK: - Routable tool spec
//
// The embedding-relevant slice of a tool: what gets embedded into the
// index. Built from ToolCatalog only — real tools. "No match" has no
// text to embed, so the retrieval stage expresses it as a threshold
// abstention and the LLM stage expresses it as `none`.

nonisolated struct RoutableToolSpec: Sendable {
    let name: String
    let description: String
    let exampleQueries: [String]

    /// One vector per text: the description plus each example query.
    /// Multi-vector max-similarity beats averaging everything into one
    /// vector — a query only needs to be close to ONE way of asking.
    /// `notFor` is deliberately NOT embedded: negative examples would
    /// attract exactly the queries the tool should repel.
    var embeddingTexts: [String] {
        [description] + exampleQueries
    }
}

extension ToolDefinition {
    var routableSpec: RoutableToolSpec {
        RoutableToolSpec(name: displayName, description: description, exampleQueries: exampleQueries)
    }
}

// MARK: - Tool index
//
// Precomputed vectors over all routable specs. No vector database: at
// ~20 tools × a handful of texts × 384 dims, brute-force dot product is
// well under a millisecond.

nonisolated struct ToolIndex: Codable, Sendable {
    struct Entry: Codable, Sendable {
        let toolName: String
        let text: String
        let vector: [Float]
    }

    let fingerprint: String
    let entries: [Entry]
}

// MARK: - Store (build + persistence)

nonisolated enum ToolIndexStore {
    /// Loads the persisted index when its fingerprint still matches the
    /// specs and embedder; otherwise rebuilds and persists. The
    /// fingerprint covers every embedded text plus the model ID, so any
    /// catalog edit, spec change, or embedder swap invalidates the cache.
    static func loadOrBuild(specs: [RoutableToolSpec], embedder: any Embedder) async throws -> ToolIndex {
        let fingerprint = fingerprint(specs: specs, modelID: embedder.modelID)
        let url = cacheURL(fingerprint: fingerprint)

        if let data = try? Data(contentsOf: url),
           let cached = try? JSONDecoder().decode(ToolIndex.self, from: data),
           cached.fingerprint == fingerprint {
            return cached
        }

        // A miss on a launch that should have hit is the thing to catch
        // here: the fingerprint covers every embedded text plus the model
        // ID, so an unexpected rebuild means the catalog changed — or a
        // write failed last time and has been failing silently since.

        let texts = specs.flatMap(\.embeddingTexts)
        let names = specs.flatMap { spec in spec.embeddingTexts.map { _ in spec.name } }
        let vectors = try await embedder.embed(texts)

        let index = ToolIndex(
            fingerprint: fingerprint,
            entries: zip(zip(names, texts), vectors).map { pair, vector in
                ToolIndex.Entry(toolName: pair.0, text: pair.1, vector: vector)
            }
        )

        // Best-effort cache: routing works fine without persistence — but
        // a write that keeps failing costs a full rebuild every launch,
        // and without this line the only symptom is a slow first request.
        do {
            let data = try JSONEncoder().encode(index)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        } catch {
        }

        return index
    }

    private static func fingerprint(specs: [RoutableToolSpec], modelID: String) -> String {
        let material = ([modelID] + specs.flatMap { [$0.name] + $0.embeddingTexts })
            .joined(separator: "\u{1F}")
        let digest = SHA256.hash(data: Data(material.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func cacheURL(fingerprint: String) -> URL {
        URL.applicationSupportDirectory
            .appending(path: "ToolRoutingIndex")
            .appending(path: "index-\(fingerprint.prefix(16)).json")
    }
}
