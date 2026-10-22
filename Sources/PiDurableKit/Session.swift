import Foundation

// MARK: Custom storage

/// pi-durable's `Storage` interface implemented in Swift, for ``Storage/custom(_:)``: the atomic persistence boundary
/// of a session's records and documents.
///
/// Records cross as JSON exactly as pi-durable defines them (`ConversationRecord`, `EntryRecord`, `TaskRecord`,
/// `SubmissionRecord`, `DocumentRecord`, `StorageWrite`, `Page`, `StoredDocument`; see
/// `PiDurable.documentation/dist/types.d.ts`). Return `nil` for an absent record. Materialize a document by applying its
/// stored deltas to its base with ``Runtime/applyOperations(_:to:)``. Validate an implementation with
/// ``Runtime/runStorageConformance(only:_:)``.
///
/// Most apps want ``Storage/sqlite(database:tablePrefix:)`` or ``Storage/jsonl(in:directory:fsync:)`` instead, which keep this
/// format for you.
public protocol CustomStorage: Sendable {
    /// Atomically persists one batch of `StorageWrite`s and returns its commit sequence number.
    func commit(_ writes: [JSONValue]) async throws -> Int
    /// A fresh ID from the session-global numeric namespace.
    func mintId() async throws -> Int
    func conversation(_ id: Int) async throws -> JSONValue?
    /// A page of `ConversationRecord`s for a `ConversationQuery`.
    func scanConversations(_ query: JSONValue, limit: Int, cursor: JSONValue?) async throws -> JSONValue
    /// `{ entry, commitSeq }` of one entry; with `conversationId`, only when visible through its ancestry.
    func entry(_ id: Int, visibleFrom conversationId: Int?) async throws -> JSONValue?
    /// The newest visible entry with a `head` at or below the cutoff.
    func findLatestHeadMarker(in conversationId: Int, atOrBefore entryId: Int?) async throws -> JSONValue?
    func scanEntries(_ query: JSONValue, limit: Int, cursor: JSONValue?) async throws -> JSONValue
    func task(_ id: Int) async throws -> JSONValue?
    func scanTasks(_ query: JSONValue, limit: Int, cursor: JSONValue?) async throws -> JSONValue
    func submission(_ id: Int) async throws -> JSONValue?
    func scanSubmissions(_ query: JSONValue, limit: Int, cursor: JSONValue?) async throws -> JSONValue
    func submission(in conversationId: Int, requestId: String) async throws -> JSONValue?
    /// The `DocumentRecord` occupying a `DocumentAddress` at a `DocumentPoint` (a sequence number or `"current"`).
    func findDocument(_ address: JSONValue, at point: JSONValue) async throws -> JSONValue?
    /// The `StoredDocument` of one incarnation at a point.
    func document(_ id: Int, at point: JSONValue) async throws -> JSONValue?
    func scanDocuments(_ query: JSONValue, limit: Int, cursor: JSONValue?) async throws -> JSONValue
    /// Releases resources; later operations must fail.
    func close() async throws
}

// MARK: Plain sessions

/// A plain pi-durable session (pi-durable `createSession`): atomic commits of conversations, entries, and your
/// documents over one storage, without agents, models, or a task scheduler. Use it for durable app state that shares
/// pi-durable's storage formats, or to inspect a harness's storage offline.
///
/// Tasks can't run in a plain session: creating one fails, since no task is installed.
public final class Session: Sendable {
    let engine: Engine
    let id: Int

    private init(engine: Engine, id: Int) {
        self.engine = engine
        self.id = id
    }

    /// Opens a session over `storage`. Only one session or harness may use a storage at a time.
    ///
    /// - Parameters:
    ///   - storage: Where to keep records and documents.
    ///   - runtime: The JavaScript runtime to run in.
    ///   - clock: The session clock for task times, for tests; defaults to the system clock.
    ///   - documentRetention: How long a loaded document that nothing observes stays in memory; see
    ///     ``Settings/documentRetention``.
    ///   - timer: Arms the session's timers, such as the ones that free idle documents; see ``HarnessTimer``.
    public static func open(
        _ storage: Storage = .memory, runtime: Runtime = .shared, clock: (@Sendable () -> Date)? = nil,
        documentRetention: Duration? = nil, timer: HarnessTimer? = nil
    ) async throws -> Session {
        let engine = runtime.engine
        let id = await engine.makeObjectID()
        engine.host.registerHarness(id, extensions: [], callbacks: HarnessCallbacks(clock: clock, timer: timer))
        do {
            try await engine.perform(
                "session.open",
                [
                    "id": id, "storage": try storage.specification(engine.host), "clock": clock != nil,
                    "documentRetentionMs": documentRetention?.milliseconds, "timer": timer != nil,
                ])
        } catch {
            engine.host.removeHarness(id)
            throw error
        }
        return Session(engine: engine, id: id)
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

    /// Runs `body` in one atomic commit.
    @discardableResult
    public func commit<T: Sendable>(_ body: @escaping @Sendable (Transaction) async throws -> T) async throws -> T {
        try await Transaction.run(engine: engine) { commit in
            try await self.perform("harness.commit", ["commit": commit])
        } body: { transaction, _ in
            (try await body(transaction), nil)
        }
    }

    /// A document's committed value, or its initial value.
    public func document<Value>(
        _ document: Document<Value>, of owner: DocumentOwner = .session, key: String? = nil, asOf entry: EntryID? = nil
    ) async throws -> Value {
        engine.host.register(document)
        let json: JSONValue = try await call(
            "doc.read", ["doc": try document.specification(), "owner": owner, "key": key, "asOf": entry])
        return try document.decode(json)
    }

    /// Changes a document in one atomic commit and returns the new value.
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
        return engine.stream(
            "doc.watch", ["harness": id, "doc": specification, "owner": owner, "key": key], of: Value.self,
            bufferingPolicy: .bufferingNewest(1))
    }

    /// Every commit's changes, as soon as it is stored (pi-durable `subscribeCommits`).
    public func commits() -> AsyncThrowingStream<CommitPublication, Error> {
        engine.stream("harness.commits", ["harness": id])
    }

    /// Returns when the session starts closing (pi-durable `subscribeClose`), also when a storage failure closes it.
    public func closing() async throws {
        for try await _ in engine.stream("harness.closeEvents", ["harness": id], of: Bool.self) { return }
    }

    /// Returns once the session has closed, storage included, and why (pi-durable `Session.closed`).
    public func closed() async throws -> SessionEnd {
        try await sessionEnd(engine: engine, id: id)
    }

    /// Settles admitted commits and closes the storage.
    public func close() async throws {
        try await perform("harness.close")
        engine.host.removeHarness(id)
    }
}

extension Harness {
    /// Returns when the harness starts closing (pi-durable `subscribeClose`), for example to stop work that uses it;
    /// also when a storage failure closes it.
    public func closing() async throws {
        for try await _ in engine.stream("harness.closeEvents", ["harness": id], of: Bool.self) { return }
    }

    /// Returns once the harness has closed, storage included, and why (pi-durable `Session.closed`): after
    /// ``close()``, or after a storage call failed, which closes the harness by itself. Reopen a failed harness; it
    /// recovers from what was committed.
    public func closed() async throws -> SessionEnd {
        try await sessionEnd(engine: engine, id: id)
    }
}

/// Why a session or harness ended (pi-durable `SessionEnd`).
public enum SessionEnd: Sendable, Hashable {
    /// ``Harness/close()`` or ``Session/close()``.
    case closed
    /// A storage call failed, which fails the session and closes it; the message of that error.
    case failed(String)
}

private func sessionEnd(engine: Engine, id: Int) async throws -> SessionEnd {
    for try await end in engine.stream("harness.closed", ["harness": id], of: JSONValue.self) {
        if end["reason"]?.stringValue == "failed" { return .failed(end["error"]?["message"]?.stringValue ?? "") }
        return .closed
    }
    throw CancellationError()
}

// MARK: Runtime utilities

/// The outcome of one pi-durable conformance case.
public struct ConformanceResult: Sendable, Hashable {
    public let name: String
    /// The failure, or `nil` when the case passed.
    public let failure: String?
    public var passed: Bool { failure == nil }
}

extension Runtime {
    /// Applies Chord operations (as found in ``CommitPublication`` document changes, ``ConversationChange/ops``, and
    /// stored document deltas) to a JSON value.
    public func applyOperations(_ operations: [JSONValue], to value: JSONValue?) async throws -> JSONValue {
        try await engine.call("chord.apply", ["value": value, "ops": operations])
    }

    /// Runs pi-durable's storage conformance suite (`@earendil-works/pi-durable/testing`), opening a fresh storage from
    /// `makeStorage` for every case, for example over your ``SQLiteDatabase`` or ``CustomStorage``.
    ///
    /// - Parameters:
    ///   - only: Run only the cases whose names contain one of these strings.
    ///   - makeStorage: A fresh, empty storage.
    public func runStorageConformance(
        only: [String]? = nil, _ makeStorage: @escaping @Sendable () async throws -> Storage
    ) async throws -> [ConformanceResult] {
        let router = engine.host
        let factory = router.registerConformanceFactory { try JSONValue(encoding: try await makeStorage().specification(router)) }
        defer { router.removeConformanceFactory(factory) }
        return try await results(engine.stream("conformance.storage", ["factory": factory, "only": only], of: JSONValue.self))
    }

    /// Runs pi-durable's execution environment conformance suite, building a fresh environment from
    /// `makeEnvironment` for every case: its `cwd` (`/` for a directory or custom environment) must be an empty,
    /// writable directory.
    ///
    /// - Parameters:
    ///   - shell: Program and flag that run a POSIX shell script; default `["sh", "-c"]`.
    ///   - symlinks: Whether the shell's `ln -s` creates symbolic links; default `true`.
    ///   - listFiles: Whether to check ``ExecutionEnv/listFiles(_:options:)``, which every PiDurableKit environment
    ///     implements; default `true`.
    ///   - only: Run only the cases whose names contain one of these strings.
    ///   - makeEnvironment: A fresh environment.
    public func runEnvironmentConformance(
        shell: [String]? = nil, symlinks: Bool? = nil, listFiles: Bool = true, only: [String]? = nil,
        _ makeEnvironment: @escaping @Sendable () async throws -> ExecutionEnvironment
    ) async throws -> [ConformanceResult] {
        let router = engine.host
        let factory = router.registerConformanceFactory { try await makeEnvironment().specification(router) }
        defer { router.removeConformanceFactory(factory) }
        return try await results(engine.stream(
            "conformance.env", ["factory": factory, "shell": shell, "symlinks": symlinks, "listFiles": listFiles, "only": only],
            of: JSONValue.self))
    }

    private func results(_ stream: AsyncThrowingStream<JSONValue, Error>) async throws -> [ConformanceResult] {
        var results: [ConformanceResult] = []
        for try await item in stream {
            let error = item["error"].flatMap { $0.isNull ? JSONValue?.none : $0 }
            results.append(ConformanceResult(
                name: item["name"]?.stringValue ?? "",
                failure: error.map { error in
                    let name = error["name"]?.stringValue ?? "Error"
                    let message = error["message"]?.stringValue ?? error.jsonString
                    return "\(name): \(message)"
                }))
        }
        return results
    }
}
