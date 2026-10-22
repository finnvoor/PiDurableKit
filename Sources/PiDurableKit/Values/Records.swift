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
    /// Context-only overrides of earlier visible entries.
    public let edits: [ContextEdit]?
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

/// A new transcript entry written by the app, without asking the model anything (pi-durable `EntryDraft`).
public struct EntryDraft: Encodable, Sendable, Hashable {
    /// Where the active context starts once this entry is written.
    public enum Head: Sendable, Hashable {
        /// At this entry itself, like a reset: the model no longer sees older entries.
        case itself
        /// At an earlier visible entry, like a compaction summary that keeps the entries from `entry` on.
        case entry(EntryID)
    }

    public var kind: EntryKind
    public var data: JSONValue?
    /// Messages contributed to the model's context, if any.
    public var model: [Message]?
    /// Makes this entry a head marker that starts a new active context.
    public var head: Head?
    /// Overrides of earlier visible entries' contributions to the model's context.
    public var edits: [ContextEdit]?

    public init(
        kind: EntryKind, data: JSONValue? = nil, model: [Message]? = nil, head: Head? = nil, edits: [ContextEdit]? = nil
    ) {
        self.kind = kind
        self.data = data
        self.model = model
        self.head = head
        self.edits = edits
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyKey.self)
        try container.encode(kind, forKey: AnyKey("kind"))
        try container.encodeIfPresent(data, forKey: AnyKey("data"))
        try container.encodeIfPresent(model, forKey: AnyKey("model"))
        switch head {
        case .itself: try container.encode("self", forKey: AnyKey("head"))
        case .entry(let id): try container.encode(id, forKey: AnyKey("head"))
        case nil: break
        }
        try container.encodeIfPresent(edits, forKey: AnyKey("edits"))
    }
}

/// An immutable override of one visible entry's contribution to the model's context (pi-durable `ContextEdit`).
public struct ContextEdit: Codable, Sendable, Hashable {
    public enum Action: Sendable, Hashable {
        /// The model no longer sees the target's messages.
        case omit
        /// The model sees these messages instead of the target's.
        case replace([Message])
    }

    /// The entry whose messages are omitted or replaced.
    public var target: EntryID
    public var action: Action

    public init(target: EntryID, action: Action) {
        self.target = target
        self.action = action
    }

    public static func omit(_ target: EntryID) -> ContextEdit { ContextEdit(target: target, action: .omit) }
    public static func replace(_ target: EntryID, with messages: [Message]) -> ContextEdit {
        ContextEdit(target: target, action: .replace(messages))
    }

    private enum CodingKeys: String, CodingKey { case target, action, messages }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        target = try container.decode(EntryID.self, forKey: .target)
        switch try container.decode(String.self, forKey: .action) {
        case "replace": action = .replace(try container.decodeIfPresent([Message].self, forKey: .messages) ?? [])
        default: action = .omit
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(target, forKey: .target)
        switch action {
        case .omit: try container.encode("omit", forKey: .action)
        case .replace(let messages):
            try container.encode("replace", forKey: .action)
            try container.encode(messages, forKey: .messages)
        }
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
    /// The telemetry context of the submission's admission, when the harness records with propagation; its run's
    /// tasks continue that trace.
    public let trace: TelemetryCarrier?

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
        case id, conversationId, requestId, type, status, entry, answer, reason, detail, trace
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(SubmissionID.self, forKey: .id)
        conversationId = try container.decode(ConversationID.self, forKey: .conversationId)
        requestId = try container.decodeIfPresent(String.self, forKey: .requestId)
        type = try container.decodeIfPresent(SubmissionType.self, forKey: .type) ?? .input
        trace = try? container.decodeIfPresent(TelemetryCarrier.self, forKey: .trace)
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
        var container = encoder.container(keyedBy: AnyKey.self)
        try container.encode(id, forKey: AnyKey("id"))
        try container.encode(conversationId, forKey: AnyKey("conversationId"))
        try container.encodeIfPresent(requestId, forKey: AnyKey("requestId"))
        try container.encode(type, forKey: AnyKey("type"))
        try container.encodeIfPresent(trace, forKey: AnyKey("trace"))
        try status.encode(into: &container)
    }
}

extension SubmissionRecord.Status {
    /// Writes `status` and its fields (`entry`, `answer`, `reason`, `detail`).
    func encode(into container: inout KeyedEncodingContainer<AnyKey>) throws {
        switch self {
        case .queued:
            try container.encode("queued", forKey: AnyKey("status"))
        case .placed(let entry):
            try container.encode("placed", forKey: AnyKey("status"))
            try container.encode(entry, forKey: AnyKey("entry"))
        case .done(let entry, let answer):
            try container.encode("done", forKey: AnyKey("status"))
            try container.encode(entry, forKey: AnyKey("entry"))
            try container.encodeIfPresent(answer, forKey: AnyKey("answer"))
        case .unanswered(let entry, let reason, let detail):
            try container.encode("unanswered", forKey: AnyKey("status"))
            try container.encodeIfPresent(entry, forKey: AnyKey("entry"))
            try container.encode(reason, forKey: AnyKey("reason"))
            try container.encodeIfPresent(detail, forKey: AnyKey("detail"))
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
    /// The queued entry (writes), or the entry an input is placed as instead of `pi.user`.
    public let entry: JSONValue?

    /// The entry a queued input is placed as, when not `pi.user`.
    public var inputEntry: InputEntry? {
        guard mode != .write else { return nil }
        return try? entry?.decode(as: InputEntry.self)
    }

    /// The queued input's text.
    public var text: String {
        if let text = content?.stringValue { return text }
        return content?.arrayValue?.compactMap { $0["text"]?.stringValue }.joined() ?? ""
    }
}
