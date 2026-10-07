import Foundation

/// Your own typed state, stored next to the transcript and changed in atomic commits (pi-durable `defineDoc` and
/// `defineDocFamily`).
///
/// ```swift
/// struct Todos: Codable, Sendable { var items: [String] = [] }
/// let todos = Document("app.todos", initial: Todos())
///
/// try await conversation.update(todos) { $0.items.append("Write docs") }
/// let current = try await conversation.document(todos)
/// ```
///
/// The value must encode as a JSON object. Each commit stores only what changed.
public struct Document<Value: Codable & Sendable>: Sendable {
    /// What a document belongs to.
    public enum Scope: String, Sendable {
        /// One per conversation (the default). Address it with ``DocumentOwner/conversation(_:)``.
        case conversation
        /// One per harness. Address it with ``DocumentOwner/session``.
        case session
        /// One per durable task. Address it with ``DocumentOwner/task(_:)``.
        case task
    }

    /// How much history a conversation document keeps.
    public enum History: String, Sendable {
        /// Only the current value.
        case latest
        /// Every value stays readable as of any entry, with ``Conversation/document(_:key:asOf:)``.
        case rewindable
    }

    /// What a fork of the conversation starts with.
    public enum Fork: String, Sendable {
        /// The parent's current value.
        case current
        /// The initial value.
        case initial
        /// The parent's value as of the fork entry (rewindable documents only).
        case asOf
    }

    /// The stable stored kind; part of your storage format.
    public let kind: String
    /// The version of the stored shape. Raise it and pass `migrate` when the shape changes.
    public let version: Int
    public let scope: Scope
    public let history: History
    public let fork: Fork
    /// Whether this is a family of documents addressed by a string key (pi-durable `defineDocFamily`).
    public let keyed: Bool
    public let initial: Value
    let migrate: (@Sendable (JSONObject, Int) throws -> Value)?
    let initialForSeed: (@Sendable (JSONValue) throws -> Value)?
    let checkpointWhen: (@Sendable (JSONObject, [JSONValue], Int) -> Bool)?

    /// - Parameters:
    ///   - kind: The stable stored kind.
    ///   - version: The version of the stored shape.
    ///   - scope: What the document belongs to.
    ///   - history: How much history a conversation document keeps.
    ///   - fork: What a fork of the conversation starts with.
    ///   - keyed: Makes this a family: one value per key, such as per file or per contact.
    ///   - initialForSeed: For families, the value a new member starts with, from the `seed` its first write passes
    ///     (pi-durable `initial(seed)`); without it, members start from `initial`.
    ///   - initial: The value of a document that was never written.
    ///   - migrate: Upgrades a stored value written by an older `version`; receives the stored JSON and its version.
    ///   - checkpointWhen: Return `true` to store a change as a complete value instead of a delta; receives the new
    ///     value, the change's operations, and how many deltas are stored since the last complete value.
    public init(
        _ kind: String,
        version: Int = 1,
        scope: Scope = .conversation,
        history: History = .latest,
        fork: Fork = .current,
        keyed: Bool = false,
        initial: Value,
        initialForSeed: (@Sendable (_ seed: JSONValue) throws -> Value)? = nil,
        migrate: (@Sendable (_ stored: JSONObject, _ fromVersion: Int) throws -> Value)? = nil,
        checkpointWhen: (@Sendable (_ value: JSONObject, _ ops: [JSONValue], _ deltasSinceBase: Int) -> Bool)? = nil
    ) {
        self.initialForSeed = initialForSeed
        self.checkpointWhen = checkpointWhen
        self.kind = kind
        self.version = version
        self.scope = scope
        self.history = history
        self.fork = fork
        self.keyed = keyed
        self.initial = initial
        self.migrate = migrate
    }

    func specification() throws -> JSONValue {
        var json: JSONObject = [
            "kind": .string(kind),
            "version": .number(Double(version)),
            "scope": .string(scope.rawValue),
            "initial": try encode(initial),
            "keyed": .bool(keyed),
            "migrates": .bool(migrate != nil),
            "seeded": .bool(initialForSeed != nil),
            "checkpoints": .bool(checkpointWhen != nil),
        ]
        if scope == .conversation {
            json["history"] = .string(history.rawValue)
            json["fork"] = .string(fork.rawValue)
        }
        return .object(json)
    }

    func encode(_ value: Value) throws -> JSONValue {
        let json = try JSONValue(encoding: value)
        guard case .object = json else { throw PiDurableError.runtime("Document \(kind) must encode as a JSON object") }
        return json
    }

    func decode(_ json: JSONValue) throws -> Value {
        try json.decode(as: Value.self)
    }

    /// The definition's Swift callbacks as JSON in, JSON out, for the bridge.
    var callbacks: DocumentCallbacks {
        var migrateJSON: (@Sendable (JSONObject, Int) throws -> JSONValue)?
        if let migrate {
            migrateJSON = { stored, version in try JSONValue(encoding: migrate(stored, version)) }
        }
        var initialJSON: (@Sendable (JSONValue) throws -> JSONValue)?
        if let initialForSeed {
            initialJSON = { seed in try JSONValue(encoding: initialForSeed(seed)) }
        }
        return DocumentCallbacks(migrate: migrateJSON, initialForSeed: initialJSON, checkpointWhen: checkpointWhen)
    }
}

/// A document definition's callbacks, kept by kind for JavaScript's synchronous calls.
struct DocumentCallbacks: Sendable {
    let migrate: (@Sendable (JSONObject, Int) throws -> JSONValue)?
    let initialForSeed: (@Sendable (JSONValue) throws -> JSONValue)?
    let checkpointWhen: (@Sendable (JSONObject, [JSONValue], Int) -> Bool)?
}

/// A typed transcript entry kind (pi-durable `defineEntry`): app records such as notes or bookmarks that live in the
/// transcript, optionally contributing messages to the model's context.
///
/// ```swift
/// struct Note: Codable, Sendable { var text: String }
/// let note = EntryType<Note>("app.note")
/// try await conversation.write(note, Note(text: "User opened settings"))
/// let notes = view.entries.compactMap { $0.data(as: note) }
/// ```
public struct EntryType<Data: Codable & Sendable>: Sendable, Hashable {
    public let kind: EntryKind

    public init(_ kind: EntryKind) {
        self.kind = kind
    }

    /// A draft of this kind.
    public func draft(_ data: Data, model: [Message]? = nil) throws -> EntryDraft {
        EntryDraft(kind: kind, data: try JSONValue(encoding: data), model: model)
    }
}

extension Entry {
    /// The entry's data, when the entry is of this type.
    public func data<Data>(as type: EntryType<Data>) -> Data? {
        guard kind == type.kind, let data else { return nil }
        return try? data.decode(as: Data.self)
    }
}
