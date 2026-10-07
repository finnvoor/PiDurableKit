import Foundation

/// A JavaScript object Swift may use while a call, commit, or task phase runs.
struct ScopeHandle: Sendable {
    let engine: Engine
    let id: Int

    func call<Result: Decodable & Sendable>(
        _ method: String, _ arguments: BridgeArguments = [:], as type: Result.Type = Result.self
    ) async throws -> Result {
        var arguments = arguments
        arguments["handle"] = id
        return try await engine.call(method, arguments)
    }

    func perform(_ method: String, _ arguments: BridgeArguments = [:]) async throws {
        var arguments = arguments
        arguments["handle"] = id
        try await engine.perform(method, arguments)
    }

    /// Reads a document through the scope's committed reads.
    func document<Value>(_ document: Document<Value>, of owner: DocumentOwner, key: String?, asOf: EntryID? = nil) async throws -> Value {
        engine.host.register(document)
        let json: JSONValue = try await call(
            "scope.read", ["doc": try document.specification(), "owner": owner, "key": key, "asOf": asOf])
        return try document.decode(json)
    }

    /// Watches a document through the scope (pi-durable `watchDoc`); the stream ends with the call or phase.
    func values<Value>(of document: Document<Value>, owner: DocumentOwner, key: String?) -> AsyncThrowingStream<Value, Error> {
        engine.host.register(document)
        let specification: JSONValue
        do {
            specification = try document.specification()
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        return engine.stream(
            "scope.watchDoc", ["handle": id, "doc": specification, "owner": owner, "key": key], of: Value.self,
            bufferingPolicy: .bufferingNewest(1))
    }

    func memo<Value: Codable & Sendable>(_ name: String, as type: Value.Type) async throws -> Value? {
        let json: JSONValue = try await call("scope.memo", ["name": name])
        return json.isNull ? nil : try json.decode(as: Value.self)
    }

    func memo<Value: Codable & Sendable>(_ name: String, default candidate: Value) async throws -> Value {
        let json: JSONValue = try await call("scope.memo", ["name": name, "candidate": try JSONValue(encoding: candidate)])
        return try json.decode(as: Value.self)
    }

    func conversation(_ id: ConversationID, harness: Harness) async throws -> ConversationHandle? {
        let handle: Int? = try await call("scope.conversation", ["conversation": id])
        return handle.map { ConversationHandle(id: id, handle: ScopeHandle(engine: engine, id: $0), harness: harness) }
    }

    func commit<T: Sendable>(harness: Harness, _ body: @escaping @Sendable (Transaction) async throws -> T) async throws -> T {
        try await Transaction.run(harness: harness) { commit in
            try await perform("scope.commit", ["commit": commit])
        } body: { transaction, _ in
            (try await body(transaction), nil)
        }
    }
}

/// Where a ``Document`` lives.
public enum DocumentOwner: Sendable, Hashable, Encodable {
    /// One per harness.
    case session
    case conversation(ConversationID)
    case task(TaskID)

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyKey.self)
        switch self {
        case .session: try container.encode(true, forKey: AnyKey("session"))
        case .conversation(let id): try container.encode(id, forKey: AnyKey("conversation"))
        case .task(let id): try container.encode(id, forKey: AnyKey("task"))
        }
    }
}

/// An atomic write (pi-durable `Tx`): entries, conversations, tasks, and documents changed together, or not at all.
///
/// Get one from ``Harness/commit(_:)``, ``Conversation/commit(_:)``, ``ToolCallContext/commit(_:)``, or
/// ``TaskRun/commit(_:)``. A transaction is only valid inside its closure.
public struct Transaction: Sendable {
    let handle: ScopeHandle
    let harness: Harness

    /// Runs `body` in a commit started by `start`, which receives the id of the registered closure.
    /// `body` returns its value and the JSON it hands back to JavaScript.
    static func run<T: Sendable>(
        harness: Harness,
        start: (Int) async throws -> Void,
        body: @escaping @Sendable (Transaction, JSONValue) async throws -> (T, JSONValue?)
    ) async throws -> T {
        let box = ResultBox<T>()
        let engine = harness.engine
        let commit = engine.host.registerCommit { tx, extra in
            do {
                let (value, json) = try await body(Transaction(handle: ScopeHandle(engine: engine, id: tx), harness: harness), extra)
                box.set(.success(value))
                return json
            } catch {
                box.set(.failure(error))
                throw error
            }
        }
        defer { engine.host.removeCommit(commit) }
        do {
            try await start(commit)
        } catch {
            // Prefer the Swift error the closure threw over its JavaScript rendering.
            if case .failure(let original)? = box.get() { throw original }
            throw error
        }
        guard case .success(let value)? = box.get() else {
            throw PiDurableError.runtime("The commit finished without running its closure")
        }
        return value
    }

    // MARK: Reading

    public func conversation(_ id: ConversationID) async throws -> ConversationRecord? {
        try await handle.call("tx.conversation", ["conversation": id])
    }

    public func entry(_ id: EntryID) async throws -> Entry? {
        try await handle.call("tx.entry", ["entry": id])
    }

    public func task(_ id: TaskID) async throws -> TaskRecord? {
        try await handle.call("tx.task", ["task": id])
    }

    /// Conversations in ID order (oldest first by default), optionally only those owned by a task or created by a
    /// conversation's tasks.
    public func conversations(
        ownedBy task: TaskID? = nil, ownerConversation: ConversationID? = nil, order: ScanOrder? = nil, limit: Int = 100,
        after cursor: Cursor? = nil
    ) async throws -> Page<ConversationRecord> {
        try await handle.call(
            "tx.scanConversations",
            ["ownerTask": task, "ownerConversation": ownerConversation, "order": order, "limit": limit, "cursor": cursor])
    }

    /// A conversation's visible history, newest first by default.
    public func entries(
        in conversation: ConversationID, order: ScanOrder? = nil, limit: Int = 50, after cursor: Cursor? = nil
    ) async throws -> Page<Entry> {
        try await handle.call(
            "tx.scanEntries", ["conversation": conversation, "order": order, "limit": limit, "cursor": cursor])
    }

    /// Task records matching every given filter.
    public func tasks(_ query: TaskQuery = TaskQuery(), limit: Int = 100, after cursor: Cursor? = nil) async throws -> Page<TaskRecord> {
        try await handle.call("tx.scanTasks", ["query": query, "limit": limit, "cursor": cursor])
    }

    // MARK: Writing

    /// Creates a conversation, owned by `task` (a subagent's conversation) or by no one.
    public func createConversation(ownedBy task: TaskID? = nil) async throws -> ConversationRecord {
        try await handle.call("tx.createConversation", ["ownerTask": task])
    }

    /// Forks `conversation` at `entry`.
    public func fork(_ conversation: ConversationID, at entry: EntryID, ownedBy task: TaskID? = nil) async throws -> ConversationRecord {
        try await handle.call("tx.forkConversation", ["conversation": conversation, "at": entry, "ownerTask": task])
    }

    /// Appends an entry directly, without the inbox. Prefer ``Conversation/write(_:requestId:)`` outside transactions.
    @discardableResult
    public func append(_ entry: EntryDraft, to conversation: ConversationID) async throws -> Entry {
        try await handle.call("tx.appendEntry", ["conversation": conversation, "entry": entry])
    }

    /// Appends a typed entry.
    @discardableResult
    public func append<Data>(_ type: EntryType<Data>, _ data: Data, to conversation: ConversationID, model: [Message]? = nil)
        async throws -> Entry
    {
        try await append(try type.draft(data, model: model), to: conversation)
    }

    /// Creates a durable task of an installed ``TaskType``.
    ///
    /// - Parameters:
    ///   - type: The installed task type.
    ///   - input: The task's input.
    ///   - conversation: The task's conversation; defaults to the commit's conversation, if it has one.
    ///   - task: The owning task, for child tasks; by default the conversation owns it.
    ///   - background: Survives the conversation's abort and does not keep it busy.
    @discardableResult
    public func createTask<Input, State, Result>(
        _ type: TaskType<Input, State, Result>, input: Input, in conversation: ConversationID? = nil,
        ownedBy task: TaskID? = nil, background: Bool = false
    ) async throws -> TaskID {
        try await handle.call(
            "tx.createTask",
            [
                "task": type.name, "input": try JSONValue(encoding: input), "conversation": conversation, "ownerTask": task,
                "background": background,
            ])
    }

    /// Changes a conversation's agent in this commit.
    public func configure(_ conversation: ConversationID, _ change: AgentChange) async throws {
        try await handle.perform("tx.configure", ["conversation": conversation, "change": change])
    }

    // MARK: Documents

    /// The document's value in this transaction, created when absent (from `seed` for a family with
    /// `initialForSeed`).
    public func document<Value>(_ document: Document<Value>, of owner: DocumentOwner, key: String? = nil, seed: JSONValue? = nil)
        async throws -> Value
    {
        handle.engine.host.register(document)
        let json: JSONValue = try await handle.call(
            "tx.readDoc", ["doc": try document.specification(), "owner": owner, "key": key, "seed": seed])
        return try document.decode(json)
    }

    /// Replaces the document's value. Only the parts that changed are stored.
    public func setDocument<Value>(
        _ document: Document<Value>, _ value: Value, of owner: DocumentOwner, key: String? = nil, seed: JSONValue? = nil
    ) async throws {
        handle.engine.host.register(document)
        try await handle.perform(
            "tx.writeDoc",
            ["doc": try document.specification(), "owner": owner, "key": key, "seed": seed, "value": try document.encode(value)])
    }

    /// Changes the document's value.
    @discardableResult
    public func updateDocument<Value>(
        _ document: Document<Value>, of owner: DocumentOwner, key: String? = nil, seed: JSONValue? = nil,
        _ change: (inout Value) throws -> Void
    ) async throws -> Value {
        var value = try await self.document(document, of: owner, key: key, seed: seed)
        try change(&value)
        try await setDocument(document, value, of: owner, key: key, seed: seed)
        return value
    }

    /// Retires the document; a later access starts again from the initial value.
    public func retireDocument<Value>(_ document: Document<Value>, of owner: DocumentOwner, key: String? = nil) async throws {
        try await handle.perform("tx.retireDoc", ["doc": try document.specification(), "owner": owner, "key": key])
    }
}

/// The direction of a scan (pi-durable `ScanOrder`).
public enum ScanOrder: String, Codable, Sendable {
    case ascending, descending
}

/// Filters of ``Transaction/tasks(_:limit:after:)``.
public struct TaskQuery: Encodable, Sendable, Hashable {
    public var conversationId: ConversationID?
    /// The task definition's name.
    public var kind: String?
    /// `pending`, `running`, `waiting`, `completing`, or `terminal`.
    public var status: String?
    public var abortRequested: Bool?
    public var background: Bool?
    /// Oldest first by default.
    public var order: ScanOrder?

    public init(
        conversationId: ConversationID? = nil, kind: String? = nil, status: String? = nil, abortRequested: Bool? = nil,
        background: Bool? = nil, order: ScanOrder? = nil
    ) {
        self.order = order
        self.conversationId = conversationId
        self.kind = kind
        self.status = status
        self.abortRequested = abortRequested
        self.background = background
    }
}

/// An existing conversation, as seen from a running tool call or task phase (pi-durable `ConversationHandle`).
/// Its operations fail once the call or phase has ended; the work it admitted stays durable.
public struct ConversationHandle: Sendable, Identifiable {
    public let id: ConversationID
    let handle: ScopeHandle
    let harness: Harness

    /// Admits user input, like `Conversation.submit(_:whenBusy:requestId:)`.
    @discardableResult
    public func submit(_ text: String, whenBusy: Conversation.WhenBusy = .followUp, requestId: String? = nil) async throws
        -> Submission
    {
        var submission: JSONObject = ["type": "input", "content": .string(text), "whenBusy": .string(whenBusy.rawValue)]
        if let requestId { submission["requestId"] = .string(requestId) }
        let id: SubmissionID = try await handle.call("conversationHandle.submit", ["submission": JSONValue.object(submission)])
        return Submission(harness: harness, id: id)
    }

    /// Withdraws queued inputs and aborts the conversation's current work.
    public func abort(background: Bool = false) async throws {
        try await handle.perform("conversationHandle.abort", ["background": background])
    }

    /// Waits until the conversation has no running work.
    public func waitForIdle() async throws {
        try await handle.perform("conversationHandle.waitForIdle")
    }

    /// The conversation as a regular ``Conversation``, usable after the call or phase ends.
    public var conversation: Conversation { Conversation(harness: harness, id: id) }
}

/// Holds a commit closure's outcome across the bridge.
final class ResultBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<T, Error>?

    func set(_ value: Result<T, Error>) { lock.withLock { self.value = value } }
    func get() -> Result<T, Error>? { lock.withLock { value } }
}
