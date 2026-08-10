/*
Locks the wire contract of CustomLanguageModel — the bridge that lets a
corporate OpenAI-compatible gateway stand in for Claude as the judge in
HybridRouterTests.

Nothing here talks to a network, and nothing here needs Apple
Intelligence or MLX: the transport is a protocol, and both halves of the
bridge are pure functions around it. That is the point of the split —
you can be sure the request is SHAPED right long before you have working
credentials to find out whether it is ACCEPTED.

What these cover, in the order the failures actually bite:

  the message array   role tagging, and the tool_call ↔ tool_call_id
                      pairing a gateway rejects the request without
  the schema          strict-mode JSON Schema, where the framework's own
                      encoding is invalid on the wire as-is
  the credentials     both of them, on the same request
  the 401 retry       a revoked token has to cost one retry, not the run

The fictional parts of the implementation — header names, the grant, the
error envelope — are exactly the parts these tests pin, so when you swap
in your company's real ones, a failure here tells you what moved.
*/

import Foundation
import FoundationModels
import Testing
@testable import ToolRoutingStrategies

// MARK: - Test doubles

/// Records every request and replays canned responses in order. The last
/// response repeats, so a test that only cares about the first call does
/// not have to enumerate the rest.
private final class StubTransport: HTTPTransport, @unchecked Sendable {
    struct Canned {
        var status: Int
        var body: String
    }

    private let lock = NSLock()
    private var responses: [Canned]
    private var _sent: [URLRequest] = []
    private var index = 0

    init(_ responses: [Canned]) {
        self.responses = responses
    }

    var sent: [URLRequest] {
        lock.withLock { _sent }
    }

    /// Non-async on purpose: `NSLock` is unavailable from an async context,
    /// so the whole critical section stays inside this call.
    private func record(_ request: URLRequest) -> Canned {
        lock.withLock {
            _sent.append(request)
            defer { index += 1 }
            return responses[min(index, responses.count - 1)]
        }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let canned = record(request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: canned.status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (Data(canned.body.utf8), response)
    }
}

private extension StubTransport.Canned {
    /// A minimal successful completion carrying `text`.
    static func reply(_ text: String) -> Self {
        .init(
            status: 200,
            body: """
                {"choices":[{"message":{"role":"assistant","content":"\(text)"},
                 "finish_reason":"stop"}],
                 "usage":{"prompt_tokens":11,"completion_tokens":3}}
                """
        )
    }

    static let token = Self(
        status: 200,
        body: #"{"access_token":"apigee-token-1","expires_in":3599,"token_type":"Bearer"}"#
    )

    static let unauthorized = Self(status: 401, body: #"{"error":{"message":"token expired"}}"#)
}

// MARK: - Fixtures

@Generable
private struct JudgeVerdict {
    @Guide(description: "1 through 4")
    var score: Int
    var rationale: String
}

private enum Fixture {
    static let endpoint = CustomLanguageModel.Endpoint(
        baseURL: URL(string: "https://gateway.example.com/llm/v1")!,
        modelID: "internal-gpt-4o"
    )

    static func request(
        transcript: Transcript,
        tools: [Transcript.ToolDefinition] = [],
        schema: GenerationSchema? = nil,
        options: GenerationOptions = GenerationOptions(),
        contextOptions: ContextOptions = ContextOptions()
    ) -> LanguageModelExecutorGenerationRequest {
        .init(
            id: UUID(),
            transcript: transcript,
            enabledTools: tools,
            schema: schema,
            generationOptions: options,
            contextOptions: contextOptions,
            metadata: [:]
        )
    }

    static func text(_ content: String) -> [Transcript.Segment] {
        [.text(.init(content: content))]
    }

    /// The request body as loose JSON, which is the only form worth
    /// asserting against — the test should fail when a KEY changes, not
    /// when a Swift property is renamed.
    static func body(_ request: ChatCompletionRequest) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(request))
    }
}

private extension JSONValue {
    subscript(key: String) -> JSONValue? {
        guard case .object(let fields) = self else { return nil }
        return fields[key]
    }

    var array: [JSONValue]? {
        guard case .array(let elements) = self else { return nil }
        return elements
    }

    var string: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }
}

// MARK: - Request mapping

@Suite("Custom language model — request")
struct ChatRequestBuilderTests {

    @Test("Instructions become the system message and lead the array")
    func instructionsBecomeSystem() throws {
        let transcript = Transcript(entries: [
            .instructions(.init(segments: Fixture.text("You are a judge."), toolDefinitions: [])),
            .prompt(.init(segments: Fixture.text("Score this answer."))),
        ])

        let body = try Fixture.body(
            ChatRequestBuilder.build(
                from: Fixture.request(transcript: transcript),
                endpoint: Fixture.endpoint,
                behavior: .init()
            )
        )

        let messages = try #require(body["messages"]?.array)
        #expect(messages.count == 2)
        #expect(messages[0]["role"]?.string == "system")
        #expect(messages[0]["content"]?.string == "You are a judge.")
        #expect(messages[1]["role"]?.string == "user")
        #expect(body["model"]?.string == "internal-gpt-4o")
    }

    /// The pairing a gateway 400s without: an assistant turn carrying
    /// `tool_calls`, immediately followed by a `tool` message quoting the
    /// same id.
    @Test("A tool call and its result stay paired by id")
    func toolCallsPairWithOutputs() throws {
        let arguments = try GeneratedContent(json: #"{"account":"checking"}"#)
        let transcript = Transcript(entries: [
            .prompt(.init(segments: Fixture.text("What is my balance?"))),
            .toolCalls(
                .init([
                    .init(id: "call_1", toolName: "get_balance", arguments: arguments)
                ])
            ),
            .toolOutput(
                .init(id: "call_1", toolName: "get_balance", segments: Fixture.text("$2,340.12"))
            ),
        ])

        let body = try Fixture.body(
            ChatRequestBuilder.build(
                from: Fixture.request(transcript: transcript),
                endpoint: Fixture.endpoint,
                behavior: .init()
            )
        )

        let messages = try #require(body["messages"]?.array)
        #expect(messages[1]["role"]?.string == "assistant")
        let calls = try #require(messages[1]["tool_calls"]?.array)
        #expect(calls[0]["id"]?.string == "call_1")
        #expect(calls[0]["function"]?["name"]?.string == "get_balance")
        // Arguments cross the wire as a JSON *string*, not an object.
        #expect(calls[0]["function"]?["arguments"]?.string?.contains("checking") == true)

        #expect(messages[2]["role"]?.string == "tool")
        #expect(messages[2]["tool_call_id"]?.string == "call_1")
        #expect(messages[2]["content"]?.string == "$2,340.12")
    }

    @Test("Tools are omitted entirely when the gateway cannot call them")
    func toolsOmittedWhenUnsupported() throws {
        let definition = Transcript.ToolDefinition(
            name: "get_balance",
            description: "Balances",
            parameters: JudgeVerdict.generationSchema
        )
        let transcript = Transcript(entries: [
            .prompt(.init(segments: Fixture.text("hello")))
        ])

        let withTools = try Fixture.body(
            ChatRequestBuilder.build(
                from: Fixture.request(transcript: transcript, tools: [definition]),
                endpoint: Fixture.endpoint,
                behavior: .init(supportsToolCalling: true)
            )
        )
        #expect(withTools["tools"]?.array?.count == 1)

        let withoutTools = try Fixture.body(
            ChatRequestBuilder.build(
                from: Fixture.request(transcript: transcript, tools: [definition]),
                endpoint: Fixture.endpoint,
                behavior: .init(supportsToolCalling: false)
            )
        )
        // Absent, not empty: an empty `tools` array is itself a 400 on some
        // gateways.
        #expect(withoutTools["tools"] == nil)
        #expect(withoutTools["tool_choice"] == nil)
    }

    /// Strict mode has two requirements the framework's own encoding does
    /// not meet, and both are silent 400s if missed.
    @Test("A @Generable schema is rewritten for a strict validator")
    func schemaIsSanitized() throws {
        let transcript = Transcript(entries: [
            .prompt(.init(segments: Fixture.text("Score it.")))
        ])

        let body = try Fixture.body(
            ChatRequestBuilder.build(
                from: Fixture.request(transcript: transcript, schema: JudgeVerdict.generationSchema),
                endpoint: Fixture.endpoint,
                behavior: .init(supportsStructuredOutputs: true)
            )
        )

        let format = try #require(body["response_format"])
        #expect(format["type"]?.string == "json_schema")
        let schema = try #require(format["json_schema"]?["schema"])

        guard case .bool(let closed)? = schema["additionalProperties"] else {
            Issue.record("additionalProperties was not set on the root object")
            return
        }
        #expect(closed == false)

        let names = schema["required"]?.array?.compactMap(\.string)
        let required = try #require(names)
        #expect(Set(required) == ["score", "rationale"])

        // Framework extension keys are a hard rejection, not a warning.
        #expect(schema["x-order"] == nil)
        #expect(schema["title"] == nil)
    }

    @Test("Without structured-output support the schema moves into the prompt")
    func schemaFallsBackToThePrompt() throws {
        let transcript = Transcript(entries: [
            .prompt(.init(segments: Fixture.text("Score it.")))
        ])

        let body = try Fixture.body(
            ChatRequestBuilder.build(
                from: Fixture.request(
                    transcript: transcript,
                    schema: JudgeVerdict.generationSchema,
                    contextOptions: .init(includeSchemaInPrompt: false)
                ),
                endpoint: Fixture.endpoint,
                behavior: .init(supportsStructuredOutputs: false)
            )
        )

        #expect(body["response_format"]?["type"]?.string == "json_object")
        // `includeSchemaInPrompt: false` is overridden here on purpose:
        // with no constrained decoding, the prompt is the ONLY thing
        // carrying the shape.
        let system = try #require(body["messages"]?.array?.first?["content"]?.string)
        #expect(system.contains("rationale"))
    }
}

// MARK: - Executor

@Suite("Custom language model — executor")
struct CustomModelExecutorTests {

    /// Drives one generation and hands back the requests the transport saw.
    /// The channel is drained concurrently because `send` is async — an
    /// un-consumed channel would park the executor mid-response.
    private static func run(
        transport: StubTransport,
        credentials: CustomLanguageModel.Credentials,
        behavior: CustomLanguageModel.Behavior = .init()
    ) async throws {
        let configuration = CustomModelExecutor.Configuration(
            endpoint: Fixture.endpoint,
            credentials: credentials,
            behavior: behavior,
            timeout: 30
        )
        let executor = CustomModelExecutor(configuration: configuration, transport: transport)
        let model = CustomLanguageModel(
            endpoint: Fixture.endpoint,
            credentials: credentials,
            behavior: behavior
        )
        let request = Fixture.request(
            transcript: Transcript(entries: [
                .prompt(.init(segments: Fixture.text("Score this answer.")))
            ])
        )

        let channel = LanguageModelExecutorGenerationChannel()
        let drain = Task { for try await _ in channel {} }
        defer { drain.cancel() }
        try await executor.respond(to: request, model: model, streamingInto: channel)
    }

    @Test("Both credentials ride the same request")
    func sendsKeyAndToken() async throws {
        let apigee = ApigeeCredentials(
            tokenURL: URL(string: "https://gateway.example.com/oauth/token")!,
            clientID: "client",
            clientSecret: "secret"
        )
        // Seeded before the executor asks for the same credential, so the
        // provider it finds in the registry is this stub rather than one
        // holding a real URLSession.
        let tokens = StubTransport([.token])
        _ = await ApigeeTokenProvider.shared(for: apigee, transport: tokens)

        let gateway = StubTransport([.reply("4")])
        try await Self.run(
            transport: gateway,
            credentials: .init(apiKey: "static-key", apigee: apigee)
        )

        let sent = try #require(gateway.sent.first)
        #expect(sent.url?.absoluteString == "https://gateway.example.com/llm/v1/chat/completions")
        #expect(sent.httpMethod == "POST")
        #expect(sent.value(forHTTPHeaderField: "x-api-key") == "static-key")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer apigee-token-1")
        #expect(tokens.sent.count == 1)
    }

    /// A gateway with no Apigee proxy in front of it must not grow an
    /// empty `Authorization` header — some reject the request on the
    /// header's presence alone.
    @Test("An API-key-only gateway gets no bearer header")
    func omitsBearerWithoutApigee() async throws {
        let gateway = StubTransport([.reply("4")])
        try await Self.run(transport: gateway, credentials: .init(apiKey: "static-key"))

        let sent = try #require(gateway.sent.first)
        #expect(sent.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(sent.value(forHTTPHeaderField: "x-api-key") == "static-key")
    }

    /// A token can be revoked before it expires, and the gateway's clock
    /// can disagree with this device's. Both look like a 401 on a token
    /// this side believes is valid, and both are fixed by one refresh —
    /// which is worth having because the alternative is a 60-sample eval
    /// run dying an hour in.
    @Test("A 401 refreshes the token and retries exactly once")
    func retriesOnceAfterUnauthorized() async throws {
        let apigee = ApigeeCredentials(
            // A distinct URL keeps this test's provider out of the other
            // test's registry entry — the registry is process-wide.
            tokenURL: URL(string: "https://gateway.example.com/oauth/token-retry")!,
            clientID: "client",
            clientSecret: "secret"
        )
        let tokens = StubTransport([.token, .token])
        _ = await ApigeeTokenProvider.shared(for: apigee, transport: tokens)

        let gateway = StubTransport([.unauthorized, .reply("4")])
        try await Self.run(
            transport: gateway,
            credentials: .init(apiKey: "static-key", apigee: apigee)
        )

        #expect(gateway.sent.count == 2, "the rejected request should be retried once")
        #expect(tokens.sent.count == 2, "the retry should carry a freshly fetched token")
    }

    @Test("A persistent 401 surfaces rather than looping")
    func stopsAfterASecondRejection() async throws {
        let apigee = ApigeeCredentials(
            tokenURL: URL(string: "https://gateway.example.com/oauth/token-dead")!,
            clientID: "client",
            clientSecret: "secret"
        )
        _ = await ApigeeTokenProvider.shared(for: apigee, transport: StubTransport([.token]))

        let gateway = StubTransport([.unauthorized])
        await #expect(throws: CustomModelError.self) {
            try await Self.run(
                transport: gateway,
                credentials: .init(apiKey: "static-key", apigee: apigee)
            )
        }
        #expect(gateway.sent.count == 2)
    }

    @Test("A rate limit maps onto the framework's own error")
    func mapsRateLimit() async throws {
        let gateway = StubTransport([
            .init(status: 429, body: #"{"error":{"message":"slow down"}}"#)
        ])
        await #expect(throws: LanguageModelError.self) {
            try await Self.run(transport: gateway, credentials: .init(apiKey: "static-key"))
        }
    }
}
