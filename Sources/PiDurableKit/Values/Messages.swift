import Foundation

// pi-ai messages, as they appear in transcript entries and agent events.
// Decoding is lenient: unknown roles and content blocks are preserved as JSON instead of failing.

/// A model-facing message.
public enum Message: Sendable, Hashable {
    case user(UserMessage)
    case assistant(AssistantMessage)
    case toolResult(ToolResultMessage)
    case system(SystemMessage)
    /// A message of a role this version of PiDurableKit does not know.
    case other(JSONValue)

    public var role: String {
        switch self {
        case .user: "user"
        case .assistant: "assistant"
        case .toolResult: "toolResult"
        case .system: "system"
        case .other(let json): json["role"]?.stringValue ?? "unknown"
        }
    }

    /// The text of the message's text blocks.
    public var text: String {
        switch self {
        case .user(let message): message.text
        case .assistant(let message): message.text
        case .toolResult(let message): message.text
        case .system(let message): message.text
        case .other: ""
        }
    }
}

extension Message: Codable {
    private enum CodingKeys: String, CodingKey { case role }

    public init(from decoder: Decoder) throws {
        let role = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(String.self, forKey: .role)
        switch role {
        case "user": self = .user(try UserMessage(from: decoder))
        case "assistant": self = .assistant(try AssistantMessage(from: decoder))
        case "toolResult": self = .toolResult(try ToolResultMessage(from: decoder))
        case "system": self = .system(try SystemMessage(from: decoder))
        default: self = .other(try JSONValue(from: decoder))
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .user(let message): try message.encode(to: encoder)
        case .assistant(let message): try message.encode(to: encoder)
        case .toolResult(let message): try message.encode(to: encoder)
        case .system(let message): try message.encode(to: encoder)
        case .other(let json): try json.encode(to: encoder)
        }
    }
}

/// One block of message content.
public enum ContentBlock: Sendable, Hashable {
    case text(String)
    case thinking(String, redacted: Bool = false)
    case image(ImageContent)
    case toolCall(ToolCall)
    /// A block of a type this version of PiDurableKit does not know.
    case other(JSONValue)

    public var text: String? {
        if case .text(let text) = self { return text }
        return nil
    }
}

extension ContentBlock: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, text, thinking, redacted, data, mimeType
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decodeIfPresent(String.self, forKey: .type) {
        case "text":
            self = .text(try container.decodeIfPresent(String.self, forKey: .text) ?? "")
        case "thinking":
            self = .thinking(
                try container.decodeIfPresent(String.self, forKey: .thinking) ?? "",
                redacted: try container.decodeIfPresent(Bool.self, forKey: .redacted) ?? false)
        case "image":
            self = .image(try ImageContent(from: decoder))
        case "toolCall":
            self = .toolCall(try ToolCall(from: decoder))
        default:
            self = .other(try JSONValue(from: decoder))
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .text(let text):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .thinking(let thinking, let redacted):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("thinking", forKey: .type)
            try container.encode(thinking, forKey: .thinking)
            if redacted { try container.encode(true, forKey: .redacted) }
        case .image(let image):
            try image.encode(to: encoder)
        case .toolCall(let call):
            try call.encode(to: encoder)
        case .other(let json):
            try json.encode(to: encoder)
        }
    }
}

/// Base64-encoded image content.
public struct ImageContent: Codable, Sendable, Hashable {
    public var type = "image"
    /// Base64-encoded image bytes.
    public var data: String
    public var mimeType: String

    public init(data: Data, mimeType: String) {
        self.data = data.base64EncodedString()
        self.mimeType = mimeType
    }

    public init(base64: String, mimeType: String) {
        data = base64
        self.mimeType = mimeType
    }

    public var bytes: Data? { Data(base64Encoded: data) }
}

/// A tool call requested by the model.
public struct ToolCall: Codable, Sendable, Hashable, Identifiable {
    public var type = "toolCall"
    public var id: String
    public var name: String
    public var arguments: JSONObject

    public init(id: String, name: String, arguments: JSONObject) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }

    private enum CodingKeys: String, CodingKey { case type, id, name, arguments }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        arguments = (try? container.decodeIfPresent(JSONObject.self, forKey: .arguments)) ?? [:]
    }

    /// Decodes the arguments as `T`.
    public func decodeArguments<T: Decodable>(as type: T.Type = T.self) throws -> T {
        try JSONValue.object(arguments).decode(as: T.self)
    }
}

/// User input: plain text or text and images.
public struct UserMessage: Codable, Sendable, Hashable {
    public var role = "user"
    public var content: [ContentBlock]
    public var timestamp: Date

    var origin: MessageOrigin?

    private enum CodingKeys: String, CodingKey { case role, content, timestamp }

    public init(content: [ContentBlock], timestamp: Date = Date()) {
        self.content = content
        self.timestamp = timestamp
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let text = try? container.decode(String.self, forKey: .content) {
            content = [.text(text)]
        } else {
            content = try container.decodeIfPresent([ContentBlock].self, forKey: .content) ?? []
        }
        timestamp = try container.decodeMilliseconds(forKey: .timestamp)
        let copy = self
        origin = MessageOrigin.capture(decoder, original: copy)
    }

    private func encodeFields(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        try container.encode(content, forKey: .content)
        try container.encode(timestamp.timeIntervalSince1970 * 1000, forKey: .timestamp)
    }

    public var text: String { content.compactMap(\.text).joined() }

    public func encode(to encoder: Encoder) throws {
        var bare = self
        bare.origin = nil
        try MessageOrigin.merge(origin, current: bare) { try encodedFields(encodeFields) }.encode(to: encoder)
    }
}

/// Why a model response ended.
public struct StopReason: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static let pending: StopReason = "pending"
    public static let stop: StopReason = "stop"
    public static let length: StopReason = "length"
    public static let toolUse: StopReason = "toolUse"
    public static let error: StopReason = "error"
    public static let aborted: StopReason = "aborted"
    public static let deferred: StopReason = "deferred"
}

/// A model response.
public struct AssistantMessage: Codable, Sendable, Hashable {
    public var role = "assistant"
    public var content: [ContentBlock]
    public var api: String
    public var provider: ProviderID
    public var model: String
    public var usage: Usage
    public var stopReason: StopReason
    public var errorMessage: String?
    public var timestamp: Date
    /// How long the response took, as pi-ai measured it.
    public var duration: Duration?

    var origin: MessageOrigin?

    private enum CodingKeys: String, CodingKey {
        case role, content, api, provider, model, usage, stopReason, errorMessage, timestamp, durationMs
    }

    public init(
        content: [ContentBlock], api: String = "", provider: ProviderID = "", model: String = "",
        usage: Usage = Usage(), stopReason: StopReason = .stop, errorMessage: String? = nil, timestamp: Date = Date()
    ) {
        self.content = content
        self.api = api
        self.provider = provider
        self.model = model
        self.usage = usage
        self.stopReason = stopReason
        self.errorMessage = errorMessage
        self.timestamp = timestamp
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        content = try container.decodeIfPresent([ContentBlock].self, forKey: .content) ?? []
        api = try container.decodeIfPresent(String.self, forKey: .api) ?? ""
        provider = try container.decodeIfPresent(ProviderID.self, forKey: .provider) ?? ""
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? ""
        usage = (try? container.decodeIfPresent(Usage.self, forKey: .usage)) ?? Usage()
        stopReason = try container.decodeIfPresent(StopReason.self, forKey: .stopReason) ?? .stop
        errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
        duration = try container.decodeIfPresent(Double.self, forKey: .durationMs).map { .milliseconds($0) }
        timestamp = try container.decodeMilliseconds(forKey: .timestamp)
        let copy = self
        origin = MessageOrigin.capture(decoder, original: copy)
    }

    private func encodeFields(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        try container.encode(content, forKey: .content)
        try container.encode(api, forKey: .api)
        try container.encode(provider, forKey: .provider)
        try container.encode(model, forKey: .model)
        try container.encode(usage, forKey: .usage)
        try container.encode(stopReason, forKey: .stopReason)
        try container.encodeIfPresent(errorMessage, forKey: .errorMessage)
        try container.encodeIfPresent(duration?.milliseconds, forKey: .durationMs)
        try container.encode(timestamp.timeIntervalSince1970 * 1000, forKey: .timestamp)
    }

    /// The text of the response's text blocks.
    public var text: String { content.compactMap(\.text).joined() }

    /// The response's reasoning, when the model exposes it.
    public var thinking: String {
        content.compactMap { block in
            if case .thinking(let text, _) = block { return text }
            return nil
        }.joined()
    }

    /// The tool calls the model requested.
    public var toolCalls: [ToolCall] {
        content.compactMap { block in
            if case .toolCall(let call) = block { return call }
            return nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var bare = self
        bare.origin = nil
        try MessageOrigin.merge(origin, current: bare) { try encodedFields(encodeFields) }.encode(to: encoder)
    }
}

/// The result of one tool call, as the model sees it.
public struct ToolResultMessage: Codable, Sendable, Hashable {
    public var role = "toolResult"
    public var toolCallId: String
    public var toolName: String
    public var content: [ContentBlock]
    public var details: JSONValue?
    public var isError: Bool
    public var timestamp: Date
    /// How long the tool's `execute` took in this attempt; `nil` for calls that did not run or were interrupted.
    public var duration: Duration?

    var origin: MessageOrigin?

    private enum CodingKeys: String, CodingKey {
        case role, toolCallId, toolName, content, details, isError, timestamp, durationMs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        toolCallId = try container.decodeIfPresent(String.self, forKey: .toolCallId) ?? ""
        toolName = try container.decodeIfPresent(String.self, forKey: .toolName) ?? ""
        content = try container.decodeIfPresent([ContentBlock].self, forKey: .content) ?? []
        details = try container.decodeIfPresent(JSONValue.self, forKey: .details)
        isError = try container.decodeIfPresent(Bool.self, forKey: .isError) ?? false
        duration = try container.decodeIfPresent(Double.self, forKey: .durationMs).map { .milliseconds($0) }
        timestamp = try container.decodeMilliseconds(forKey: .timestamp)
        let copy = self
        origin = MessageOrigin.capture(decoder, original: copy)
    }

    private func encodeFields(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        try container.encode(toolCallId, forKey: .toolCallId)
        try container.encode(toolName, forKey: .toolName)
        try container.encode(content, forKey: .content)
        try container.encodeIfPresent(details, forKey: .details)
        try container.encode(isError, forKey: .isError)
        try container.encodeIfPresent(duration?.milliseconds, forKey: .durationMs)
        try container.encode(timestamp.timeIntervalSince1970 * 1000, forKey: .timestamp)
    }

    public var text: String { content.compactMap(\.text).joined() }

    public func encode(to encoder: Encoder) throws {
        var bare = self
        bare.origin = nil
        try MessageOrigin.merge(origin, current: bare) { try encodedFields(encodeFields) }.encode(to: encoder)
    }
}

/// A system prompt message or update. pi-durable writes these as `pi.system` entries.
public struct SystemMessage: Codable, Sendable, Hashable {
    public var role = "system"
    /// The message's base text.
    public var text: String
    /// Named prompt sections; `nil` values remove a section.
    public var sections: [String: String?]
    public var timestamp: Date

    var origin: MessageOrigin?

    private enum CodingKeys: String, CodingKey { case role, content, sections, timestamp }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let text = try? container.decode(String.self, forKey: .content) {
            self.text = text
        } else {
            text = (try? container.decodeIfPresent([ContentBlock].self, forKey: .content))?.compactMap(\.text).joined() ?? ""
        }
        sections = (try? container.decodeIfPresent([String: String?].self, forKey: .sections)) ?? [:]
        timestamp = try container.decodeMilliseconds(forKey: .timestamp)
        let copy = self
        origin = MessageOrigin.capture(decoder, original: copy)
    }

    private func encodeFields(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        try container.encode(text, forKey: .content)
        try container.encode(sections, forKey: .sections)
        try container.encode(timestamp.timeIntervalSince1970 * 1000, forKey: .timestamp)
    }

    public func encode(to encoder: Encoder) throws {
        var bare = self
        bare.origin = nil
        try MessageOrigin.merge(origin, current: bare) { try encodedFields(encodeFields) }.encode(to: encoder)
    }
}

/// Token counts and cost of model or tool work.
public struct Usage: Codable, Sendable, Hashable {
    public struct Cost: Codable, Sendable, Hashable {
        public var input: Double = 0
        public var output: Double = 0
        public var cacheRead: Double = 0
        public var cacheWrite: Double = 0
        public var total: Double = 0

        public init() {}

        public init(input: Double, output: Double, cacheRead: Double = 0, cacheWrite: Double = 0) {
            self.input = input
            self.output = output
            self.cacheRead = cacheRead
            self.cacheWrite = cacheWrite
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: AnyKey.self)
            func value(_ key: String) -> Double { (try? container.decode(Double.self, forKey: AnyKey(key))) ?? 0 }
            input = value("input")
            output = value("output")
            cacheRead = value("cacheRead")
            cacheWrite = value("cacheWrite")
            total = value("total")
        }
    }

    public var input = 0
    public var output = 0
    public var cacheRead = 0
    public var cacheWrite = 0
    public var reasoning: Int?
    public var totalTokens = 0
    public var cost = Cost()

    public init() {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyKey.self)
        func value(_ key: String) -> Int {
            (try? container.decode(Double.self, forKey: AnyKey(key))).map { Int($0) } ?? 0
        }
        input = value("input")
        output = value("output")
        cacheRead = value("cacheRead")
        cacheWrite = value("cacheWrite")
        reasoning = (try? container.decode(Double.self, forKey: AnyKey("reasoning"))).map { Int($0) }
        totalTokens = value("totalTokens")
        cost = (try? container.decode(Cost.self, forKey: AnyKey("cost"))) ?? Cost()
    }
}

extension KeyedDecodingContainer {
    /// Decodes a JavaScript millisecond timestamp, defaulting to the epoch when absent.
    func decodeMilliseconds(forKey key: Key) throws -> Date {
        guard let milliseconds = try? decodeIfPresent(Double.self, forKey: key) else { return Date(timeIntervalSince1970: 0) }
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }
}

/// The JSON a message was decoded from, so a message passed back unchanged keeps every provider field (signatures,
/// response IDs, diagnostics) that this Swift model does not represent. Ignored by equality.
final class MessageOrigin: @unchecked Sendable, Hashable {
    let json: JSONObject
    /// The value as decoded; equality ignores `origin`, so comparing with it tells whether anything changed.
    let original: AnyHashable

    init(json: JSONObject, original: AnyHashable) {
        self.json = json
        self.original = original
    }

    static func == (lhs: MessageOrigin, rhs: MessageOrigin) -> Bool { true }
    func hash(into hasher: inout Hasher) {}

    /// Records the origin of `original`, decoded from `decoder`.
    static func capture(_ decoder: Decoder, original: some Hashable & Sendable) -> MessageOrigin? {
        guard let json = (try? JSONValue(from: decoder))?.objectValue else { return nil }
        return MessageOrigin(json: json, original: AnyHashable(original))
    }

    /// The JSON to encode: the original when nothing changed, else the original with the changed fields replaced.
    static func merge(_ origin: MessageOrigin?, current: some Hashable, fields: () throws -> JSONObject) rethrows
        -> JSONObject
    {
        guard let origin else { return try fields() }
        if origin.original == AnyHashable(current) { return origin.json }
        return origin.json.merging(try fields()) { _, new in new }
    }
}

/// Encodes `fields` (a struct's own `encodeFields`) as a JSON object.
func encodedFields(_ encode: (Encoder) throws -> Void) throws -> JSONObject {
    struct Wrapper: Encodable {
        let encode: (Encoder) throws -> Void
        func encode(to encoder: Encoder) throws { try encode(encoder) }
    }
    return try withoutActuallyEscaping(encode) { encode in
        try JSONValue(encoding: Wrapper(encode: encode)).objectValue ?? [:]
    }
}
