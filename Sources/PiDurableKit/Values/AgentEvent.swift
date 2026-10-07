import Foundation

/// A coding-agent style event derived from one conversation's commits (pi-durable `watchEvents`).
///
/// The first event of every stream is a ``snapshot(_:)``; later events apply on top of it. A consumer that falls
/// far behind receives a fresh snapshot instead of the events it missed.
public enum AgentEvent: Sendable, Hashable {
    case snapshot(Snapshot)
    case runStart(inputs: [SubmissionID])
    case runEnd(inputs: [SubmissionID])
    case turnStart
    case turnEnd
    case messageStart(Message)
    /// Changes to the in-flight assistant message, with its current usage.
    case messageUpdate(changes: [MessageChange], usage: Usage)
    case messageEnd(Entry)
    case toolExecutionStart(callId: String, toolName: String, arguments: JSONObject)
    case toolExecutionUpdate(callId: String, toolName: String, output: OutputChange?, details: JSONValue?)
    /// `entry` is absent when the tool task faulted or was orphaned.
    case toolExecutionEnd(callId: String, toolName: String, entry: Entry?)
    case inboxUpdate([QueuedItem])
    case submission(SubmissionRecord)
    case autoRetryStart(attempt: Int, at: Date, errorMessage: String)
    case autoRetryEnd(attempt: Int)
    case entryAppended(Entry)
    case agentChanged(AgentState)
    case usageChanged(UsageState)
    case taskFailed(taskId: TaskID, kind: String, message: String)
    case compactionStart(taskId: TaskID, reason: String, blocking: Bool)
    case compactionEnd(taskId: TaskID, reason: String)
    /// An event this version of PiDurableKit does not know.
    case other(type: String, JSONValue)

    /// The state of the conversation when the stream attached.
    public struct Snapshot: Decodable, Sendable, Hashable {
        public let entries: [Entry]
        /// The inputs of the running run, if busy.
        public let run: [SubmissionID]?
        /// The in-flight partial response, if a generation is streaming.
        public let message: AssistantMessage?
        public let tools: [LiveState.ToolSlot]
        public let inbox: [QueuedItem]
        public let agent: AgentState
        public let usage: UsageState

        private enum CodingKeys: String, CodingKey { case entries, run, generation, tools, inbox, agent, usage }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            entries = try container.decodeIfPresent([Entry].self, forKey: .entries) ?? []
            run = try container.decodeIfPresent(JSONValue.self, forKey: .run)?["inputs"].flatMap { try? $0.decode(as: [SubmissionID].self) }
            message = try container.decodeIfPresent(JSONValue.self, forKey: .generation)?["message"].flatMap { try? $0.decode(as: AssistantMessage.self) }
            tools = (try? container.decodeIfPresent([LiveState.ToolSlot].self, forKey: .tools)) ?? []
            inbox = (try? container.decodeIfPresent([QueuedItem].self, forKey: .inbox)) ?? []
            agent = (try? container.decodeIfPresent(AgentState.self, forKey: .agent)) ?? AgentState()
            usage = (try? container.decodeIfPresent(UsageState.self, forKey: .usage)) ?? UsageState()
        }
    }

    public struct QueuedItem: Decodable, Sendable, Hashable {
        public let id: SubmissionID
        /// `steer`, `followUp`, or `write`.
        public let mode: String
    }

    /// A change to the running output of a tool call.
    public enum OutputChange: Sendable, Hashable {
        /// Drop `trimStart` characters from the front, then append `append`.
        case append(String, trimStart: Int)
        /// Replace the whole output.
        case set(String)
    }
}

/// One change to the in-flight assistant message.
public enum MessageChange: Sendable, Hashable {
    case blockStart(index: Int, block: ContentBlock)
    case textDelta(index: Int, delta: String)
    case thinkingDelta(index: Int, delta: String)
    case toolCallDelta(index: Int, path: [JSONValue], delta: String)
    case block(index: Int, block: ContentBlock)
    case message(AssistantMessage)
    case other(JSONValue)
}

extension MessageChange: Decodable {
    public init(from decoder: Decoder) throws {
        let json = try JSONValue(from: decoder)
        let index = json["contentIndex"]?.intValue ?? 0
        switch json["type"]?.stringValue {
        case "text_start", "thinking_start", "toolcall_start", "block":
            guard let block = try? json["block"]?.decode(as: ContentBlock.self) else {
                self = .other(json)
                return
            }
            self = json["type"]?.stringValue == "block" ? .block(index: index, block: block) : .blockStart(index: index, block: block)
        case "text_delta": self = .textDelta(index: index, delta: json["delta"]?.stringValue ?? "")
        case "thinking_delta": self = .thinkingDelta(index: index, delta: json["delta"]?.stringValue ?? "")
        case "toolcall_delta":
            self = .toolCallDelta(index: index, path: json["path"]?.arrayValue ?? [], delta: json["delta"]?.stringValue ?? "")
        case "message":
            if let message = try? json["message"]?.decode(as: AssistantMessage.self) {
                self = .message(message)
            } else {
                self = .other(json)
            }
        default: self = .other(json)
        }
    }
}

extension AgentEvent: Decodable {
    public init(from decoder: Decoder) throws {
        let json = try JSONValue(from: decoder)
        do {
            self = try Self.decode(json)
        } catch {
            // Never fail a stream over one event whose shape changed upstream.
            self = .other(type: json["type"]?.stringValue ?? "", json)
        }
    }

    private static func decode(_ json: JSONValue) throws -> AgentEvent {
        let type = json["type"]?.stringValue ?? ""
        func value<T: Decodable>(_ key: String, as: T.Type = T.self) throws -> T {
            guard let field = json[key] else {
                throw DecodingError.keyNotFound(AnyKey(key), .init(codingPath: [], debugDescription: "\(type).\(key)"))
            }
            return try field.decode(as: T.self)
        }
        let string = { (key: String) in json[key]?.stringValue ?? "" }

        switch type {
        case "snapshot": return .snapshot(try json.decode(as: Snapshot.self))
        case "run_start": return .runStart(inputs: try value("inputs"))
        case "run_end": return .runEnd(inputs: try value("inputs"))
        case "turn_start": return .turnStart
        case "turn_end": return .turnEnd
        case "message_start": return .messageStart(try value("message"))
        case "message_update":
            return .messageUpdate(changes: try value("changes"), usage: (try? value("usage")) ?? Usage())
        case "message_end": return .messageEnd(try value("entry"))
        case "tool_execution_start":
            return .toolExecutionStart(
                callId: string("toolCallId"), toolName: string("toolName"), arguments: json["args"]?.objectValue ?? [:])
        case "tool_execution_update":
            var output: OutputChange?
            if let set = json["output"]?["set"]?.stringValue {
                output = .set(set)
            } else if let change = json["output"] {
                output = .append(change["append"]?.stringValue ?? "", trimStart: change["trimStart"]?.intValue ?? 0)
            }
            return .toolExecutionUpdate(
                callId: string("toolCallId"), toolName: string("toolName"), output: output, details: json["details"])
        case "tool_execution_end":
            return .toolExecutionEnd(
                callId: string("toolCallId"), toolName: string("toolName"), entry: try? value("entry", as: Entry.self))
        case "inbox_update": return .inboxUpdate(try value("items"))
        case "submission": return .submission(try value("record"))
        case "auto_retry_start":
            return .autoRetryStart(
                attempt: json["attempt"]?.intValue ?? 0,
                at: Date(timeIntervalSince1970: (json["at"]?.doubleValue ?? 0) / 1000),
                errorMessage: string("errorMessage"))
        case "auto_retry_end": return .autoRetryEnd(attempt: json["attempt"]?.intValue ?? 0)
        case "entry_appended": return .entryAppended(try value("entry"))
        case "agent_changed": return .agentChanged(try value("agent"))
        case "usage_changed": return .usageChanged(try value("usage"))
        case "task_failed":
            return .taskFailed(taskId: try value("taskId"), kind: string("kind"), message: string("message"))
        case "compaction_start":
            return .compactionStart(
                taskId: try value("taskId"), reason: string("reason"), blocking: json["blocking"]?.boolValue ?? false)
        case "compaction_end": return .compactionEnd(taskId: try value("taskId"), reason: string("reason"))
        default: return .other(type: type, json)
        }
    }
}

/// One conversation's agent events (pi-durable `AgentEventStream`): the snapshot at attachment, then one batch per
/// commit. When a consumer falls far behind, a batch holds a fresh ``AgentEvent/snapshot(_:)`` instead of the events it
/// missed. Iterate once; stopping the iteration (or cancelling its task) stops the stream.
public struct AgentEventStream: AsyncSequence, Sendable {
    public typealias Element = [AgentEvent]

    /// The `snapshot` event at attachment.
    public let snapshot: AgentEvent.Snapshot
    private let box: IteratorBox

    init(snapshot: AgentEvent.Snapshot, iterator: AsyncThrowingStream<[AgentEvent], Error>.AsyncIterator) {
        self.snapshot = snapshot
        box = IteratorBox(iterator)
    }

    public func makeAsyncIterator() -> Iterator {
        Iterator(box: box)
    }

    public struct Iterator: AsyncIteratorProtocol {
        let box: IteratorBox

        public mutating func next() async throws -> [AgentEvent]? {
            try await box.next()
        }
    }

    /// Holds the single underlying iterator.
    final class IteratorBox: @unchecked Sendable {
        private var iterator: AsyncThrowingStream<[AgentEvent], Error>.AsyncIterator

        init(_ iterator: AsyncThrowingStream<[AgentEvent], Error>.AsyncIterator) {
            self.iterator = iterator
        }

        func next() async throws -> [AgentEvent]? {
            try await iterator.next()
        }
    }
}
