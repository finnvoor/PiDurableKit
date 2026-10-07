import Foundation

/// Everything a UI needs to show one conversation: its active transcript and live state. Each committed
/// change produces a new view; see ``Conversation/views()``.
public struct ConversationView: Decodable, Sendable, Hashable {
    public let conversation: ConversationRecord
    /// The active transcript: the head marker (if any), then every entry from its head onward.
    public let entries: [Entry]
    /// The running generation and tool calls (`pi.live`).
    public let live: LiveState
    /// Queued submissions (`pi.inbox`).
    public let inbox: [InboxItem]
    /// The conversation's spend (`pi.usage`).
    public let usage: UsageState
    /// The stored agent choices (`pi.agent`).
    public let agent: AgentState
    /// Every built-in document, raw, keyed by kind.
    public let documents: JSONObject

    private enum CodingKeys: String, CodingKey { case conversation, entries, docs }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            conversation: try container.decode(ConversationRecord.self, forKey: .conversation),
            entries: try container.decodeIfPresent([Entry].self, forKey: .entries) ?? [],
            docs: try container.decodeIfPresent(JSONObject.self, forKey: .docs) ?? [:])
    }

    init(conversation: ConversationRecord, entries: [Entry], docs: JSONObject) {
        self.conversation = conversation
        self.entries = entries
        documents = docs
        live = (try? docs["pi.live"].map { try $0.decode(as: LiveState.self) }) ?? LiveState()
        inbox = (try? docs["pi.inbox"]?["items"].map { try $0.decode(as: [InboxItem].self) }) ?? []
        usage = (try? docs["pi.usage"].map { try $0.decode(as: UsageState.self) }) ?? UsageState()
        agent = (try? docs["pi.agent"].map { try $0.decode(as: AgentState.self) }) ?? AgentState()
    }

    /// Whether a run is working on an input.
    public var isBusy: Bool { live.run != nil }

    /// The answer being generated right now, as last committed.
    public var streamingMessage: AssistantMessage? { live.generation?.message }

    /// The transcript's user, assistant, and tool result messages, in order.
    public var messages: [Message] {
        entries.flatMap { entry -> [Message] in
            guard entry.kind != .system else { return [] }
            return (entry.model ?? []).filter { if case .system = $0 { false } else { true } }
        }
    }
}

/// Live presentation of the current run (`pi.live`).
public struct LiveState: Decodable, Sendable, Hashable {
    public struct Run: Decodable, Sendable, Hashable {
        /// The task that settles the run's inputs.
        public let taskId: TaskID
        public let inputs: [SubmissionID]
    }

    public struct Generation: Decodable, Sendable, Hashable {
        public let attempt: Int
        /// The partial response, committed periodically while it streams.
        public let message: AssistantMessage?
        /// A durable backoff before the next attempt.
        public let retry: Retry?
    }

    public struct Retry: Decodable, Sendable, Hashable {
        /// When the next attempt starts.
        public let at: Date
        public let error: String

        private enum CodingKeys: String, CodingKey { case at, error }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            at = try container.decodeMilliseconds(forKey: .at)
            error = try container.decodeIfPresent(String.self, forKey: .error) ?? ""
        }
    }

    /// One tool call of the current round.
    public struct ToolSlot: Decodable, Sendable, Hashable, Identifiable {
        public enum Status: String, Decodable, Sendable {
            case pending, running, done
        }

        public var id: String { callId }
        public let callId: String
        public let name: String
        public let taskId: TaskID?
        public let status: Status
        /// The output the tool streamed so far.
        public let output: String?
        public let details: JSONValue?
        /// The result entry, once done.
        public let entry: EntryID?
    }

    public struct Compaction: Decodable, Sendable, Hashable {
        public let taskId: TaskID
        /// `manual`, `threshold`, or `overflow`.
        public let reason: String
        public let blocking: Bool
        public let attempt: Int
    }

    /// Present exactly while the conversation is busy.
    public let run: Run?
    public let generation: Generation?
    public let tools: [ToolSlot]
    public let compactions: [Compaction]

    init() {
        run = nil
        generation = nil
        tools = []
        compactions = []
    }

    private enum CodingKeys: String, CodingKey { case run, generation, tools, compactions }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        run = try? container.decodeIfPresent(Run.self, forKey: .run)
        generation = try? container.decodeIfPresent(Generation.self, forKey: .generation)
        tools = (try? container.decodeIfPresent([ToolSlot].self, forKey: .tools)) ?? []
        compactions = (try? container.decodeIfPresent([Compaction].self, forKey: .compactions)) ?? []
    }
}

/// One update of ``Conversation/views()`` on the wire: the whole transcript, or the entries appended since the last
/// update after keeping the first `keep` of its entries.
struct ConversationViewUpdate: Decodable, Sendable {
    let conversation: ConversationRecord
    let entries: [Entry]?
    let keep: Int?
    let append: [Entry]?
    let docs: JSONObject?

    func view(after previous: [Entry]) -> ConversationView {
        var transcript = entries ?? []
        if entries == nil, let keep {
            transcript = Array(previous.prefix(keep)) + (append ?? [])
        }
        return ConversationView(conversation: conversation, entries: transcript, docs: docs ?? [:])
    }
}
