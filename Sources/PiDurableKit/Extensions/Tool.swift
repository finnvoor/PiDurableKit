import Foundation

/// A tool the model can call, implemented in Swift (pi-durable `defineTool`).
///
/// ```swift
/// struct Weather: Decodable { var city: String }
///
/// let weather = Tool("get_weather", description: "Look up the current weather",
///                    parameters: .object(["city": .string("City name")])) { (args: Weather, call) in
///     call.output("Looking up \(args.city)…\n")
///     return "Sunny and 22°C in \(args.city)"
/// }
/// ```
///
/// Each call runs as its own durable task: its intent is committed before `execute` runs. If the process dies
/// mid-call, the call reruns on reopen only when it is declared `replay: .safe`; otherwise the model gets an
/// `interrupted` error result. Throwing gives the model an error result.
public struct Tool: Sendable, Identifiable {
    /// Whether an interrupted call may run again after a restart.
    public enum Replay: String, Sendable, Encodable {
        /// Rerunning is harmless (reads, idempotent writes).
        case safe
        /// The default: an interrupted call becomes an `interrupted` error result.
        case unsafe
    }

    public var id: String { name }
    public let name: String
    public let description: String
    public let parameters: JSONSchema
    public var replay: Replay
    /// `sequential` makes the whole round of tool calls run one after another.
    public var executionMode: Settings.ToolExecution?
    /// Repairs arguments models commonly get wrong before validation, such as a JSON string where an array belongs.
    /// Must be pure; its result is still validated against ``parameters``.
    public var prepareArguments: (@Sendable (JSONValue) -> JSONValue)?
    /// Bounds on the output a call keeps; see ``OutputLimits``.
    public var outputLimits: OutputLimits?
    let execute: @Sendable (JSONValue, ToolCallContext) async throws -> ToolResult

    /// Bounds on the running output a call keeps, and whether it keeps the head or the tail.
    public struct OutputLimits: Encodable, Sendable, Hashable {
        public var maxBytes: Int?
        public var maxLines: Int?
        public var retain: Retain?

        public enum Retain: String, Encodable, Sendable {
            case head, tail
        }

        public init(maxBytes: Int? = nil, maxLines: Int? = nil, retain: Retain? = nil) {
            self.maxBytes = maxBytes
            self.maxLines = maxLines
            self.retain = retain
        }
    }

    /// The same tool with an argument repair step.
    public func preparingArguments(_ prepare: @escaping @Sendable (JSONValue) -> JSONValue) -> Tool {
        var copy = self
        copy.prepareArguments = prepare
        return copy
    }

    /// The same tool with output limits.
    public func limitingOutput(_ limits: OutputLimits) -> Tool {
        var copy = self
        copy.outputLimits = limits
        return copy
    }

    /// A tool whose arguments decode as `Arguments`.
    public init<Arguments: Decodable & Sendable, Output: ToolOutput>(
        _ name: String,
        description: String,
        parameters: JSONSchema,
        replay: Replay = .unsafe,
        executionMode: Settings.ToolExecution? = nil,
        execute: @escaping @Sendable (Arguments, ToolCallContext) async throws -> Output
    ) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.replay = replay
        self.executionMode = executionMode
        self.execute = { arguments, context in
            let decoded: Arguments
            do {
                decoded = try arguments.decode()
            } catch {
                throw ToolArgumentsError(tool: name, underlying: error)
            }
            return try await execute(decoded, context).toolResult
        }
    }

    /// A tool without parameters.
    public init<Output: ToolOutput>(
        _ name: String,
        description: String,
        replay: Replay = .unsafe,
        executionMode: Settings.ToolExecution? = nil,
        execute: @escaping @Sendable (ToolCallContext) async throws -> Output
    ) {
        self.name = name
        self.description = description
        self.parameters = .object()
        self.replay = replay
        self.executionMode = executionMode
        self.execute = { _, context in try await execute(context).toolResult }
    }

    var specification: BridgeArguments {
        [
            "name": name,
            "description": description,
            "parameters": parameters,
            "replay": replay,
            "executionMode": executionMode?.rawValue,
            "outputLimits": outputLimits,
            "prepares": prepareArguments != nil,
        ]
    }
}

struct ToolArgumentsError: Error, LocalizedError {
    let tool: String
    let underlying: Error
    var errorDescription: String? { "Invalid arguments for \(tool): \(underlying)" }
}

/// What a tool returns to the model.
public struct ToolResult: Sendable, Encodable, ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
    /// The content the model sees. `nil` uses the output streamed with ``ToolCallContext/output(_:)``.
    public var content: [ContentBlock]?
    public var isError: Bool
    /// App-facing data stored on the result; not shown to the model.
    public var details: JSONValue?
    /// Ends the run without another model request, when every result of the round asks for it.
    public var terminate: Bool
    /// Starts a new context from this handoff note.
    public var handoff: String?
    /// Tools to offer from the next request on, by name; they must belong to a selected extension.
    public var addTools: [String]
    /// Remarks for the model and the UI, added after those recorded with ``ToolCallContext/diagnostic(_:)``.
    public var diagnostics: [ToolDiagnostic]
    /// Spend of the tool's own work, such as a model call.
    public var usage: Usage?

    public init(
        content: [ContentBlock]?,
        isError: Bool = false,
        details: JSONValue? = nil,
        terminate: Bool = false,
        handoff: String? = nil,
        addTools: [String] = [],
        diagnostics: [ToolDiagnostic] = [],
        usage: Usage? = nil
    ) {
        self.diagnostics = diagnostics
        self.content = content
        self.isError = isError
        self.details = details
        self.terminate = terminate
        self.handoff = handoff
        self.addTools = addTools
        self.usage = usage
    }

    public init(stringLiteral value: String) {
        self.init(content: [.text(value)])
    }

    /// A text result.
    public static func text(_ text: String, details: JSONValue? = nil) -> ToolResult {
        ToolResult(content: [.text(text)], details: details)
    }

    /// An error result the model sees.
    public static func error(_ message: String, details: JSONValue? = nil) -> ToolResult {
        ToolResult(content: [.text(message)], isError: true, details: details)
    }

    /// A result made of the output streamed with ``ToolCallContext/output(_:)``.
    public static var streamedOutput: ToolResult { ToolResult(content: nil) }

    /// An image result.
    public static func image(_ data: Data, mimeType: String, caption: String? = nil) -> ToolResult {
        var content: [ContentBlock] = [.image(ImageContent(data: data, mimeType: mimeType))]
        if let caption { content.insert(.text(caption), at: 0) }
        return ToolResult(content: content)
    }

    /// Ends the run after this round instead of asking the model again.
    public func terminating() -> ToolResult {
        var copy = self
        copy.terminate = true
        return copy
    }

    /// Offers these tools from the next request on.
    public func addingTools(_ names: String...) -> ToolResult {
        var copy = self
        copy.addTools += names
        return copy
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyKey.self)
        try container.encodeIfPresent(content, forKey: AnyKey("content"))
        if isError { try container.encode(true, forKey: AnyKey("isError")) }
        if !diagnostics.isEmpty { try container.encode(diagnostics, forKey: AnyKey("diagnostics")) }
        try container.encodeIfPresent(details, forKey: AnyKey("details"))
        try container.encodeIfPresent(usage, forKey: AnyKey("usage"))
        if terminate || handoff != nil || !addTools.isEmpty {
            var control: JSONObject = [:]
            if terminate { control["terminate"] = true }
            if let handoff { control["handoff"] = .string(handoff) }
            if !addTools.isEmpty { control["addTools"] = .array(addTools.map(JSONValue.string)) }
            try container.encode(control, forKey: AnyKey("control"))
        }
    }
}

extension ToolResult: Decodable {
    public init(from decoder: Decoder) throws {
        let json = try JSONValue(from: decoder)
        content = try json["content"].map { try $0.decode(as: [ContentBlock].self) }
        isError = json["isError"]?.boolValue ?? false
        details = json["details"]
        terminate = json["control"]?["terminate"]?.boolValue ?? false
        handoff = json["control"]?["handoff"]?.stringValue
        addTools = json["control"]?["addTools"]?.arrayValue?.compactMap(\.stringValue) ?? []
        diagnostics = (try? json["diagnostics"].map { try $0.decode(as: [ToolDiagnostic].self) }) ?? []
        usage = try? json["usage"].map { try $0.decode(as: Usage.self) }
    }
}

/// A value a tool can return: a `String`, a ``ToolResult``, or anything `Encodable` (sent as JSON text).
public protocol ToolOutput: Sendable {
    var toolResult: ToolResult { get }
}

extension ToolResult: ToolOutput {
    public var toolResult: ToolResult { self }
}

extension String: ToolOutput {
    public var toolResult: ToolResult { .text(self) }
}

extension JSONValue: ToolOutput {
    public var toolResult: ToolResult { .text(stringValue ?? jsonString, details: self) }
}

/// One running tool call (pi-durable `ToolExecutionApi`). Valid until the tool returns.
public struct ToolCallContext: Sendable {
    public let conversationId: ConversationID
    /// The model's ID for this call.
    public let callId: String
    /// The durable task running this call. Tasks and conversations it owns are aborted with it.
    public let taskId: TaskID
    public let harness: Harness
    let handle: ScopeHandle

    var engine: Engine { handle.engine }

    /// The harness's models (pi-durable `api.models`), for calling a model with the same catalog and credentials as
    /// generation. Report the spend in ``ToolResult/usage``.
    public var models: Models { harness.models }

    /// Appends running output. It is committed periodically, shown in ``LiveState/ToolSlot/output``, and becomes
    /// the result when the tool returns ``ToolResult/streamedOutput``.
    public func output(_ chunk: String) {
        engine.send("tool.output", ["handle": handle.id, "chunk": chunk])
    }

    /// Replaces the call's running details, an app-facing value shown in ``LiveState/ToolSlot/details``.
    public func details(_ value: some Encodable & Sendable) async throws {
        try await handle.perform("tool.details", ["details": JSONValue(encoding: value)])
    }

    /// Records a remark about this call for the model and the UI, such as a truncation.
    public func diagnostic(_ diagnostic: ToolDiagnostic) async throws {
        try await handle.perform("tool.diagnostic", ["diagnostic": diagnostic])
    }

    /// Commits a transaction, for example to create a subagent conversation this call owns:
    ///
    /// ```swift
    /// let child = try await call.commit { tx in
    ///     let created = try await tx.createConversation(ownedBy: call.taskId)
    ///     try await tx.configure(created.id, AgentChange(instructions: "You are a researcher."))
    ///     return created.id
    /// }
    /// let settled = try await call.conversation(child)!.submit(task).wait()
    /// ```
    @discardableResult
    public func commit<T: Sendable>(_ body: @escaping @Sendable (Transaction) async throws -> T) async throws -> T {
        try await handle.commit(harness: harness, body)
    }

    /// A handle to an existing conversation, such as a subagent this call created.
    public func conversation(_ id: ConversationID) async throws -> ConversationHandle? {
        try await handle.conversation(id, harness: harness)
    }

    /// Creates a durable task owned by this call (aborted with it), or with `ownedByConversation` a top-level task of
    /// the conversation.
    @discardableResult
    public func createTask<Input, State, Result>(
        _ type: TaskType<Input, State, Result>, input: Input, ownedByConversation: Bool = false, background: Bool = false
    ) async throws -> TaskID {
        try await handle.call(
            "scope.createTask",
            [
                "task": type.name, "input": try JSONValue(encoding: input), "ownedByConversation": ownedByConversation,
                "background": background,
            ])
    }

    public func task(_ id: TaskID) async throws -> TaskRecord? {
        try await handle.call("scope.getTask", ["task": id])
    }

    /// Waits for a task to be terminal.
    public func waitForTask(_ id: TaskID) async throws -> TaskRecord {
        try await handle.call("scope.waitForTask", ["task": id])
    }

    /// The calling conversation's agent.
    public func agent() async throws -> Agent {
        try await handle.call("scope.agent")
    }

    /// A durable value of this call: the stored one, or `candidate` stored now. A replay-safe tool uses memos to find
    /// the work a crashed attempt already did.
    public func memo<Value: Codable & Sendable>(_ name: String, default candidate: @autoclosure () -> Value) async throws -> Value {
        try await handle.memo(name, default: candidate())
    }

    /// A durable value of this call, if stored.
    public func memo<Value: Codable & Sendable>(_ name: String, as type: Value.Type = Value.self) async throws -> Value? {
        try await handle.memo(name, as: type)
    }

    /// A document, as committed. Defaults to the calling conversation's.
    public func document<Value>(
        _ document: Document<Value>, of owner: DocumentOwner? = nil, key: String? = nil, asOf entry: EntryID? = nil
    ) async throws -> Value {
        try await handle.document(document, of: owner ?? .conversation(conversationId), key: key, asOf: entry)
    }

    /// The document's value after every commit that changes it, while this call runs.
    public func values<Value>(of document: Document<Value>, owner: DocumentOwner? = nil, key: String? = nil)
        -> AsyncThrowingStream<Value, Error>
    {
        handle.values(of: document, owner: owner ?? .conversation(conversationId), key: key)
    }
}

/// A remark about a tool call for the model and the UI, such as a truncation or a spill path (pi-durable
/// `ToolDiagnostic`); never part of the tool's data.
public struct ToolDiagnostic: Codable, Sendable, Hashable {
    public enum Severity: String, Codable, Sendable {
        case info, warn, error
    }

    public var severity: Severity
    public var message: String
    public var code: String?

    public init(_ message: String, severity: Severity = .info, code: String? = nil) {
        self.severity = severity
        self.message = message
        self.code = code
    }
}
