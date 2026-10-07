import Foundation

/// A model request's context (pi-ai `Context`): the system prompt, messages, and offered tools.
public struct ModelContext: Encodable, Sendable {
    public var systemPrompt: String?
    public var messages: [Message]
    public var tools: [ModelTool]

    public init(systemPrompt: String? = nil, messages: [Message], tools: [ModelTool] = []) {
        self.systemPrompt = systemPrompt
        self.messages = messages
        self.tools = tools
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyKey.self)
        try container.encodeIfPresent(systemPrompt, forKey: AnyKey("systemPrompt"))
        try container.encode(messages, forKey: AnyKey("messages"))
        if !tools.isEmpty { try container.encode(tools, forKey: AnyKey("tools")) }
    }
}

/// A tool offered to a direct model request (pi-ai `Tool`): only its declaration; the caller runs its calls.
public struct ModelTool: Encodable, Sendable {
    public var name: String
    public var description: String
    public var parameters: JSONSchema

    public init(name: String, description: String, parameters: JSONSchema = .object()) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }

    /// The declaration of a harness tool.
    public init(_ tool: Tool) {
        self.init(name: tool.name, description: tool.description, parameters: tool.parameters)
    }
}

/// Options of a direct model request (pi-ai `SimpleStreamOptions`).
public struct ModelOptions: Encodable, Sendable {
    /// How much a reasoning model thinks.
    public var reasoning: ThinkingLevel?
    public var maxTokens: Int?
    public var temperature: Double?
    /// Provider prompt-cache and session affinity.
    public var sessionId: String?
    /// `none`, `short`, or `long`.
    public var cacheRetention: String?
    public var headers: [String: String]?
    public var metadata: JSONObject?

    public init(
        reasoning: ThinkingLevel? = nil, maxTokens: Int? = nil, temperature: Double? = nil, sessionId: String? = nil,
        cacheRetention: String? = nil, headers: [String: String]? = nil, metadata: JSONObject? = nil
    ) {
        self.reasoning = reasoning
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.sessionId = sessionId
        self.cacheRetention = cacheRetention
        self.headers = headers
        self.metadata = metadata
    }
}

/// One event of a streamed model response (pi-ai `AssistantMessageEvent`).
public enum ModelStreamEvent: Decodable, Sendable {
    case start
    case textDelta(index: Int, delta: String)
    case thinkingDelta(index: Int, delta: String)
    /// A tool call is complete.
    case toolCall(index: Int, ToolCall)
    /// The response finished; `message.stopReason` says why.
    case done(AssistantMessage)
    /// The request failed or was aborted; `message.errorMessage` says why.
    case error(AssistantMessage)
    /// Another event, such as `text_start` or `toolcall_delta`.
    case other(type: String, JSONValue)

    public init(from decoder: Decoder) throws {
        let json = try JSONValue(from: decoder)
        let type = json["type"]?.stringValue ?? ""
        let index = json["contentIndex"]?.intValue ?? 0
        switch type {
        case "start": self = .start
        case "text_delta": self = .textDelta(index: index, delta: json["delta"]?.stringValue ?? "")
        case "thinking_delta": self = .thinkingDelta(index: index, delta: json["delta"]?.stringValue ?? "")
        case "toolcall_end":
            if let call = try? (json["toolCall"] ?? .null).decode(as: ToolCall.self) {
                self = .toolCall(index: index, call)
            } else {
                self = .other(type: type, json)
            }
        case "done": self = .done(try (json["message"] ?? .null).decode(as: AssistantMessage.self))
        case "error": self = .error(try (json["error"] ?? .null).decode(as: AssistantMessage.self))
        default: self = .other(type: type, json)
        }
    }
}

extension Models {
    /// Sends one request to a model and returns its response (pi-ai `models.completeSimple`). Credentials, sign-in
    /// tokens, and headers resolve as for harness requests. Failures come back as a message with stop reason `error`.
    ///
    /// Tools that call a model can report the spend in ``ToolResult/usage``.
    public func complete(_ model: ModelRef, context: ModelContext, options: ModelOptions = ModelOptions()) async throws
        -> AssistantMessage
    {
        try await call("models.complete", ["model": model, "context": context, "options": options])
    }

    /// Streams one model response (pi-ai `models.streamSimple`). Stopping the iteration aborts the request.
    public func stream(_ model: ModelRef, context: ModelContext, options: ModelOptions = ModelOptions())
        -> AsyncThrowingStream<ModelStreamEvent, Error>
    {
        let engine = runtime.engine
        let id = id
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await prepare()
                    let events = engine.stream(
                        "models.stream", ["id": id, "model": model, "context": context, "options": options],
                        of: ModelStreamEvent.self)
                    for try await event in events { continuation.yield(event) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
