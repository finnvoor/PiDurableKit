import Foundation

/// A task's checkpoint: the state saved at every step. Like pi-durable's `S extends { phase: string }`, it names the
/// phase that runs next.
public protocol TaskCheckpoint: Codable, Sendable {
    var phase: String { get }
}

/// A durable state machine (pi-durable `defineTask`): it saves a checkpoint at every step, so a restarted app continues
/// from the last one.
///
/// ```swift
/// struct Checkout: TaskCheckpoint {
///     var phase: String
///     var payments: [TaskID] = []
/// }
///
/// let checkout = TaskType<[String], Checkout, [String]>(
///     "app.checkout", version: 1,
///     initial: { _ in Checkout(phase: "pay") },
///     abort: { run in try await run.commit { _, _ in .aborted(nil) } }
/// ) {
///     Phase("pay") { run in
///         try await run.commit { tx, current in
///             var payments: [TaskID] = []
///             for card in run.input {
///                 payments.append(try await tx.createTask(payment, input: card, ownedBy: current.id))
///             }
///             return .waiting(Checkout(phase: "decide", payments: payments), on: payments, policy: .failFast)
///         }
///     }
///     Phase("decide") { run in
///         let outcomes = try await run.outcomes(of: run.checkpoint.payments, as: String.self)
///         try await run.commit { _, _ in .completed(outcomes.compactMap(\.result)) }
///     }
/// }
/// ```
///
/// Install task types in an ``Extension``, then create tasks in a commit with
/// ``Transaction/createTask(_:input:in:ownedBy:background:abandonOnRestart:trace:links:)``. A phase runs again from its checkpoint after a crash, so it
/// must be safe to repeat up to its commit; ``TaskRun/memo(_:default:)`` keeps values stable across reruns.
public struct TaskType<Input: Codable & Sendable, Checkpoint: TaskCheckpoint, Result: Codable & Sendable>: Sendable {
    public typealias Handler = @Sendable (TaskRun<Input, Checkpoint, Result>) async throws -> Void

    /// The registered name; part of your storage format.
    public let name: String
    /// The version of the input and checkpoint shapes.
    public let version: Int
    let initial: @Sendable (Input) throws -> Checkpoint
    let phases: [String: Handler]
    let abort: Handler
    let migrate: (@Sendable (_ input: JSONValue, _ checkpoint: JSONValue, _ fromVersion: Int) throws -> (Input, Checkpoint))?

    /// - Parameters:
    ///   - name: The registered name; part of your storage format.
    ///   - version: The version of the input and checkpoint shapes.
    ///   - initial: The checkpoint a new task starts with (pi-durable `initial(input)`).
    ///   - abort: Runs when the task is aborted, after the work it owns has stopped; it must commit a terminal state.
    ///   - migrate: Upgrades a live task stored by an older version; receives its stored input, checkpoint, and version.
    ///   - phases: The phase handlers, by the phase names checkpoints use.
    public init(
        _ name: String,
        version: Int,
        initial: @escaping @Sendable (Input) throws -> Checkpoint,
        abort: @escaping Handler,
        migrate: (@Sendable (_ input: JSONValue, _ checkpoint: JSONValue, _ fromVersion: Int) throws -> (Input, Checkpoint))? = nil,
        @PhaseBuilder<Input, Checkpoint, Result> phases: () -> [Phase<Input, Checkpoint, Result>]
    ) {
        self.name = name
        self.version = version
        self.initial = initial
        self.phases = Dictionary(phases().map { ($0.name, $0.handler) }, uniquingKeysWith: { _, last in last })
        self.abort = abort
        self.migrate = migrate
    }

    var erased: AnyTaskType {
        let phases = phases
        let abort = abort
        let initial = initial
        let initialJSON: @Sendable (JSONValue) throws -> JSONValue = { input in
            try JSONValue(encoding: initial(try input.decode(as: Input.self)))
        }
        let run: @Sendable (String?, ScopeHandle, Harness, TaskRecord) async throws -> Void = { phase, handle, harness, record in
            let handler: Handler
            if let phase {
                guard let found = phases[phase] else { throw PiDurableError.notFound("Task phase \(phase) is not defined") }
                handler = found
            } else {
                handler = abort
            }
            try await handler(try TaskRun(handle: handle, harness: harness, record: record))
        }
        var migrateJSON: (@Sendable (JSONValue, JSONValue, Int) throws -> JSONValue)?
        if let migrate {
            migrateJSON = { input, checkpoint, version in
                let (newInput, newCheckpoint) = try migrate(input, checkpoint, version)
                return ["input": try JSONValue(encoding: newInput), "checkpoint": try JSONValue(encoding: newCheckpoint)]
            }
        }
        return AnyTaskType(
            name: name, version: version, phaseNames: phases.keys.sorted(), migrates: migrate != nil,
            initial: initialJSON, run: run, migrate: migrateJSON)
    }
}

/// One named step of a ``TaskType`` (an entry of pi-durable's `phases`).
public struct Phase<Input: Codable & Sendable, Checkpoint: TaskCheckpoint, Result: Codable & Sendable>: Sendable {
    let name: String
    let handler: TaskType<Input, Checkpoint, Result>.Handler

    public init(_ name: String, _ handler: @escaping TaskType<Input, Checkpoint, Result>.Handler) {
        self.name = name
        self.handler = handler
    }
}

@resultBuilder
public enum PhaseBuilder<Input: Codable & Sendable, Checkpoint: TaskCheckpoint, Result: Codable & Sendable> {
    public static func buildExpression(_ phase: Phase<Input, Checkpoint, Result>) -> Phase<Input, Checkpoint, Result> { phase }
    public static func buildBlock(_ phases: Phase<Input, Checkpoint, Result>...) -> [Phase<Input, Checkpoint, Result>] { phases }
}

/// A task type with its types erased, as stored in an ``Extension``.
public struct AnyTaskType: Sendable {
    public let name: String
    public let version: Int
    let phaseNames: [String]
    let migrates: Bool
    let initial: @Sendable (JSONValue) throws -> JSONValue
    /// Runs a phase, or with `nil` the abort handler.
    let run: @Sendable (String?, ScopeHandle, Harness, TaskRecord) async throws -> Void
    let migrate: (@Sendable (JSONValue, JSONValue, Int) throws -> JSONValue)?

    var specification: BridgeArguments {
        ["name": name, "version": version, "phases": phaseNames, "migrates": migrates]
    }
}

/// The state a ``TaskRun`` commits (pi-durable `NextTaskState`).
public enum NextState<Checkpoint: TaskCheckpoint, Result: Encodable & Sendable>: Sendable {
    /// Continue in `checkpoint.phase`.
    case running(Checkpoint)
    /// Run no code until the tasks in `on` are done, then continue in `checkpoint.phase`.
    case waiting(Checkpoint, on: [TaskID], policy: JoinPolicy)
    /// Run no code until the harness clock reaches `until`, then continue in `checkpoint.phase`. The task holds no
    /// invocation meanwhile, and the sleep survives restarts. An abort doesn't wait for it.
    case sleeping(Checkpoint, until: Date)
    case completed(Result)
    /// An expected failure, recorded as the task's outcome.
    case failed(String, detail: JSONValue? = nil)
    case aborted(String?)

    func json() throws -> JSONValue {
        switch self {
        case .running(let checkpoint):
            return ["status": "running", "checkpoint": try JSONValue(encoding: checkpoint)]
        case .waiting(let checkpoint, let on, let policy):
            return [
                "status": "waiting", "checkpoint": try JSONValue(encoding: checkpoint), "on": try JSONValue(encoding: on),
                "policy": .string(policy.rawValue),
            ]
        case .sleeping(let checkpoint, let until):
            return [
                "status": "sleeping", "checkpoint": try JSONValue(encoding: checkpoint),
                "until": .number(until.timeIntervalSince1970 * 1000),
            ]
        case .completed(let result):
            return ["status": "terminal", "outcome": ["status": "completed", "result": try JSONValue(encoding: result)]]
        case .failed(let message, let detail):
            var error: JSONObject = ["message": .string(message)]
            if let detail { error["detail"] = detail }
            return ["status": "terminal", "outcome": ["status": "failed", "error": .object(error)]]
        case .aborted(let reason):
            var outcome: JSONObject = ["status": "aborted"]
            if let reason { outcome["reason"] = .string(reason) }
            return ["status": "terminal", "outcome": .object(outcome)]
        }
    }
}

/// When a waiting task resumes.
public enum JoinPolicy: String, Codable, Sendable {
    /// Once every task it waits on is done.
    case allSettled
    /// Once every task is done, or at the first failure, which also aborts the others.
    case failFast
}

/// One invocation of a task phase (pi-durable `TaskRuntime`). Valid until the phase handler returns.
public struct TaskRun<Input: Codable & Sendable, Checkpoint: TaskCheckpoint, Result: Codable & Sendable>: Sendable {
    public let taskId: TaskID
    public let conversationId: ConversationID
    public let input: Input
    /// The task's checkpoint when the phase started (pi-durable `task.state.checkpoint`).
    public let checkpoint: Checkpoint
    /// The task's record when the phase started.
    public let record: TaskRecord
    public let harness: Harness
    let handle: ScopeHandle

    init(handle: ScopeHandle, harness: Harness, record: TaskRecord) throws {
        self.handle = handle
        self.harness = harness
        self.record = record
        taskId = record.id
        conversationId = record.conversationId
        input = try record.input.decode(as: Input.self)
        checkpoint = try (record.checkpoint ?? .null).decode(as: Checkpoint.self)
    }

    /// Commits on the session line. Returning a state replaces the task's state in the same commit; returning `nil`
    /// leaves it unchanged. `tx.createTask` defaults to the task's conversation.
    public func commit(_ body: @escaping @Sendable (Transaction, TaskRecord) async throws -> NextState<Checkpoint, Result>?) async throws {
        let _: Void = try await Transaction.run(engine: harness.engine) { commit in
            try await handle.perform("scope.commit", ["commit": commit])
        } body: { transaction, extra in
            let current = try (extra["current"] ?? .null).decode(as: TaskRecord.self)
            return ((), try await body(transaction, current)?.json())
        }
    }

    /// Runs the handlers other extensions registered for this task's hook `name` with `Hook.task(_:_:_:)`, in
    /// extension order, and returns their results (`null` for handlers that returned `nil`). Like pi-durable
    /// `runtime.hooks.each`: a handler's failure is reported, not thrown.
    public func hooks(_ name: String, arguments: some Encodable & Sendable) async throws -> [JSONValue] {
        try await handle.call("scope.hooks", ["name": name, "arguments": try JSONValue(encoding: arguments)])
    }

    /// Runs the hook's handlers and decodes their results as `Output`; `nil` for handlers that returned `nil`.
    public func hooks<Output: Decodable & Sendable>(
        _ name: String, arguments: some Encodable & Sendable, as type: Output.Type
    ) async throws -> [Output?] {
        try await hooks(name, arguments: arguments).map { $0.isNull ? nil : try $0.decode(as: Output.self) }
    }

    /// Outcomes of terminal tasks, in order; use after a wait.
    public func outcomes(of tasks: [TaskID]) async throws -> [TaskOutcome<JSONValue>] {
        try await handle.call("scope.outcomes", ["tasks": tasks])
    }

    /// Outcomes of terminal tasks with results of type `R`.
    public func outcomes<R: Decodable & Sendable>(of tasks: [TaskID], as type: R.Type) async throws -> [TaskOutcome<R>] {
        try await handle.call("scope.outcomes", ["tasks": tasks])
    }

    /// A durable value of this task: the stored one, or `candidate` stored now. Use it to keep a value stable across
    /// reruns of a phase, such as an idempotency key.
    public func memo<Value: Codable & Sendable>(_ name: String, default candidate: @autoclosure () -> Value) async throws -> Value {
        try await handle.memo(name, default: candidate())
    }

    /// A durable value of this task, if stored.
    public func memo<Value: Codable & Sendable>(_ name: String, as type: Value.Type = Value.self) async throws -> Value? {
        try await handle.memo(name, as: type)
    }

    public func task(_ id: TaskID) async throws -> TaskRecord? {
        try await handle.call("scope.getTask", ["task": id])
    }

    /// Waits for a task to be terminal.
    public func waitForTask(_ id: TaskID) async throws -> TaskRecord {
        try await handle.call("scope.waitForTask", ["task": id])
    }

    /// The live tasks this task owns directly, in ID order, including those an earlier invocation created before a
    /// restart (pi-durable `runtime.ownedTasks()`).
    public func ownedTasks() async throws -> [TaskRecord] {
        try await handle.call("scope.ownedTasks")
    }

    /// Aborts a task this task owns and waits until it is terminal (pi-durable `runtime.abortOwned()`).
    public func abortOwned(_ task: TaskID) async throws {
        try await handle.perform("scope.abortOwned", ["task": task])
    }

    /// A handle to an existing conversation, such as one this task owns.
    public func conversation(_ id: ConversationID) async throws -> ConversationHandle? {
        try await handle.conversation(id, harness: harness)
    }

    /// An entry visible from the task's conversation.
    public func entry(_ id: EntryID) async throws -> Entry? {
        try await handle.call("scope.entry", ["entry": id])
    }

    /// A conversation's active entries and model context, optionally as of entry `at`.
    public func context(of conversation: ConversationID, at entry: EntryID? = nil) async throws -> ContextView {
        try await handle.call("scope.context", ["conversation": conversation, "at": entry])
    }

    /// The task's conversation's agent.
    public func agent() async throws -> Agent {
        try await handle.call("scope.agent")
    }

    /// The task's conversation's execution environment (pi-durable `runtime.env()`); `nil` without one. Valid until
    /// the phase handler returns.
    public func environment() async throws -> ExecutionEnv? {
        try await handle.environment()
    }

    /// The harness clock.
    public func now() async throws -> Date {
        let milliseconds: Double = try await handle.call("scope.now")
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }

    /// Ends the phase asleep (pi-durable `runtime.sleepUntil()`): the task holds no invocation until the harness clock
    /// reaches `date`, then continues in `checkpoint.phase`. The sleep survives restarts. Returns once the sleep is
    /// stored, not when the time comes; return from the phase right after. To sleep together with other writes, return
    /// ``NextState/sleeping(_:until:)`` from ``commit(_:)`` instead.
    public func sleep(until date: Date, then checkpoint: Checkpoint) async throws {
        try await handle.perform(
            "scope.sleepUntil", ["until": date.timeIntervalSince1970 * 1000, "checkpoint": try JSONValue(encoding: checkpoint)])
    }

    @available(*, unavailable, message: "A phase no longer waits: end it asleep with sleep(until:then:) and continue in the checkpoint's phase")
    public func sleep(until date: Date) async throws {}

    /// Calls `body` once after about `delay` on the harness's timer (pi-durable `runtime.setTimer()`), to pace work
    /// inside the phase, such as throttled progress. Not durable: the phase's end disarms it. Returns a timer to cancel.
    @discardableResult
    public func timer(after delay: Duration, _ body: @escaping @Sendable () -> Void) async throws -> PhaseTimer {
        let id = harness.engine.host.registerTimer(body)
        let seconds = Double(delay.components.seconds) + Double(delay.components.attoseconds) / 1e18
        try await handle.perform("scope.setTimer", ["timer": id, "delay": seconds * 1000])
        return PhaseTimer(handle: handle, id: id, router: harness.engine.host)
    }

    /// Reports a non-fatal problem to the harness's `onReport` (pi-durable `runtime.report()`): about this task's own
    /// code, or, with `from`, about extension code or a host callback it called.
    public func report(_ message: String, from source: ReportSource? = nil) async throws {
        try await handle.perform("scope.report", ["message": message, "from": try source.map { try JSONValue(encoding: $0) }])
    }

    /// A document, as committed. Defaults to the task's own (`scope: .task`).
    public func document<Value>(
        _ document: Document<Value>, of owner: DocumentOwner? = nil, key: String? = nil, asOf entry: EntryID? = nil
    ) async throws -> Value {
        try await handle.document(document, of: owner ?? .task(taskId), key: key, asOf: entry)
    }

    /// The document's value after every commit that changes it, while this phase runs.
    public func values<Value>(of document: Document<Value>, owner: DocumentOwner? = nil, key: String? = nil)
        -> AsyncThrowingStream<Value, Error>
    {
        handle.values(of: document, owner: owner ?? .task(taskId), key: key)
    }
}

/// How a task ended.
public enum TaskOutcome<Result: Decodable & Sendable>: Decodable, Sendable {
    case completed(Result)
    /// An expected failure the task recorded.
    case failed(message: String, detail: JSONValue?)
    case aborted(reason: String?)
    /// No installed definition could take the task.
    case orphaned(reason: String)
    /// The task's code threw.
    case faulted(message: String, detail: JSONValue?)

    public var isCompleted: Bool {
        if case .completed = self { return true }
        return false
    }

    /// The result of a completed task.
    public var result: Result? {
        if case .completed(let result) = self { return result }
        return nil
    }

    public init(from decoder: Decoder) throws {
        let json = try JSONValue(from: decoder)
        let error = json["error"]
        switch json["status"]?.stringValue {
        case "completed": self = .completed(try (json["result"] ?? .null).decode(as: Result.self))
        case "failed": self = .failed(message: error?["message"]?.stringValue ?? "", detail: error?["detail"])
        case "aborted": self = .aborted(reason: json["reason"]?.stringValue)
        case "orphaned": self = .orphaned(reason: json["reason"]?.stringValue ?? "")
        default: self = .faulted(message: error?["message"]?.stringValue ?? "", detail: error?["detail"])
        }
    }
}

extension TaskOutcome: Equatable where Result: Equatable {}
extension TaskOutcome: Hashable where Result: Hashable {}

/// The durable record of one task.
public struct TaskRecord: Decodable, Sendable, Hashable, Identifiable {
    public enum Status: Sendable, Hashable {
        case pending
        case running
        case waiting(on: [TaskID], policy: JoinPolicy)
        /// Asleep until the harness clock reaches `until`, holding no invocation.
        case sleeping(until: Date)
        /// The outcome is decided, but work the task owns is still finishing.
        case completing(TaskOutcome<JSONValue>)
        case terminal(TaskOutcome<JSONValue>)
    }

    public let id: TaskID
    public let conversationId: ConversationID
    /// The task definition's name, such as `pi.generation` or your ``TaskType/name``.
    public let kind: String
    public let version: Int
    public let input: JSONValue
    /// The owning task of a child task.
    public let owner: TaskID?
    public let background: Bool
    public let abortRequested: Bool
    /// Why the abort mark was set when not by an abort request: `restart` for a task abandoned after a restart
    /// (``Transaction/createTask(_:input:in:ownedBy:background:abandonOnRestart:trace:links:)``) or below one.
    public let abortReason: String?
    /// Whether the task is aborted when a later harness starts scheduling, since its creator awaits it only in memory.
    public let abandonOnRestart: Bool
    /// When the task first started running; `nil` for records written before pi-durable 1.1.
    public let startedAt: Date?
    /// When the task became terminal.
    public let endedAt: Date?
    public let status: Status
    /// The live checkpoint.
    public let checkpoint: JSONValue?
    /// How many times in a row a crash, eviction, or reset cut the task off while it ran without it changing its state;
    /// at ``Settings/restartLimit`` it is parked until ``Harness/retryTask(_:)``.
    public let restarts: Int
    /// The telemetry context that created the task, when the harness records with propagation.
    public let trace: TelemetryCarrier?
    /// Telemetry links attached to the task's first invocation.
    public let links: [TelemetryCarrier]

    /// The outcome of a completing or terminal task.
    public var outcome: TaskOutcome<JSONValue>? {
        switch status {
        case .completing(let outcome), .terminal(let outcome): outcome
        default: nil
        }
    }

    /// The outcome with a typed result.
    public func outcome<Result: Decodable & Sendable>(as type: Result.Type) throws -> TaskOutcome<Result>? {
        guard let outcome = rawOutcome else { return nil }
        return try outcome.decode(as: TaskOutcome<Result>.self)
    }

    public var isTerminal: Bool {
        if case .terminal = status { return true }
        return false
    }

    private let rawOutcome: JSONValue?

    private enum CodingKeys: String, CodingKey {
        case id, conversationId, kind, version, input, owner, background, abortRequested, abortReason, abandonOnRestart, state
        case startedAt, endedAt, restarts, trace, links
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(TaskID.self, forKey: .id)
        conversationId = try container.decode(ConversationID.self, forKey: .conversationId)
        kind = try container.decode(String.self, forKey: .kind)
        version = Int(try container.decodeIfPresent(Double.self, forKey: .version) ?? 1)
        input = try container.decodeIfPresent(JSONValue.self, forKey: .input) ?? .null
        owner = try container.decodeIfPresent(TaskID.self, forKey: .owner)
        background = try container.decodeIfPresent(Bool.self, forKey: .background) ?? false
        abortRequested = try container.decodeIfPresent(Bool.self, forKey: .abortRequested) ?? false
        abortReason = try container.decodeIfPresent(String.self, forKey: .abortReason)
        abandonOnRestart = try container.decodeIfPresent(Bool.self, forKey: .abandonOnRestart) ?? false
        startedAt = try container.decodeIfPresent(Double.self, forKey: .startedAt).map { Date(timeIntervalSince1970: $0 / 1000) }
        endedAt = try container.decodeIfPresent(Double.self, forKey: .endedAt).map { Date(timeIntervalSince1970: $0 / 1000) }
        restarts = Int(try container.decodeIfPresent(Double.self, forKey: .restarts) ?? 0)
        trace = try? container.decodeIfPresent(TelemetryCarrier.self, forKey: .trace)
        links = (try? container.decodeIfPresent([TelemetryCarrier].self, forKey: .links)) ?? []
        let state = try container.decode(JSONValue.self, forKey: .state)
        checkpoint = state["checkpoint"]
        rawOutcome = state["outcome"]
        switch state["status"]?.stringValue {
        case "pending": status = .pending
        case "running": status = .running
        case "waiting":
            status = .waiting(
                on: (try? (state["on"] ?? []).decode(as: [TaskID].self)) ?? [],
                policy: JoinPolicy(rawValue: state["policy"]?.stringValue ?? "") ?? .allSettled)
        case "sleeping": status = .sleeping(until: Date(timeIntervalSince1970: (state["until"]?.doubleValue ?? 0) / 1000))
        case "completing": status = .completing(try (state["outcome"] ?? [:]).decode(as: TaskOutcome<JSONValue>.self))
        default: status = .terminal(try (state["outcome"] ?? [:]).decode(as: TaskOutcome<JSONValue>.self))
        }
    }
}

/// Every live task, with its owner edges (pi-durable `TaskGraph`).
public struct TaskGraph: Decodable, Sendable, Hashable {
    public struct Node: Decodable, Sendable, Hashable, Identifiable {
        public enum State: Sendable, Hashable {
            case pending(phase: String)
            case running(phase: String)
            case waiting(phase: String, on: [TaskID], policy: JoinPolicy)
            /// Asleep until the harness clock reaches `until`.
            case sleeping(phase: String, until: Date)
            /// The decided outcome's status, such as `completed`.
            case completing(outcome: String)
        }

        public let id: TaskID
        public let kind: String
        public let conversationId: ConversationID
        /// The owning task; `nil` for a task its conversation owns.
        public let owner: TaskID?
        public let background: Bool
        public let abortRequested: Bool
        public let state: State
        /// Why the task can't run here, when it can't: no installed definition takes it, or the restart limit parked it.
        public let blocked: BlockedReason?
        /// Conversations this task owns, such as subagents'.
        public let conversations: [ConversationID]

        private enum CodingKeys: String, CodingKey {
            case id, kind, conversationId, owner, background, abortRequested, state, blocked, conversations
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(TaskID.self, forKey: .id)
            kind = try container.decode(String.self, forKey: .kind)
            conversationId = try container.decode(ConversationID.self, forKey: .conversationId)
            owner = try container.decodeIfPresent(TaskID.self, forKey: .owner)
            background = try container.decodeIfPresent(Bool.self, forKey: .background) ?? false
            abortRequested = try container.decodeIfPresent(Bool.self, forKey: .abortRequested) ?? false
            conversations = try container.decodeIfPresent([ConversationID].self, forKey: .conversations) ?? []
            blocked = try container.decodeIfPresent(String.self, forKey: .blocked).map(BlockedReason.init(rawValue:))
            let state = try container.decode(JSONValue.self, forKey: .state)
            let phase = state["phase"]?.stringValue ?? ""
            switch state["status"]?.stringValue {
            case "running": self.state = .running(phase: phase)
            case "waiting":
                self.state = .waiting(
                    phase: phase, on: (try? (state["on"] ?? []).decode(as: [TaskID].self)) ?? [],
                    policy: JoinPolicy(rawValue: state["policy"]?.stringValue ?? "") ?? .allSettled)
            case "sleeping":
                self.state = .sleeping(phase: phase, until: Date(timeIntervalSince1970: (state["until"]?.doubleValue ?? 0) / 1000))
            case "completing": self.state = .completing(outcome: state["outcome"]?.stringValue ?? "")
            default: self.state = .pending(phase: phase)
            }
        }
    }

    public let tasks: [TaskID: Node]

    private enum CodingKeys: String, CodingKey { case tasks }

    public init(from decoder: Decoder) throws {
        let nodes = try decoder.container(keyedBy: CodingKeys.self).decode([String: Node].self, forKey: .tasks)
        tasks = Dictionary(nodes.values.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Tasks without an owner task, in ID order.
    public var roots: [Node] { tasks.values.filter { $0.owner == nil }.sorted { $0.id < $1.id } }

    /// Tasks owned by `task`, in ID order.
    public func children(of task: TaskID) -> [Node] { tasks.values.filter { $0.owner == task }.sorted { $0.id < $1.id } }
}

/// Live work and what the scheduler would do with it (pi-durable `HarnessInspection`).
public struct HarnessInspection: Decodable, Sendable, Hashable {
    /// Whether the task scheduler runs.
    public enum Scheduling: String, Decodable, Sendable {
        /// Not started yet; see ``Harness/resume()``.
        case paused
        case running
        case closing
    }

    public struct Task: Decodable, Sendable, Hashable {
        /// What the scheduler would do with a live task (pi-durable `TaskInspection.state`).
        public enum State: Sendable, Hashable {
            /// An invocation is running it.
            case running
            /// The next scheduling pass reserves it; `migrates` when its definition is newer and has `migrate`.
            case ready(migrates: Bool)
            /// Waits for these live tasks.
            case waiting(on: [TaskID])
            /// Sleeps until the harness clock reaches `until`.
            case sleeping(until: Date)
            /// Its outcome is held until the work it owns drains.
            case completing
            /// Can't run here: no installed definition can take it (`missing_task`, `task_too_old`, or
            /// `migration_failed`, with the migration's error; aborting it settles it as orphaned), or the restart limit
            /// parked it (`restart_limit`; ``Harness/retryTask(_:)`` runs it again).
            case blocked(reason: String, error: String?)
        }

        public let record: TaskRecord
        public let state: State

        /// Why a blocked task cannot run, such as `missing_task`.
        public var blockedReason: String? {
            if case .blocked(let reason, _) = state { return reason }
            return nil
        }

        /// The tasks a waiting task waits for.
        public var waitingOn: [TaskID] {
            if case .waiting(let on) = state { return on }
            return []
        }

        private enum CodingKeys: String, CodingKey { case record, state }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            record = try container.decode(TaskRecord.self, forKey: .record)
            let state = try container.decode(JSONValue.self, forKey: .state)
            switch state["kind"]?.stringValue {
            case "running": self.state = .running
            case "ready": self.state = .ready(migrates: state["migrates"]?.boolValue ?? false)
            case "waiting": self.state = .waiting(on: (try? (state["on"] ?? []).decode(as: [TaskID].self)) ?? [])
            case "sleeping": self.state = .sleeping(until: Date(timeIntervalSince1970: (state["until"]?.doubleValue ?? 0) / 1000))
            case "completing": self.state = .completing
            default:
                let error = state["error"].flatMap { $0.isNull ? nil : ($0["message"]?.stringValue ?? $0.stringValue ?? $0.jsonString) }
                self.state = .blocked(reason: state["reason"]?.stringValue ?? "", error: error)
            }
        }
    }

    public let scheduling: Scheduling
    public let tasks: [Task]
    /// Queued and placed submissions.
    public let submissions: [SubmissionRecord]
}

/// A task's durable status (pi-durable `TaskState.status`), for ``TaskQuery``.
public enum TaskStatus: String, Codable, Sendable, CaseIterable {
    case pending, running, waiting, sleeping, completing, terminal
}

/// Why a task can't run here (pi-durable `BlockedReason`).
public struct BlockedReason: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }

    /// No installed definition has the task's name.
    public static let missingTask = BlockedReason(rawValue: "missing_task")
    /// The installed definition is older than the task's version.
    public static let taskTooOld = BlockedReason(rawValue: "task_too_old")
    /// Migrating the task's state to the installed definition failed.
    public static let migrationFailed = BlockedReason(rawValue: "migration_failed")
    /// Crashes cut it off ``Settings/restartLimit`` times in a row; ``Harness/retryTask(_:)`` runs it again.
    public static let restartLimit = BlockedReason(rawValue: "restart_limit")
}

/// A timer from ``TaskRun/timer(after:_:)``.
public struct PhaseTimer: Sendable {
    let handle: ScopeHandle
    let id: Int
    let router: HostRouter

    /// Disarms the timer, if it hasn't fired.
    public func cancel() async {
        router.removeTimer(id)
        try? await handle.perform("scope.clearTimer", ["timer": id])
    }
}

/// A conversation's raw active transcript and the model context derived from it (pi-durable `ContextView`).
public struct ContextView: Decodable, Sendable, Hashable {
    /// The newest applicable head marker (a reset or compaction), if any.
    public let head: Entry?
    /// The raw active entries: the head marker, then the entries from its head through the tail.
    public let entries: [Entry]
    /// Per entry of ``entries``, its model messages after edits and excluded stop reasons, before tool result ordering.
    public let contributions: [[Message]]
    /// The model context of the next provider request.
    public let messages: [Message]

    private enum CodingKeys: String, CodingKey { case head, entries, contributions, messages }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        head = try container.decodeIfPresent(Entry.self, forKey: .head)
        entries = try container.decodeIfPresent([Entry].self, forKey: .entries) ?? []
        contributions = try container.decodeIfPresent([[Message]].self, forKey: .contributions) ?? []
        messages = try container.decodeIfPresent([Message].self, forKey: .messages) ?? []
    }
}
