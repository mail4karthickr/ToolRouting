import Foundation

// MARK: - The /chat/completions wire format
//
// Hand-written Codable types rather than a generated client, because the
// only part that matters is the part a corporate gateway is likely to
// bend: which keys it accepts, and which of them it silently ignores.
//
// Every key is spelled out in a `CodingKeys` even where a snake-case
// strategy would do it automatically. That is deliberate — a key strategy
// would also rewrite the property names INSIDE a JSON Schema
// (`toolOutput` → `tool_output`), which is a corruption you would not
// find until a structured response failed to decode.

// MARK: - Request

nonisolated struct ChatCompletionRequest: Encodable, Sendable {
    var model: String
    var messages: [ChatCompletionMessage]
    var maxTokens: Int?
    /// Newer surfaces renamed `max_tokens`; only one of the two is ever
    /// encoded, chosen by `Behavior.usesMaxCompletionTokens`.
    var maxCompletionTokens: Int?
    var temperature: Double?
    var topP: Double?
    var tools: [ChatTool]?
    var toolChoice: ChatToolChoice?
    var responseFormat: ChatResponseFormat?
    var stream: Bool = false

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case maxTokens = "max_tokens"
        case maxCompletionTokens = "max_completion_tokens"
        case temperature
        case topP = "top_p"
        case tools
        case toolChoice = "tool_choice"
        case responseFormat = "response_format"
        case stream
    }
}

/// Named for the wire, not shortened to `ChatMessage` — that name is
/// already the app's UI model.
nonisolated struct ChatCompletionMessage: Encodable, Sendable {
    enum Role: String, Encodable, Sendable {
        case system
        case user
        case assistant
        case tool
    }

    var role: Role
    /// Nil on an assistant turn that only called tools.
    var content: String?
    var toolCalls: [ChatToolCall]?
    /// Set only on `.tool` messages; ties the result to the call.
    var toolCallID: String?

    enum CodingKeys: String, CodingKey {
        case role
        case content
        case toolCalls = "tool_calls"
        case toolCallID = "tool_call_id"
    }
}

nonisolated struct ChatToolCall: Codable, Sendable {
    nonisolated struct Function: Codable, Sendable {
        var name: String
        /// A JSON *string*, not an object — the OpenAI surface passes tool
        /// arguments as encoded text, which is also how the framework
        /// streams them, so no re-encoding happens in either direction.
        var arguments: String
    }

    var id: String
    var type: String = "function"
    var function: Function
}

nonisolated struct ChatTool: Encodable, Sendable {
    nonisolated struct Function: Encodable, Sendable {
        var name: String
        var description: String
        var parameters: JSONValue
    }

    var type: String = "function"
    var function: Function
}

nonisolated enum ChatToolChoice: Encodable, Sendable {
    /// Model must call a tool.
    case required
    /// Model must not call a tool.
    case none

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .required: try container.encode("required")
        case .none: try container.encode("none")
        }
    }
}

nonisolated struct ChatResponseFormat: Encodable, Sendable {
    nonisolated struct Schema: Encodable, Sendable {
        var name: String
        /// `true` asks the gateway for constrained decoding. Gateways that
        /// don't implement it either ignore the flag or 400 — which is why
        /// `Behavior.supportsStructuredOutputs` exists.
        var strict: Bool
        var schema: JSONValue
    }

    var type: String
    var jsonSchema: Schema?

    static func jsonSchema(name: String, schema: JSONValue) -> ChatResponseFormat {
        .init(type: "json_schema", jsonSchema: .init(name: name, strict: true, schema: schema))
    }

    /// The weaker guarantee: valid JSON, shape unenforced.
    static let jsonObject = ChatResponseFormat(type: "json_object", jsonSchema: nil)

    enum CodingKeys: String, CodingKey {
        case type
        case jsonSchema = "json_schema"
    }
}

// MARK: - Response

nonisolated struct ChatCompletionResponse: Decodable, Sendable {
    nonisolated struct Choice: Decodable, Sendable {
        var message: ResponseMessage
        var finishReason: String?

        enum CodingKeys: String, CodingKey {
            case message
            case finishReason = "finish_reason"
        }
    }

    nonisolated struct ResponseMessage: Decodable, Sendable {
        var content: String?
        var toolCalls: [ChatToolCall]?
        /// Present when the model declined rather than answered. Distinct
        /// from an empty content, and worth surfacing as such.
        var refusal: String?

        enum CodingKeys: String, CodingKey {
            case content
            case toolCalls = "tool_calls"
            case refusal
        }
    }

    nonisolated struct Usage: Decodable, Sendable {
        var promptTokens: Int?
        var completionTokens: Int?
        var totalTokens: Int?
        var promptTokensDetails: PromptDetails?

        nonisolated struct PromptDetails: Decodable, Sendable {
            var cachedTokens: Int?

            enum CodingKeys: String, CodingKey {
                case cachedTokens = "cached_tokens"
            }
        }

        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
            case totalTokens = "total_tokens"
            case promptTokensDetails = "prompt_tokens_details"
        }
    }

    var choices: [Choice]
    var usage: Usage?
}

/// The error envelope both OpenAI and most gateways wrap failures in.
/// Decoded best-effort: a gateway that returns HTML or a bare string still
/// produces a readable error, it just carries less detail.
nonisolated struct ChatErrorResponse: Decodable, Sendable {
    nonisolated struct Payload: Decodable, Sendable {
        var message: String?
        var type: String?
        var code: String?
    }

    var error: Payload?
}

// MARK: - Loosely typed JSON

/// For values whose shape is only known at runtime: tool parameter
/// schemas, structured-output schemas, tool arguments.
nonisolated enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        if let value = try? container.decode(Double.self) { self = .number(value); return }
        if let value = try? container.decode(String.self) { self = .string(value); return }
        if let value = try? container.decode([JSONValue].self) { self = .array(value); return }
        if let value = try? container.decode([String: JSONValue].self) { self = .object(value); return }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    /// Re-encodes any `Encodable` as loose JSON. Used to get at
    /// `GenerationSchema`, which encodes as JSON Schema but exposes none of
    /// it as values.
    static func encoded(_ value: some Encodable) -> JSONValue? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    static func parsed(_ json: String) -> JSONValue? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Compact JSON text, for pasting a schema into a prompt.
    var jsonText: String {
        guard let data = try? JSONEncoder().encode(self),
              let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return text
    }
}
