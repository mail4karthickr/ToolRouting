import Foundation
import FoundationModels

// MARK: - A corporate OpenAI-compatible endpoint as a Foundation Model
//
// FICTIONAL IMPLEMENTATION. Every wire detail below — header names, the
// token grant, the response envelope — is a plausible guess at what a
// company gateway looks like, not a spec. The seams you will have to
// change are marked `FILL IN`; the shape around them is what Foundation
// Models requires and should not need to move.
//
// The point of conforming to `LanguageModel` rather than writing a
// bespoke client is that NOTHING ELSE IN THE APP CHANGES. A
// `LanguageModelSession(model:)` built on this runs the same tools, the
// same @Generable schemas, and the same judge prompts as the on-device
// model:
//
//     let model = CustomLanguageModel(endpoint: …, credentials: …)
//     let session = LanguageModelSession(model: model, tools: […])
//     let answer = try await session.respond(to: query, generating: Score.self)
//
// Two credentials, because that is what an Apigee-fronted gateway
// usually wants: a long-lived API key that identifies the APPLICATION,
// and a short-lived OAuth token that authorizes the CALL. The key is
// static config; the token is fetched, cached, and refreshed by
// ``ApigeeTokenProvider``.
//
// Requests are single-shot (`stream: false`). Every caller in this app —
// the router, the agent, the judge — awaits a whole response, so SSE
// would add a parser and a state machine for no behaviour anyone
// consumes. If you later want token-by-token UI, that change is confined
// to `CustomModelExecutor.respond`.

nonisolated struct CustomLanguageModel: Sendable {
    let endpoint: Endpoint
    let credentials: Credentials
    let behavior: Behavior
    let timeout: TimeInterval

    init(
        endpoint: Endpoint,
        credentials: Credentials,
        behavior: Behavior = Behavior(),
        timeout: TimeInterval = 120
    ) {
        self.endpoint = endpoint
        self.credentials = credentials
        self.behavior = behavior
        self.timeout = timeout
    }

    /// Idempotent. Fetches the Apigee token now so its latency — and, more
    /// usefully, its failure — surfaces at setup instead of inside the
    /// first generation. A no-op when no Apigee credentials are configured.
    func authenticateIfNeeded() async throws {
        guard let apigee = credentials.apigee else { return }
        _ = try await ApigeeTokenProvider.shared(for: apigee).token()
    }
}

// MARK: - Where to send it

extension CustomLanguageModel {
    nonisolated struct Endpoint: Hashable, Sendable {
        /// Gateway root, e.g. `https://api.mycompany.com/llm/v1`.
        var baseURL: URL
        /// Model name the gateway expects in the request body. This is the
        /// gateway's name for it ("gpt-4o", "internal-gpt-4o-2024"), not a
        /// vendor's.
        var modelID: String
        /// FILL IN — some gateways mount the OpenAI surface at the root
        /// (`/chat/completions`), some keep the version segment.
        var chatCompletionsPath: String = "/chat/completions"

        var chatCompletionsURL: URL {
            baseURL.appending(path: chatCompletionsPath)
        }

        init(baseURL: URL, modelID: String, chatCompletionsPath: String = "/chat/completions") {
            self.baseURL = baseURL
            self.modelID = modelID
            self.chatCompletionsPath = chatCompletionsPath
        }
    }
}

// MARK: - What it takes to get in

extension CustomLanguageModel {
    nonisolated struct Credentials: Hashable, Sendable {
        /// Static application key. Sent on every request under
        /// ``apiKeyHeader``.
        var apiKey: String
        /// FILL IN — Apigee deployments differ: `x-api-key`, `apikey`,
        /// `X-IBM-Client-Id`. Whatever your gateway rejects the request
        /// without.
        var apiKeyHeader: String = "x-api-key"
        /// Nil for a gateway that authorizes on the API key alone.
        var apigee: ApigeeCredentials?

        init(apiKey: String, apiKeyHeader: String = "x-api-key", apigee: ApigeeCredentials? = nil) {
            self.apiKey = apiKey
            self.apiKeyHeader = apiKeyHeader
            self.apigee = apigee
        }

        /// The full header set for one request.
        ///
        /// THE SEAM. If your gateway wants the token somewhere other than
        /// `Authorization: Bearer`, or wants a correlation ID, or wants the
        /// key as a query parameter — this is the only function that has to
        /// know.
        func headers(bearerToken: String?) -> [String: String] {
            var headers = [
                "Content-Type": "application/json",
                "Accept": "application/json",
            ]
            if !apiKey.isEmpty {
                headers[apiKeyHeader] = apiKey
            }
            if let bearerToken, !bearerToken.isEmpty {
                headers["Authorization"] = "Bearer \(bearerToken)"
            }
            return headers
        }
    }
}

// MARK: - What the gateway will and won't accept

extension CustomLanguageModel {
    /// Capability switches. These exist because "OpenAI-compatible" is a
    /// claim about the request shape, not a guarantee about the features —
    /// gateways routinely accept `tools` and reject `response_format`, or
    /// pin temperature and 400 on any sampling parameter. Each flag turns
    /// off one request field and, where possible, substitutes a prompt-level
    /// fallback, so a partial gateway degrades instead of failing.
    nonisolated struct Behavior: Hashable, Sendable {
        /// Send `tools` / `tool_choice`. Off means the model never sees the
        /// app's tools, so leave it on for anything but a judge.
        var supportsToolCalling: Bool = true

        /// Send `response_format: {type: "json_schema", strict: true}` for
        /// @Generable output. Off falls back to `{type: "json_object"}` with
        /// the schema pasted into the system prompt — same JSON, no decoding
        /// constraint, so the model can violate it and the framework's
        /// decode is what catches it.
        var supportsStructuredOutputs: Bool = true

        /// Send `temperature` / `top_p`. Off drops them; several gateways
        /// reject any value including the default.
        var supportsSampling: Bool = true

        /// FILL IN — newer OpenAI-compatible surfaces renamed this to
        /// `max_completion_tokens` and reject the old key.
        var usesMaxCompletionTokens: Bool = false

        /// Used when the caller sets no `maximumResponseTokens`. Judge
        /// responses are small; tool-calling turns are smaller.
        var defaultMaximumResponseTokens: Int = 4_096

        /// Anything else your gateway demands on every call — a tenant ID, a
        /// cost-center tag, a tracing header.
        var extraHeaders: [String: String] = [:]

        init(
            supportsToolCalling: Bool = true,
            supportsStructuredOutputs: Bool = true,
            supportsSampling: Bool = true,
            usesMaxCompletionTokens: Bool = false,
            defaultMaximumResponseTokens: Int = 4_096,
            extraHeaders: [String: String] = [:]
        ) {
            self.supportsToolCalling = supportsToolCalling
            self.supportsStructuredOutputs = supportsStructuredOutputs
            self.supportsSampling = supportsSampling
            self.usesMaxCompletionTokens = usesMaxCompletionTokens
            self.defaultMaximumResponseTokens = defaultMaximumResponseTokens
            self.extraHeaders = extraHeaders
        }
    }
}

// MARK: - LanguageModel conformance

// `nonisolated` because the target defaults to MainActor isolation and the
// framework calls both of these off the main actor. Without it the
// conformance itself is main-actor-isolated, which is a warning today and a
// data race whenever Foundation Models resolves the model on its own queue.
nonisolated extension CustomLanguageModel: LanguageModel {
    typealias Executor = CustomModelExecutor

    /// Declared capabilities gate what the framework will even ask for, so
    /// they track ``Behavior`` rather than being optimistic — claiming
    /// `guidedGeneration` on a gateway that ignores schemas turns a clean
    /// "unsupported" into a decode failure at the end of a paid call.
    ///
    /// `.reasoning` is never claimed: reasoning-model summaries have no
    /// standard field on the chat-completions surface, and the framework's
    /// reasoning entries need a signature to replay.
    var capabilities: LanguageModelCapabilities {
        var capabilities: [LanguageModelCapabilities.Capability] = []
        if behavior.supportsToolCalling { capabilities.append(.toolCalling) }
        if behavior.supportsStructuredOutputs { capabilities.append(.guidedGeneration) }
        return LanguageModelCapabilities(capabilities)
    }

    var executorConfiguration: CustomModelExecutor.Configuration {
        .init(
            endpoint: endpoint,
            credentials: credentials,
            behavior: behavior,
            timeout: timeout
        )
    }
}

// MARK: - Failures

nonisolated enum CustomModelError: LocalizedError, Equatable {
    /// No API key configured — a request would 401 after a round trip.
    case missingCredential
    /// Non-2xx from the chat-completions endpoint.
    case http(status: Int, message: String, requestID: String?)
    /// 2xx with no `choices` — a gateway bug, or a filtered response.
    case emptyResponse
    /// The Apigee token endpoint refused or returned something unreadable.
    case tokenRequestFailed(status: Int, message: String)
    case malformedTokenResponse(String)

    var errorDescription: String? {
        switch self {
        case .missingCredential:
            "No API key configured for the custom language model endpoint."
        case .http(let status, let message, let requestID):
            requestID.map { "HTTP \(status) from the model gateway: \(message) (request id: \($0))" }
                ?? "HTTP \(status) from the model gateway: \(message)"
        case .emptyResponse:
            "The model gateway returned no choices."
        case .tokenRequestFailed(let status, let message):
            "Apigee token request failed with HTTP \(status): \(message)"
        case .malformedTokenResponse(let detail):
            "Apigee token response could not be read: \(detail)"
        }
    }
}
