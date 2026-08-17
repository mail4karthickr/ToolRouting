import CryptoKit
import Foundation

// MARK: - Routable tool spec

nonisolated struct RoutableToolSpec: Sendable {
    let name: String
    let description: String
    let exampleQueries: [String]

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
    static func loadOrBuild(specs: [RoutableToolSpec], embedder: any Embedder) async throws -> ToolIndex {
        let fingerprint = fingerprint(specs: specs, modelID: embedder.modelID)
        let url = cacheURL(fingerprint: fingerprint)

        if let data = try? Data(contentsOf: url),
           let cached = try? JSONDecoder().decode(ToolIndex.self, from: data),
           cached.fingerprint == fingerprint {
            return cached
        }

        let texts = specs.flatMap(\.embeddingTexts)
        let names = specs.flatMap { spec in spec.embeddingTexts.map { _ in spec.name } }
        let vectors = try await embedder.embed(texts)

        let index = ToolIndex(
            fingerprint: fingerprint,
            entries: zip(zip(names, texts), vectors).map { pair, vector in
                ToolIndex.Entry(toolName: pair.0, text: pair.1, vector: vector)
            }
        )

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
