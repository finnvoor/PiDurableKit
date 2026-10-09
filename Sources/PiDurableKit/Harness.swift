import Foundation

/// Where a harness keeps its conversations, tasks, and documents.
public struct Storage: Sendable {
    enum Kind {
        case memory
        case sqlite(URL)
        case jsonl(URL, fsync: Bool)
        case database(any SQLiteDatabase)
    }

    let kind: Kind

    /// Keeps everything in memory; nothing survives the process.
    public static let memory = Storage(kind: .memory)

    /// One SQLite database file (WAL mode). Conversations survive restarts and crashes; reopen the same file and
    /// call ``Harness/resume()`` (the default) to continue unfinished runs.
    public static func sqlite(at url: URL) -> Storage {
        Storage(kind: .sqlite(url))
    }

    /// Append-only JSONL files in one directory (pi-durable `JsonlStorage`).
    ///
    /// - Parameters:
    ///   - directory: The storage directory.
    ///   - fsync: Flush every file before each commit marker, so commits also survive power loss.
    public static func jsonl(at directory: URL, fsync: Bool = false) -> Storage {
        Storage(kind: .jsonl(directory, fsync: fsync))
    }

    /// pi-durable's portable SQLite storage over a database you implement.
    public static func sqlite(database: some SQLiteDatabase) -> Storage {
        Storage(kind: .database(database))
    }

    func specification(_ router: HostRouter) throws -> BridgeArguments {
        switch kind {
        case .database(let database): ["kind": "database", "database": router.register(database)]
        default: try specification
        }
    }

    /// The file system path two harnesses must not share, if the storage has one.
    var lockPath: String? {
        switch kind {
        case .sqlite(let url), .jsonl(let url, _): url.path(percentEncoded: false)
        case .memory, .database: nil
        }
    }

    var specification: BridgeArguments {
        get throws {
            switch kind {
            case .memory: return ["kind": "memory"]
            case .database: throw PiDurableError.runtime("A database storage needs a runtime")
            case .sqlite(let url): return ["kind": "sqlite", "path": url.path(percentEncoded: false)]
            case .jsonl(let url, let fsync):
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                return ["kind": "jsonl", "path": try FileOperations.realPath(url.path(percentEncoded: false)), "fsync": fsync]
            }
        }
    }
}

/// Where tools such as ``Extension/codingTools(name:)`` read and write files (pi-durable `HarnessOptions.env`).
public struct ExecutionEnvironment: Sendable {
    enum Kind {
        case directory(URL)
        case perConversation(@Sendable (EnvironmentTarget) async throws -> ExecutionEnvironment?)
    }

    let kind: Kind

    /// A sandbox rooted at `directory`: the agent sees it as `/`, a conversation's `cwd` is a path inside it, and
    /// no path can leave it. There is no shell.
    public static func directory(_ directory: URL) -> ExecutionEnvironment {
        ExecutionEnvironment(kind: .directory(directory))
    }

    /// Chooses each conversation's environment when it is used, like pi-durable's `env` function: for example a
    /// sandbox per conversation, found through a document. Return `nil` for no environment; return a
    /// ``directory(_:)``.
    public static func perConversation(
        _ choose: @escaping @Sendable (EnvironmentTarget) async throws -> ExecutionEnvironment?
    ) -> ExecutionEnvironment {
        ExecutionEnvironment(kind: .perConversation(choose))
    }

    /// The sandbox's real root directory.
    func root() throws -> String {
        guard case .directory(let url) = kind else {
            throw PiDurableError.runtime("A per-conversation environment must choose a directory environment")
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return try FileOperations.realPath(url.path(percentEncoded: false))
    }

    var specification: BridgeArguments {
        get throws {
            switch kind {
            case .directory: ["root": try root()]
            case .perConversation: ["perConversation": true]
            }
        }
    }
}

/// What an ``ExecutionEnvironment/perConversation(_:)`` chooses an environment for (pi-durable `EnvTarget`).
public struct EnvironmentTarget: Sendable {
    public let conversationId: ConversationID
    /// The conversation's agent `cwd`.
    public let cwd: String?
    let handle: ScopeHandle

    /// A document, as committed.
    public func document<Value>(_ document: Document<Value>, of owner: DocumentOwner? = nil, key: String? = nil) async throws
        -> Value
    {
        try await handle.document(document, of: owner ?? .conversation(conversationId), key: key)
    }
}

/// A durable agent harness: one open storage plus the machinery that runs agents on it.
///
/// Conversations, model turns, tool calls, and your own documents are committed to storage before anything is shown.
/// If the app is killed mid-turn, reopening the storage picks the work up where it stopped.
///
/// ```swift
/// let models = Models(credentials: .keychain)
/// let harness = try await Harness.open(.sqlite(at: url), models: models, extensions: [assistant])
/// let root = try await harness.root(agent: AgentChange(model: .anthropic("claude-sonnet-4-5")))
///
/// let submission = try await root.submit("What is the capital of France?")
/// let settled = try await submission.wait()
/// if case .done(_, let answer?) = settled.status {
///     let entry = try await root.commit { tx in try await tx.entry(answer) }
///     print(entry?.assistantMessage?.text ?? "")
/// }
/// ```
public final class Harness: Sendable {
    public let models: Models
    let id: Int
    private let storageLock: StorageLock?
    var engine: Engine { models.runtime.engine }

    private init(models: Models, id: Int, storageLock: StorageLock?) {
        self.models = models
        self.id = id
        self.storageLock = storageLock
    }

    /// Opens a harness over `storage`.
    ///
    /// - Parameters:
    ///   - storage: Where to keep conversations. Only one harness may use a storage at a time: opening a SQLite or
    ///     JSONL storage that another harness has open, in this process or another, throws.
    ///   - models: Model access.
    ///   - extensions: Extensions to install, in order. Change them later with ``install(_:)``.
    ///   - settings: Run policy shared by every conversation.
    ///   - environment: Where file tools work; without one, they fail with an error result.
    ///   - resume: Whether to start the task scheduler at once, continuing work a previous process left unfinished.
    ///   - onConversationCreated: Runs in every commit that creates or forks a conversation, including a tool's
    ///     ``Transaction/createConversation(ownedBy:)``, for example to give every conversation your documents.
    ///     Reading conversations, entries, or tasks there fails; documents work.
    ///   - clock: The harness clock, for tests; defaults to the system clock.
    ///   - onReport: Receives extension failures that do not fail the calling operation.
    public static func open(
        _ storage: Storage = .memory,
        models: Models,
        extensions: [Extension] = [],
        settings: Settings = Settings(),
        environment: ExecutionEnvironment? = nil,
        resume: Bool = true,
        onConversationCreated: (@Sendable (Transaction, ConversationRecord) async throws -> Void)? = nil,
        clock: (@Sendable () -> Date)? = nil,
        onReport: (@Sendable (String) -> Void)? = nil
    ) async throws -> Harness {
        try await models.prepare()
        let engine = models.runtime.engine
        let id = await engine.makeObjectID()
        let lock = try storage.lockPath.map { try StorageLock(storagePath: $0) }
        let harness = Harness(models: models, id: id, storageLock: lock)
        engine.host.registerHarness(
            id, extensions: extensions,
            callbacks: HarnessCallbacks(
                onConversationCreated: onConversationCreated, clock: clock, onReport: onReport,
                environment: environment.flatMap { if case .perConversation(let choose) = $0.kind { choose } else { nil } }))
        engine.host.attachHarness(harness)
        do {
            try await engine.perform(
                "harness.open",
                [
                    "id": id,
                    "models": models.id,
                    "storage": try storage.specification(engine.host),
                    "extensions": extensions.map(\.specification),
                    "settings": settings,
                    "environment": try environment?.specification,
                    "resume": resume,
                    "conversationCreated": onConversationCreated != nil,
                    "clock": clock != nil,
                    "report": onReport != nil,
                ])
        } catch {
            engine.host.removeHarness(id)
            lock?.release()
            throw error
        }
        return harness
    }

    func call<Result: Decodable & Sendable>(_ method: String, _ arguments: BridgeArguments = [:]) async throws -> Result {
        var arguments = arguments
        arguments["harness"] = id
        return try await engine.call(method, arguments)
    }

    func perform(_ method: String, _ arguments: BridgeArguments = [:]) async throws {
        var arguments = arguments
        arguments["harness"] = id
        try await engine.perform(method, arguments)
    }

    // MARK: Conversations

    /// The root conversation, created with `agent` on first use.
    ///
    /// - Parameters:
    ///   - agent: The agent of a new root conversation.
    ///   - initialize: Runs in the creating commit, for example to seed documents.
    public func root(
        agent: AgentChange? = nil, initialize: (@Sendable (Transaction, ConversationID) async throws -> Void)? = nil
    ) async throws -> Conversation {
        try await creating(initialize) { initializer in
            try await self.call("conversation.root", ["agent": agent, "initialize": initializer])
        }
    }

    /// Calls `create` with the id of the registered `initialize` commit, if any.
    func creating(
        _ initialize: (@Sendable (Transaction, ConversationID) async throws -> Void)?,
        _ create: (Int?) async throws -> ConversationID
    ) async throws -> Conversation {
        guard let initialize else { return Conversation(harness: self, id: try await create(nil)) }
        let commit = engine.host.registerCommit { [self] tx, extra in
            let transaction = Transaction(handle: ScopeHandle(engine: engine, id: tx), harness: self)
            try await initialize(transaction, ConversationID(extra["conversation"]?.intValue ?? 0))
            return nil
        }
        defer { engine.host.removeCommit(commit) }
        return Conversation(harness: self, id: try await create(commit))
    }

    /// An existing conversation, or `nil` when there is none with this ID.
    public func conversation(_ id: ConversationID) async throws -> Conversation? {
        let exists: Bool = try await call("conversation.exists", ["conversation": id])
        return exists ? Conversation(harness: self, id: id) : nil
    }

    /// Creates a new, ownerless conversation.
    ///
    /// - Parameters:
    ///   - agent: The new conversation's agent.
    ///   - initialize: Runs in the creating commit, for example to seed documents.
    public func createConversation(
        agent: AgentChange? = nil, initialize: (@Sendable (Transaction, ConversationID) async throws -> Void)? = nil
    ) async throws -> Conversation {
        try await creating(initialize) { initializer in
            try await self.call("conversation.create", ["agent": agent, "initialize": initializer])
        }
    }

    /// Runs `body` in one atomic commit. Everything it writes is stored together, or nothing is.
    @discardableResult
    public func commit<T: Sendable>(_ body: @escaping @Sendable (Transaction) async throws -> T) async throws -> T {
        try await commit(in: nil, body)
    }

    func commit<T: Sendable>(in conversation: ConversationID?, _ body: @escaping @Sendable (Transaction) async throws -> T)
        async throws -> T
    {
        try await Transaction.run(harness: self) { commit in
            try await self.perform("harness.commit", ["commit": commit, "conversation": conversation])
        } body: { transaction, _ in
            (try await body(transaction), nil)
        }
    }

    /// Attaches to one conversation's agent events (pi-durable `watchEvents`): ``AgentEventStream/snapshot`` is the
    /// state at attachment, and iterating yields one batch of events per later commit.
    ///
    /// ```swift
    /// let stream = try await harness.watchEvents(root.id)
    /// initialize(stream.snapshot)
    /// for try await events in stream {
    ///     for event in events { print(event) }
    /// }
    /// ```
    public func watchEvents(_ conversation: ConversationID) async throws -> AgentEventStream {
        let batches = engine.stream("conversation.events", ["harness": id, "conversation": conversation], of: [AgentEvent].self)
        var iterator = batches.makeAsyncIterator()
        guard case .snapshot(let snapshot)? = try await iterator.next()?.first else {
            throw PiDurableError.runtime("The event stream did not start with a snapshot")
        }
        return AgentEventStream(snapshot: snapshot, iterator: iterator)
    }

    /// Reacquires a submission, for example to wait for it after a restart.
    public func submission(_ id: SubmissionID) -> Submission {
        Submission(harness: self, id: id)
    }

    // MARK: Extensions and settings

    /// Installs an extension, or replaces the installed one with the same name in place. Work that already started
    /// keeps the code it took; the next request or call uses the new one.
    public func install(_ extension: Extension) async throws {
        engine.host.install(`extension`, harness: id)
        try await perform("harness.install", ["extension": `extension`.specification])
    }

    /// Removes the installed extension with this name. Conversations that select it stop getting it until it is
    /// installed again.
    public func uninstall(_ name: String) async throws {
        try await perform("harness.uninstall", ["name": name])
        engine.host.uninstall(name, harness: id)
    }

    /// Removes an installed extension.
    public func uninstall(_ extension: Extension) async throws {
        try await uninstall(`extension`.name)
    }

    /// The names of the installed extensions, in install order.
    public func installedExtensions() async throws -> [String] {
        try await call("harness.extensions")
    }

    /// Replaces the run policy. It applies from the next time each setting is read.
    public func updateSettings(_ settings: Settings) async throws {
        try await perform("harness.setSettings", ["settings": settings])
    }

    // MARK: Lifecycle

    /// Starts the task scheduler, continuing any run the last process left unfinished. Idempotent.
    public func resume() async throws {
        try await perform("harness.resume")
    }

    /// Waits until no ownerless conversation has running work.
    public func waitForIdle() async throws {
        try await perform("harness.waitForIdle")
    }

    /// Total spend of every conversation.
    public func usage() async throws -> UsageState {
        try await call("harness.usage")
    }

    // MARK: Tasks

    /// A task's committed record.
    public func task(_ id: TaskID) async throws -> TaskRecord? {
        try await call("harness.task", ["task": id])
    }

    /// Waits for a task, such as a compaction, to be terminal, and returns its record.
    @discardableResult
    public func waitForTask(_ id: TaskID) async throws -> TaskRecord {
        try await call("harness.waitForTask", ["task": id])
    }

    /// Waits for a task and returns its outcome with a typed result.
    public func waitForTask<Result: Decodable & Sendable>(_ id: TaskID, as type: Result.Type) async throws -> TaskOutcome<Result> {
        guard let outcome = try await waitForTask(id).outcome(as: Result.self) else {
            throw PiDurableError.runtime("Task \(id) has no outcome")
        }
        return outcome
    }

    /// Aborts one task and the work it owns. Returns `marked`, or `terminal` when it had already ended.
    @discardableResult
    public func abortTask(_ id: TaskID) async throws -> String {
        try await call("harness.abortTask", ["task": id])
    }

    /// Every commit's changes, as soon as it is stored (pi-durable `subscribeCommits`): records and document
    /// operations, for example to replicate or sync a harness. Nothing is replayed; iteration starts with the next commit.
    public func commits() -> AsyncThrowingStream<CommitPublication, Error> {
        engine.stream("harness.commits", ["harness": id])
    }

    /// Every live task with its owner edges.
    public func taskGraph() async throws -> TaskGraph {
        try await call("harness.taskGraph")
    }

    /// The task graph after every commit that changes it, starting with the current one.
    public func taskGraphs() -> AsyncThrowingStream<TaskGraph, Error> {
        engine.stream("harness.watchTaskGraph", ["harness": id], bufferingPolicy: .bufferingNewest(1))
    }

    /// Live tasks and what the scheduler would do with each, and unsettled submissions. Runs no task code.
    public func inspect() async throws -> HarnessInspection {
        try await call("harness.inspect")
    }

    // MARK: Documents

    /// A document's committed value, or its initial value.
    ///
    /// - Parameters:
    ///   - document: The document.
    ///   - owner: The session, conversation, or task the document belongs to.
    ///   - key: The member of a keyed document family.
    ///   - entry: For rewindable conversation documents, the value as of this entry.
    public func document<Value>(
        _ document: Document<Value>, of owner: DocumentOwner = .session, key: String? = nil, asOf entry: EntryID? = nil
    ) async throws -> Value {
        engine.host.register(document)
        let json: JSONValue = try await call(
            "doc.read", ["doc": try document.specification(), "owner": owner, "key": key, "asOf": entry])
        return try document.decode(json)
    }

    /// Changes a document in one atomic commit and returns the new value. Only what changed is stored.
    ///
    /// - Parameters:
    ///   - document: The document.
    ///   - owner: The session, conversation, or task the document belongs to.
    ///   - key: The member of a keyed document family.
    ///   - seed: For a new member of a family with `initialForSeed`, the seed it starts from.
    ///   - change: Changes the value.
    @discardableResult
    public func update<Value>(
        _ document: Document<Value>, of owner: DocumentOwner = .session, key: String? = nil, seed: JSONValue? = nil,
        _ change: @escaping @Sendable (inout Value) throws -> Void
    ) async throws -> Value {
        engine.host.register(document)
        let router = engine.host
        let mutation = router.registerMutation { json in
            var value = try document.decode(json)
            try change(&value)
            return try document.encode(value)
        }
        defer { router.removeMutation(mutation) }
        let json: JSONValue = try await call(
            "doc.update",
            ["doc": try document.specification(), "owner": owner, "key": key, "seed": seed, "mutation": mutation])
        return try document.decode(json)
    }

    /// Retires a document; a later access starts again from the initial value.
    public func retire<Value>(_ document: Document<Value>, of owner: DocumentOwner = .session, key: String? = nil) async throws {
        try await perform("doc.retire", ["doc": try document.specification(), "owner": owner, "key": key])
    }

    /// A document's value after every commit that changes it, starting with the current one.
    public func values<Value>(of document: Document<Value>, owner: DocumentOwner = .session, key: String? = nil)
        -> AsyncThrowingStream<Value, Error>
    {
        engine.host.register(document)
        let specification: JSONValue
        do {
            specification = try document.specification()
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        let owner = owner
        return engine.stream(
            "doc.watch", ["harness": id, "doc": specification, "owner": owner, "key": key], of: Value.self,
            bufferingPolicy: .bufferingNewest(1))
    }

    /// Settles admitted work and closes the storage. Unfinished runs stay pending until the storage is opened again.
    public func close() async throws {
        try await perform("harness.close")
        engine.host.removeHarness(id)
        // Only a successful close proves the storage is shut. After a failed one the lock stays until deinit.
        storageLock?.release()
    }
}
