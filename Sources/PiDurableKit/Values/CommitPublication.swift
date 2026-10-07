import Foundation

/// Every change of one successful commit (pi-durable `CommitPublication`), as delivered by ``Harness/commits()``.
public struct CommitPublication: Decodable, Sendable {
    /// The commit's sequence number; strictly increasing, with gaps permitted.
    public let seq: Int
    /// The commit's changes, in unspecified order.
    public let changes: [CommitChange]
}

/// One change of a commit (pi-durable `CommitChange`).
public enum CommitChange: Decodable, Sendable {
    case conversation(ConversationRecord)
    case entry(Entry)
    case task(TaskRecord)
    case submission(SubmissionRecord)
    /// A document was created, changed, or retired (`value` is `nil` when retired).
    case document(DocumentChange)
    /// A fork's document was initialized from its parent; read it to see its value.
    case documentCopy(JSONValue)
    /// A change of a kind this version of PiDurableKit does not know.
    case other(JSONValue)

    public init(from decoder: Decoder) throws {
        let json = try JSONValue(from: decoder)
        func value<T: Decodable>(_ type: T.Type) throws -> T { try (json["value"] ?? .null).decode(as: T.self) }
        do {
            switch json["type"]?.stringValue {
            case "conversation": self = .conversation(try value(ConversationRecord.self))
            case "entry": self = .entry(try value(Entry.self))
            case "task": self = .task(try value(TaskRecord.self))
            case "submission": self = .submission(try value(SubmissionRecord.self))
            case "document": self = .document(try json.decode(as: DocumentChange.self))
            case "document.copy": self = .documentCopy(json)
            default: self = .other(json)
            }
        } catch {
            self = .other(json)
        }
    }
}

/// A committed change of one document (pi-durable `DocumentCommitChange`).
public struct DocumentChange: Decodable, Sendable {
    /// The document's kind, such as `pi.agent` or your ``Document/kind``.
    public let kind: String
    /// The family member's key.
    public let key: String?
    /// The document record: its scope, history, and lifetime.
    public let record: JSONValue
    /// The conversation owning the document; `nil` for session documents.
    public let conversationId: ConversationID?
    /// The definition version of `value`; `nil` when retired.
    public let version: Int?
    /// The new value, or `nil` when this commit retired the document.
    public let value: JSONObject?
    /// The Chord operations of an ordinary update; empty for creation and retirement.
    public let ops: [JSONValue]

    private enum CodingKeys: String, CodingKey { case record, conversationId, version, value, ops }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        record = try container.decode(JSONValue.self, forKey: .record)
        kind = record["kind"]?.stringValue ?? ""
        key = record["key"]?.stringValue
        conversationId = try container.decodeIfPresent(ConversationID.self, forKey: .conversationId)
        version = try container.decodeIfPresent(Int.self, forKey: .version)
        value = try container.decodeIfPresent(JSONObject.self, forKey: .value)
        ops = try container.decodeIfPresent([JSONValue].self, forKey: .ops) ?? []
    }
}
