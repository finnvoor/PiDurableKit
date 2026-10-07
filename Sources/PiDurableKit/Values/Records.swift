import Foundation

/// The kind of a transcript entry, such as `pi.user` or `pi.assistant`. Apps can write their own kinds.
public struct EntryKind: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
    public var description: String { rawValue }

    public static let user: EntryKind = "pi.user"
    public static let assistant: EntryKind = "pi.assistant"
    public static let toolResult: EntryKind = "pi.tool-result"
    public static let system: EntryKind = "pi.system"
    public static let reset: EntryKind = "pi.reset"
    public static let compaction: EntryKind = "pi.compaction"
}

/// One immutable transcript record.
public struct Entry: Codable, Sendable, Hashable, Identifiable {
    public let id: EntryID
    public let conversationId: ConversationID
    public let kind: EntryKind
    /// The messages this entry contributes to the model's context.
    public let model: [Message]?
    /// Application-facing payload.
    public let data: JSONValue?
    /// The first entry of the active context this entry selects (resets and compactions).
    public let head: EntryID?
    /// The task that appended this entry.
    public let byTaskId: TaskID?

    /// The entry's first model message.
    public var message: Message? { model?.first }

    /// The model response of a `pi.assistant` entry.
    public var assistantMessage: AssistantMessage? {
        if case .assistant(let message) = message { return message }
        return nil
    }

    /// The user message of a `pi.user` entry.
    public var userMessage: UserMessage? {
        if case .user(let message) = message { return message }
        return nil
    }

    /// The tool result of a `pi.tool-result` entry.
    public var toolResult: ToolResultMessage? {
        if case .toolResult(let message) = message { return message }
        return nil
    }

    /// The text of the entry's messages.
    public var text: String { (model ?? []).map(\.text).joined(separator: "\n") }
}

/// A new transcript entry written by the app, without asking the model anything.
public struct EntryDraft: Encodable, Sendable {
    public var kind: EntryKind
    public var data: JSONValue?
    /// Messages contributed to the model's context, if any.
    public var model: [Message]?

    public init(kind: EntryKind, data: JSONValue? = nil, model: [Message]? = nil) {
        self.kind = kind
        self.data = data
        self.model = model
    }
}

/// Identity and ancestry of a conversation.
public struct ConversationRecord: Codable, Sendable, Hashable, Identifiable {
    public struct Parent: Codable, Sendable, Hashable {
        public let conversationId: ConversationID
        public let at: EntryID
    }

    public struct Owner: Codable, Sendable, Hashable {
        public let conversationId: ConversationID
        public let taskId: TaskID
    }

    public let id: ConversationID
    /// The conversation and entry this one was forked from.
    public let parent: Parent?
    /// The task that owns this conversation, such as a subagent call.
    public let owner: Owner?
}

/// A page of a scan, with the cursor of the next page.
public struct Page<Item: Sendable>: Sendable {
    public let items: [Item]
    /// Pass to the next scan to continue; `nil` on the last page.
    public let next: Cursor?
}

extension Page: Decodable where Item: Decodable {}

/// Backend-owned continuation state of a scan.
public struct Cursor: Codable, Sendable, Hashable {
    let value: JSONValue
    public init(from decoder: Decoder) throws { value = try JSONValue(from: decoder) }
    public func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}

/// The durable lifecycle of one submission.
public struct SubmissionRecord: Codable, Sendable, Hashable, Identifiable {
    public enum SubmissionType: String, Codable, Sendable {
        case input, write
    }

    public enum Status: Sendable, Hashable {
        /// Admitted but not yet in the transcript; waiting in the inbox.
        case queued
        /// In the transcript and owned by a running run.
        case placed(entry: EntryID)
        /// Answered (input) or appended (write).
        case done(entry: EntryID, answer: EntryID?)
        /// Can no longer be answered, with the reason, such as `aborted`, `failed`, or `stale`.
        case unanswered(entry: EntryID?, reason: String, detail: JSONValue?)
    }

    public let id: SubmissionID
    public let conversationId: ConversationID
    public let requestId: String?
    public let type: SubmissionType
    public let status: Status

    public var isSettled: Bool {
        switch status {
        case .done, .unanswered: true
        case .queued, .placed: false
        }
    }

    /// The answer entry of a done input.
    public var answer: EntryID? {
        if case .done(_, let answer) = status { return answer }
        return nil
    }

    private enum CodingKeys: String, CodingKey {
        case id, conversationId, requestId, type, status, entry, answer, reason, detail
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(SubmissionID.self, forKey: .id)
        conversationId = try container.decode(ConversationID.self, forKey: .conversationId)
        requestId = try container.decodeIfPresent(String.self, forKey: .requestId)
        type = try container.decodeIfPresent(SubmissionType.self, forKey: .type) ?? .input
        let entry = try container.decodeIfPresent(EntryID.self, forKey: .entry)
        switch try container.decode(String.self, forKey: .status) {
        case "queued": status = .queued
        case "placed": status = .placed(entry: entry ?? 0)
        case "done": status = .done(entry: entry ?? 0, answer: try container.decodeIfPresent(EntryID.self, forKey: .answer))
        default:
            status = .unanswered(
                entry: entry,
                reason: try container.decodeIfPresent(String.self, forKey: .reason) ?? "unknown",
                detail: try container.decodeIfPresent(JSONValue.self, forKey: .detail))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(conversationId, forKey: .conversationId)
        try container.encodeIfPresent(requestId, forKey: .requestId)
        try container.encode(type, forKey: .type)
        switch status {
        case .queued:
            try container.encode("queued", forKey: .status)
        case .placed(let entry):
            try container.encode("placed", forKey: .status)
            try container.encode(entry, forKey: .entry)
        case .done(let entry, let answer):
            try container.encode("done", forKey: .status)
            try container.encode(entry, forKey: .entry)
            try container.encodeIfPresent(answer, forKey: .answer)
        case .unanswered(let entry, let reason, let detail):
            try container.encode("unanswered", forKey: .status)
            try container.encodeIfPresent(entry, forKey: .entry)
            try container.encode(reason, forKey: .reason)
            try container.encodeIfPresent(detail, forKey: .detail)
        }
    }
}

/// Spend of a conversation or a whole harness.
public struct UsageState: Codable, Sendable, Hashable {
    /// Model responses and summarizations, keyed `provider/modelId`.
    public var models: [String: Usage]
    /// Tool results that reported usage, keyed by tool name.
    public var tools: [String: Usage]

    public init(models: [String: Usage] = [:], tools: [String: Usage] = [:]) {
        self.models = models
        self.tools = tools
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyKey.self)
        models = (try? container.decode([String: Usage].self, forKey: AnyKey("models"))) ?? [:]
        tools = (try? container.decode([String: Usage].self, forKey: AnyKey("tools"))) ?? [:]
    }

    /// The total cost across every model and tool, in the providers' currency (usually USD).
    public var totalCost: Double {
        models.values.reduce(0) { $0 + $1.cost.total } + tools.values.reduce(0) { $0 + $1.cost.total }
    }

    /// The total tokens across every model.
    public var totalTokens: Int { models.values.reduce(0) { $0 + $1.totalTokens } }
}

/// A queued submission waiting for a boundary.
public struct InboxItem: Codable, Sendable, Hashable, Identifiable {
    public enum Mode: String, Codable, Sendable {
        case steer, followUp, write
    }

    public let id: SubmissionID
    public let mode: Mode
    /// The queued user input (steers and follow-ups).
    public let content: JSONValue?
    /// The queued entry (writes).
    public let entry: JSONValue?

    /// The queued input's text.
    public var text: String {
        if let text = content?.stringValue { return text }
        return content?.arrayValue?.compactMap { $0["text"]?.stringValue }.joined() ?? ""
    }
}
