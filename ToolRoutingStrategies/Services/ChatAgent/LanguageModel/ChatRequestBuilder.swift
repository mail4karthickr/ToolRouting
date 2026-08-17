import Foundation
import FoundationModels

// MARK: - Transcript → chat-completions body
//
// Pure translation, no I/O, so the mapping can be unit-tested without a
// gateway. The whole job is turning Foundation Models' transcript — a
// flat list of typed entries — into the role-tagged message array the
// OpenAI surface expects.
//
// The two mappings worth knowing about:
//
//   .toolCalls  → an ASSISTANT message carrying `tool_calls`
//   .toolOutput → a TOOL message carrying `tool_call_id`
//
// Those two must stay adjacent and in order: the gateway rejects a tool
// result whose call it has not seen, which is the failure you get if you
// filter entries without keeping the pairing.

nonisolated enum ChatRequestBuilder {

    static func build(
        from request: LanguageModelExecutorGenerationRequest,
        endpoint: CustomLanguageModel.Endpoint,
        behavior: CustomLanguageModel.Behavior
    ) throws -> ChatCompletionRequest {
        var messages: [ChatCompletionMessage] = []
        var system: String?

        for entry in request.transcript {
            switch entry {
            case .instructions(let instructions):
                // Instructions can appear more than once; they concatenate
                // into the single system message rather than replacing.
                system = (system.map { $0 + "\n\n" } ?? "") + text(of: instructions.segments)

            case .prompt(let prompt):
                messages.append(.init(role: .user, content: text(of: prompt.segments)))

            case .response(let response):
                messages.append(.init(role: .assistant, content: text(of: response.segments)))

            case .toolCalls(let calls):
                messages.append(
                    .init(
                        role: .assistant,
                        content: nil,
                        toolCalls: calls.map { call in
                            ChatToolCall(
                                id: call.id,
                                function: .init(
                                    name: call.toolName,
                                    arguments: call.arguments.jsonString
                                )
                            )
                        }
                    )
                )

            case .toolOutput(let output):
                messages.append(
                    .init(
                        role: .tool,
                        content: text(of: output.segments),
                        toolCallID: output.id
                    )
                )

            default:
                // Reasoning entries, and anything added to `Transcript.Entry`
                // later, are dropped on purpose. The chat-completions surface
                // has no portable way to replay a prior turn's reasoning, and
                // a gateway that exposes one does it under a vendor key.
                // Reasoning is not required for correctness — it is context
                // the model regenerates.
                //
                // Matched with `default` rather than by name for the same
                // reason as `text(of:)` below: naming a case of a resilient
                // enum emits a reference to its case descriptor, and a case
                // the running OS does not export makes dyld abort at launch.
                continue
            }
        }

        // A structured request gets the schema in the prompt as well as (or
        // instead of) the wire field — see `applyStructuredOutput`.
        var responseFormat: ChatResponseFormat?
        if let schema = request.schema {
            let json = jsonSchema(from: schema)
            if behavior.supportsStructuredOutputs {
                responseFormat = .jsonSchema(name: "response", schema: json)
            } else {
                responseFormat = .jsonObject
            }
            // Constrained decoding makes the instruction redundant but
            // harmless; without it, this instruction is the only thing
            // holding the shape together.
            let needsSchemaInPrompt =
                (request.contextOptions.includeSchemaInPrompt ?? true)
                || !behavior.supportsStructuredOutputs
            if needsSchemaInPrompt {
                system = (system.map { $0 + "\n\n" } ?? "") + """
                    Respond with a single JSON object matching this schema, and \
                    nothing else — no prose, no code fence:
                    \(json.jsonText)
                    """
            }
        }

        if let system, !system.isEmpty {
            messages.insert(.init(role: .system, content: system), at: 0)
        }

        let tools: [ChatTool]? =
            behavior.supportsToolCalling && !request.enabledToolDefinitions.isEmpty
            ? request.enabledToolDefinitions.map(chatTool)
            : nil

        let maximumTokens =
            request.generationOptions.maximumResponseTokens
            ?? behavior.defaultMaximumResponseTokens

        var body = ChatCompletionRequest(
            model: endpoint.modelID,
            messages: messages,
            maxTokens: behavior.usesMaxCompletionTokens ? nil : maximumTokens,
            maxCompletionTokens: behavior.usesMaxCompletionTokens ? maximumTokens : nil,
            tools: tools,
            toolChoice: tools == nil
                ? nil
                : toolChoice(for: request.generationOptions.toolCallingMode),
            responseFormat: responseFormat,
            stream: false
        )
        applySampling(request.generationOptions, behavior: behavior, to: &body)
        return body
    }

    // MARK: Segments

    private static func text(of segments: [Transcript.Segment]) -> String {
        segments.compactMap { segment in
            switch segment {
            case .text(let text): text.content
            case .structure(let structure): structure.content.jsonString
            // Attachments, custom segments and anything added later carry
            // nothing this gateway can send. Images would need a
            // `{type: "image_url"}` content part and a gateway that accepts
            // one, so they are dropped rather than half-supported — and
            // `capabilities` never claims `.vision`, so the framework will
            // not route them here.
            //
            // Matched with `default` rather than by name on purpose.
            // `Transcript.Segment` is resilient, so naming a case emits a
            // reference to its case descriptor, and a case that only exists
            // in a newer SDK than the OS on the device makes dyld abort the
            // process at launch. Every branch here returns nil anyway.
            default: nil
            }
        }
        .joined(separator: "\n")
    }

    // MARK: Tools

    private static func chatTool(_ definition: Transcript.ToolDefinition) -> ChatTool {
        ChatTool(
            function: .init(
                name: definition.name,
                description: definition.description,
                parameters: jsonSchema(from: definition.parameters)
            )
        )
    }

    /// `.allowed` is the gateway's default and is left off the wire.
    private static func toolChoice(
        for mode: GenerationOptions.ToolCallingMode?
    ) -> ChatToolChoice? {
        guard let mode else { return nil }
        switch mode.kind {
        case .required: return .required
        case .disallowed: return ChatToolChoice.none
        case .allowed: return nil
        @unknown default: return nil
        }
    }

    // MARK: Sampling

    private static func applySampling(
        _ options: GenerationOptions,
        behavior: CustomLanguageModel.Behavior,
        to body: inout ChatCompletionRequest
    ) {
        guard behavior.supportsSampling else { return }
        body.temperature = options.temperature
        switch options.samplingMode?.kind {
        case .greedy:
            body.temperature = 0
        case .randomProbabilityThreshold(let threshold, _):
            body.topP = threshold
        case .randomTopK:
            // No `top_k` on the OpenAI surface. Dropped rather than
            // approximated with a top_p that means something else.
            break
        case nil:
            break
        @unknown default:
            break
        }
    }

    // MARK: Schema

    /// `GenerationSchema` encodes as JSON Schema, but with framework
    /// extension keys (`x-order`, `title`) that a strict validator rejects,
    /// and without the two things strict mode requires on every object:
    /// `additionalProperties: false`, and every property listed in
    /// `required`.
    ///
    /// The `required` rewrite is the part that surprises people. OpenAI
    /// strict mode has no concept of an optional field — an optional
    /// property must be listed as required with `null` in its type union.
    /// Adding every property to `required` here keeps the request valid;
    /// a genuinely optional field in a @Generable type is why the union
    /// matters, and why a schema with one should be checked by hand
    /// against your gateway.
    static func jsonSchema(from schema: GenerationSchema) -> JSONValue {
        guard let value = JSONValue.encoded(schema) else { return .object(["type": .string("object")]) }
        return sanitize(value)
    }

    /// Keys a strict JSON Schema validator accepts. Anything else is
    /// dropped — an unknown key is a 400, not a warning.
    private static let allowedSchemaKeys: Set<String> = [
        "type", "properties", "required", "items", "enum", "const",
        "anyOf", "allOf", "oneOf", "$ref", "$defs", "definitions",
        "description", "additionalProperties",
    ]

    /// Keys whose values are `{name: schema}` maps. Their KEYS are
    /// arbitrary names that must survive; only the nested schemas are
    /// sanitized.
    private static let mapValuedKeys: Set<String> = ["properties", "$defs", "definitions"]

    private static func sanitize(_ value: JSONValue) -> JSONValue {
        switch value {
        case .object(let fields):
            var out: [String: JSONValue] = [:]
            for (key, nested) in fields where allowedSchemaKeys.contains(key) {
                if mapValuedKeys.contains(key), case .object(let map) = nested {
                    out[key] = .object(map.mapValues(sanitize))
                } else {
                    out[key] = sanitize(nested)
                }
            }
            if out["type"] == .string("object") {
                out["additionalProperties"] = .bool(false)
                if case .object(let properties) = out["properties"] {
                    out["required"] = .array(properties.keys.sorted().map(JSONValue.string))
                }
            }
            return .object(out)
        case .array(let elements):
            return .array(elements.map(sanitize))
        default:
            return value
        }
    }
}
