import Foundation
import FoundationModels

// MARK: - The half that talks to the network
//
// Foundation Models splits a custom model in two: the MODEL is a value
// (cheap, copied, compared), the EXECUTOR holds the expensive parts and is
// built once per distinct `Configuration` and reused. So the URLSession
// lives here, not on `CustomLanguageModel` — which is why `Configuration`
// has to be `Hashable`: it is the cache key.
//
// One request, one response, one pass over the channel. The framework
// treats the channel as a stream, but nothing requires more than one
// event per entry — a single `appendText` with the whole reply is a
// complete, valid turn.

nonisolated struct CustomModelExecutor: LanguageModelExecutor {
    typealias Model = CustomLanguageModel

    nonisolated struct Configuration: Hashable, Sendable {
        var endpoint: CustomLanguageModel.Endpoint
        var credentials: CustomLanguageModel.Credentials
        var behavior: CustomLanguageModel.Behavior
        var timeout: TimeInterval
    }

    private let configuration: Configuration
    private let transport: any HTTPTransport

    init(configuration: Configuration) throws {
        self.init(
            configuration: configuration,
            transport: URLSessionTransport(timeout: configuration.timeout)
        )
    }

    /// Injects the transport so the request mapping and the response
    /// translation can be exercised without a gateway.
    init(configuration: Configuration, transport: any HTTPTransport) {
        self.configuration = configuration
        self.transport = transport
    }

    // MARK: Generating

    func respond(
        to request: LanguageModelExecutorGenerationRequest,
        model: CustomLanguageModel,
        streamingInto channel: LanguageModelExecutorGenerationChannel
    ) async throws {
        do {
            let body = try ChatRequestBuilder.build(
                from: request,
                endpoint: configuration.endpoint,
                behavior: configuration.behavior
            )
            let response = try await post(body)
            try await emit(response, into: channel)
        } catch {
            throw mapped(error)
        }
    }

    func prewarm(model: CustomLanguageModel, transcript: Transcript) {
        // Warms the token so its round trip lands before the first real
        // request rather than inside it. The prewarm contract has no way to
        // report a failure, so one is dropped here and surfaces on the
        // request that actually needs the token.
        guard let apigee = configuration.credentials.apigee else { return }
        Task { _ = try? await ApigeeTokenProvider.shared(for: apigee).token() }
    }

    // MARK: Transport

    private func post(_ body: ChatCompletionRequest) async throws -> ChatCompletionResponse {
        guard !configuration.credentials.apiKey.isEmpty
            || configuration.credentials.apigee != nil
        else { throw CustomModelError.missingCredential }

        let provider = await tokenProvider()
        let token = try await provider?.token()

        do {
            return try await send(body, bearerToken: token)
        } catch let error as CustomModelError {
            // A 401 on a token that looked valid means it was revoked, or
            // the gateway's clock disagrees with ours. Retry ONCE with a
            // fresh token; a second rejection is a real credential problem.
            //
            // Safe to retry blind because nothing has reached the channel
            // yet — the response is emitted only after this returns.
            guard case .http(401, _, _) = error, let provider else { throw error }
            await provider.invalidate(usedToken: token)
            return try await send(body, bearerToken: try await provider.token())
        }
    }

    private func send(
        _ body: ChatCompletionRequest,
        bearerToken: String?
    ) async throws -> ChatCompletionResponse {
        var request = URLRequest(url: configuration.endpoint.chatCompletionsURL)
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(body)
        for (field, value) in configuration.credentials.headers(bearerToken: bearerToken) {
            request.setValue(value, forHTTPHeaderField: field)
        }
        for (field, value) in configuration.behavior.extraHeaders {
            request.setValue(value, forHTTPHeaderField: field)
        }

        let (data, http) = try await transport.send(request)
        guard (200..<300).contains(http.statusCode) else {
            throw CustomModelError.http(
                status: http.statusCode,
                message: errorMessage(from: data),
                // FILL IN — whatever header your gateway echoes a trace id
                // in. Without one, a support ticket about a 500 has nothing
                // to point at.
                requestID: http.value(forHTTPHeaderField: "x-request-id")
            )
        }
        return try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
    }

    private func tokenProvider() async -> ApigeeTokenProvider? {
        guard let apigee = configuration.credentials.apigee else { return nil }
        return await ApigeeTokenProvider.shared(for: apigee)
    }

    /// Best-effort: the structured error envelope if there is one, the raw
    /// body if not.
    private func errorMessage(from data: Data) -> String {
        if let envelope = try? JSONDecoder().decode(ChatErrorResponse.self, from: data),
           let message = envelope.error?.message, !message.isEmpty {
            return message
        }
        let raw = String(data: data, encoding: .utf8) ?? ""
        return raw.isEmpty ? "<empty body>" : String(raw.prefix(500))
    }

    // MARK: Response → channel

    private func emit(
        _ response: ChatCompletionResponse,
        into channel: LanguageModelExecutorGenerationChannel
    ) async throws {
        guard let choice = response.choices.first else {
            throw CustomModelError.emptyResponse
        }
        if let refusal = choice.message.refusal, !refusal.isEmpty {
            throw LanguageModelError.refusal(
                .init(explanation: refusal, debugDescription: "The model declined to answer.")
            )
        }

        // One entry id per kind, fixed for this turn: every event below has
        // to land in the same transcript entry.
        let responseEntryID = UUID().uuidString
        let toolCallsEntryID = UUID().uuidString

        if let content = choice.message.content, !content.isEmpty {
            await channel.send(
                .response(
                    entryID: responseEntryID,
                    // A token count of 0 suppresses delivery of the partial
                    // snapshot, so the whole reply is billed as one token
                    // here. The authoritative numbers go through
                    // `updateUsage` below.
                    action: .appendText(content, tokenCount: 1)
                )
            )
        }

        for call in choice.message.toolCalls ?? [] {
            await channel.send(
                .toolCalls(
                    entryID: toolCallsEntryID,
                    action: .toolCall(
                        id: call.id,
                        name: call.function.name,
                        // A tool with no parameters can come back with empty
                        // arguments; the framework decodes this as JSON, and
                        // "" is not valid JSON.
                        action: .appendArguments(
                            call.function.arguments.isEmpty ? "{}" : call.function.arguments,
                            tokenCount: 1
                        )
                    )
                )
            )
        }

        guard let usage = response.usage else { return }
        await channel.send(
            .response(
                entryID: responseEntryID,
                action: .updateUsage(
                    input: .init(
                        totalTokenCount: usage.promptTokens ?? 0,
                        cachedTokenCount: usage.promptTokensDetails?.cachedTokens ?? 0
                    ),
                    output: .init(
                        totalTokenCount: usage.completionTokens ?? 0,
                        reasoningTokenCount: 0
                    )
                )
            )
        )
    }

    // MARK: Errors

    /// Maps gateway failures onto the framework's typed errors where an
    /// honest equivalent exists, so callers can pattern-match `rateLimited`
    /// and `contextSizeExceeded` regardless of which model produced them.
    /// Everything else surfaces as itself — inventing a category is worse
    /// than an accurate opaque error.
    private func mapped(_ error: any Error) -> any Error {
        if let url = error as? URLError, url.code == .timedOut {
            return LanguageModelError.timeout(.init(debugDescription: url.localizedDescription))
        }
        guard case .http(let status, let message, _) = error as? CustomModelError else {
            return error
        }
        switch status {
        case 429, 529:
            // No standard reset header across gateways; callers pick their
            // own backoff rather than being handed a fabricated date.
            return LanguageModelError.rateLimited(.init(resetDate: nil, debugDescription: message))
        case 400 where message.lowercased().contains("context")
            || message.lowercased().contains("too long"),
             413:
            // Neither the window nor the prompt's token count comes back on
            // this surface.
            return LanguageModelError.contextSizeExceeded(
                .init(contextSize: 0, tokenCount: 0, debugDescription: message)
            )
        default:
            return error
        }
    }
}
