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
    public enum Replay: String, Sendable, Codable {
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
    /// The JSON schema of ``ToolResult/structuredOutput``, which programs that call the tool receive. `nil`: they
    /// receive the tool's bounded output instead.
    public var structuredOutputSchema: JSONSchema?
    /// Who may call the tool: the model, other tools through ``ToolCallContext/executeTool(_:arguments:key:progress:)-(_,JSONObject,_,_)``,
    /// or both (the default).
    public var callers: Set<Caller>
    /// Not offered to the model until loaded: the model gets the tool only when a conversation's
    /// ``AgentChange/modelTools`` names it, which ``ToolResult/addTools`` (from a tool such as
    /// ``Extension/toolSearch(name:)``) writes. Other tools can call it any time.
    public var deferred: Bool

    /// Who calls a tool.
    public enum Caller: String, Codable, Sendable, CaseIterable {
        /// The model, in a tool round.
        case model
        /// Other tools, as nested calls.
        case tools
    }
    let execute: @Sendable (JSONValue, ToolCallContext) async throws -> ToolResult

    /// Bounds on the running output a call keeps, and whether it keeps the head or the tail.
    public struct OutputLimits: Codable, Sendable, Hashable {
        public var maxBytes: Int?
        public var maxLines: Int?
        public var retain: Retain?

        public enum Retain: String, Codable, Sendable {
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

    /// The same tool declaring the schema of its ``ToolResult/structuredOutput``.
    public func returningStructuredOutput(_ schema: JSONSchema) -> Tool {
        var copy = self
        copy.structuredOutputSchema = schema
        return copy
    }

    /// The same tool, callable only by these callers.
    public func callable(by callers: Set<Caller>) -> Tool {
        var copy = self
        copy.callers = callers
        return copy
    }

    /// The same tool, kept from the model until loaded (see ``deferred``).
    public func deferringUntilLoaded() -> Tool {
        var copy = self
        copy.deferred = true
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
        self.callers = [.model, .tools]
        self.deferred = false
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
        self.callers = [.model, .tools]
        self.deferred = false
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
            "structuredOutputSchema": structuredOutputSchema,
            "callers": callers == [.model, .tools] ? nil : Tool.Caller.allCases.filter(callers.contains).map(\.rawValue),
            "deferred": deferred ? true : nil,
        ]
    }
}

struct ToolArgumentsError: Error, LocalizedError {
    let tool: String
    let underlying: Error
    var errorDescription: String? { "Invalid arguments for \(tool): \(underlying)" }
}

/// What a tool returns (pi-durable `ToolExecutionResult`), on three channels: ``output`` for the model,
/// ``structuredOutput`` for programs that call the tool (``ToolCallContext/executeTool(_:arguments:key:progress:)-(_,JSONObject,_,_)``
/// callers, code mode scripts), and ``details`` for UIs.
public struct ToolResult: Sendable, Encodable, ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
    /// For the model. `nil` uses the output streamed with ``ToolCallContext/output(_:)-(String)``.
    public var output: [ContentBlock]?
    /// For programs. Required unless ``isError`` when the tool declares ``Tool/structuredOutputSchema``, and validated
    /// against it; not allowed without one, where programs get the output itself.
    public var structuredOutput: JSONValue?
    public var isError: Bool
    /// App-facing data stored on the result; not shown to the model.
    public var details: JSONValue?
    /// Ends the run without another model request, when every result of the round asks for it.
    public var terminate: Bool
    /// Starts a new context from this handoff note.
    public var handoff: String?
    /// Tools to offer from the next request on, by name, including deferred ones (``Tool/deferred``).
    public var addTools: [String]
    /// Remarks for the model and the UI, added after those recorded with ``ToolCallContext/diagnostic(_:)``.
    public var diagnostics: [ToolDiagnostic]
    /// Spend of the tool's own work, such as a model call.
    public var usage: Usage?

    @available(*, deprecated, renamed: "output")
    public var content: [ContentBlock]? {
        get { output }
        set { output = newValue }
    }

    public init(
        output: [ContentBlock]?,
        structuredOutput: JSONValue? = nil,
        isError: Bool = false,
        details: JSONValue? = nil,
        terminate: Bool = false,
        handoff: String? = nil,
        addTools: [String] = [],
        diagnostics: [ToolDiagnostic] = [],
        usage: Usage? = nil
    ) {
        self.output = output
        self.structuredOutput = structuredOutput
        self.diagnostics = diagnostics
        self.isError = isError
        self.details = details
        self.terminate = terminate
        self.handoff = handoff
        self.addTools = addTools
        self.usage = usage
    }

    @available(*, deprecated, renamed: "init(output:structuredOutput:isError:details:terminate:handoff:addTools:diagnostics:usage:)")
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
        self.init(
            output: content, isError: isError, details: details, terminate: terminate, handoff: handoff, addTools: addTools,
            diagnostics: diagnostics, usage: usage)
    }

    public init(stringLiteral value: String) {
        self.init(output: [.text(value)])
    }

    /// A text result.
    public static func text(_ text: String, details: JSONValue? = nil) -> ToolResult {
        ToolResult(output: [.text(text)], details: details)
    }

    /// An error result the model sees.
    public static func error(_ message: String, details: JSONValue? = nil) -> ToolResult {
        ToolResult(output: [.text(message)], isError: true, details: details)
    }

    /// A result made of the output streamed with ``ToolCallContext/output(_:)-(String)``.
    public static var streamedOutput: ToolResult { ToolResult(output: nil) }

    /// An image result.
    public static func image(_ data: Data, mimeType: String, caption: String? = nil) -> ToolResult {
        var output: [ContentBlock] = [.image(ImageContent(data: data, mimeType: mimeType))]
        if let caption { output.insert(.text(caption), at: 0) }
        return ToolResult(output: output)
    }

    /// A result whose structured output, for programs, is `value`, and whose output for the model is its JSON text.
    public static func structured(_ value: some Encodable & Sendable, details: JSONValue? = nil) throws -> ToolResult {
        let json = try JSONValue(encoding: value)
        return ToolResult(output: [.text(json.stringValue ?? json.jsonString)], structuredOutput: json, details: details)
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

    /// The same result with structured output for programs.
    public func withStructuredOutput(_ value: JSONValue) -> ToolResult {
        var copy = self
        copy.structuredOutput = value
        return copy
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyKey.self)
        try container.encodeIfPresent(output, forKey: AnyKey("output"))
        try container.encodeIfPresent(structuredOutput, forKey: AnyKey("structuredOutput"))
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
        output = try (json["output"] ?? json["content"]).map { try $0.decode(as: [ContentBlock].self) }
        structuredOutput = json["structuredOutput"]
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
    /// The tail of this call's output the harness keeps and the pace of its progress commits (pi-durable
    /// `api.outputWindow`), for ``ExecutionEnv/run(_:cwd:environment:inheritEnvironment:timeout:spill:window:onOutput:)``;
    /// `nil` when the tool keeps the head of its output, which cannot accept skips.
    public let outputWindow: OutputWindow?
    let handle: ScopeHandle

    var engine: Engine { handle.engine }

    /// The harness's models (pi-durable `api.models`), for calling a model with the same catalog and credentials as
    /// generation. Report the spend in ``ToolResult/usage``.
    public var models: Models { harness.requestModels }

    /// Appends running output. It is committed periodically, shown in ``LiveState/ToolSlot/output``, and becomes
    /// the result when the tool returns ``ToolResult/streamedOutput``.
    public func output(_ chunk: String) {
        engine.send("tool.output", ["handle": handle.id, "chunk": chunk])
    }

    /// Appends running output after `skipped` output an environment omitted outside ``outputWindow``, as reported in
    /// ``ShellOutput/skipped``.
    public func output(_ chunk: String, skipped: OutputSkip?) {
        engine.send("tool.output", ["handle": handle.id, "chunk": chunk, "skipped": skipped])
    }

    /// Appends running output bytes, decoded as UTF-8 across chunks.
    public func output(_ bytes: Data) {
        engine.send("tool.output", ["handle": handle.id, "base64": bytes.base64EncodedString()])
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
    ///
    /// - Parameters:
    ///   - type: The installed task type.
    ///   - input: The task's input.
    ///   - ownedByConversation: Make it a top-level task of the conversation instead of this call's.
    ///   - background: Survives the conversation's abort and does not keep it busy.
    ///   - abandonOnRestart: Whether a later harness aborts the task after a restart; by default `true` for a task this
    ///     call owns when the tool is not ``Tool/Replay/safe``, since the call never resumes to await it.
    ///   - trace: Where the task's telemetry continues; by default the call's trace.
    ///   - links: Telemetry links attached to the spans of the task's first invocation.
    @discardableResult
    public func createTask<Input, State, Result>(
        _ type: TaskType<Input, State, Result>, input: Input, ownedByConversation: Bool = false, background: Bool = false,
        abandonOnRestart: Bool? = nil, trace: TaskTrace = .inherited, links: [TelemetryCarrier] = []
    ) async throws -> TaskID {
        try await handle.call(
            "scope.createTask",
            [
                "task": type.name, "input": try JSONValue(encoding: input), "ownedByConversation": ownedByConversation,
                "background": background, "abandonOnRestart": abandonOnRestart, "trace": trace.json, "links": links,
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

    /// The call's execution environment (pi-durable `api.env`), built by the harness's ``ExecutionEnvironment`` for
    /// the calling conversation; `nil` without one. Valid until the tool returns.
    public func environment() async throws -> ExecutionEnv? {
        try await handle.environment()
    }

    /// The tools the calling conversation offers the model, with their schemas (pi-durable `api.agent().tools`): the
    /// selected extensions' tools, with wraps applied and the agent's tool filters.
    public func tools() async throws -> [OfferedTool] {
        try await handle.call("scope.tools")
    }

    /// The tools nested calls resolve among (pi-durable `api.agent().callable`): enabled and callable by tools.
    public func callableTools() async throws -> [OfferedTool] {
        try await handle.call("scope.tools", ["callable": true])
    }

    /// Runs a tool as a nested call of this one and waits for its result (pi-durable `api.executeTool()`).
    ///
    /// The nested call is its own durable `pi.tool` task owned by this call: it resolves the tool among the
    /// conversation's tools callable by tools (``Agent/callable``), repairs and validates the arguments, runs the tool
    /// hooks (which see ``ToolCall/parent``), applies output limits and the tool's replay policy, and shows its progress
    /// in ``LiveState/nestedTools``. Its result returns here instead of entering the transcript; a call that is
    /// blocked, invalid, throws, is interrupted, or is aborted returns an error result.
    ///
    /// - Parameters:
    ///   - name: The tool.
    ///   - arguments: Its arguments.
    ///   - key: Names the nested call within this one; by default its position among this call's nested calls. A rerun
    ///     of a ``Tool/Replay/safe`` tool that makes a call with a used key gets that call back instead of starting
    ///     another. Must be non-empty, without `/`, and not a positive integer.
    ///   - progress: `false` keeps the nested call's running output, details, and diagnostics out of ``LiveState``.
    public func executeTool(
        _ name: String, arguments: JSONObject = [:], key: String? = nil, progress: Bool? = nil
    ) async throws -> NestedToolResult {
        try await handle.call(
            "scope.executeTool", ["name": name, "arguments": JSONValue.object(arguments), "key": key, "progress": progress])
    }

    /// Runs a tool as a nested call, with arguments encoded as a JSON object.
    public func executeTool(
        _ name: String, arguments: some Encodable & Sendable, key: String? = nil, progress: Bool? = nil
    ) async throws -> NestedToolResult {
        guard case .object(let object) = try JSONValue(encoding: arguments) else {
            throw PiDurableError.runtime("Tool arguments must encode as a JSON object")
        }
        return try await executeTool(name, arguments: object, key: key, progress: progress)
    }

    /// Calls a tool as part of this call. Now a durable nested call; see ``executeTool(_:arguments:key:progress:)-(_,JSONObject,_,_)``,
    /// which also returns structured output.
    @available(*, deprecated, renamed: "executeTool(_:arguments:key:progress:)")
    public func callTool(_ name: String, arguments: JSONValue = [:]) async throws -> ToolResult {
        try await executeTool(name, arguments: arguments.objectValue ?? [:]).toolResult
    }

    @available(*, deprecated, renamed: "executeTool(_:arguments:key:progress:)")
    public func callTool(_ name: String, arguments: some Encodable & Sendable) async throws -> ToolResult {
        try await executeTool(name, arguments: arguments).toolResult
    }

    /// The harness clock (pi-durable `api.now()`): the times a rerun after a restart compares against.
    public func now() async throws -> Date {
        let milliseconds: Double = try await handle.call("scope.now")
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }

    /// The output retained so far, as the model will see it when the result omits ``ToolResult/output``, and whether
    /// earlier output was dropped (pi-durable `api.retainedOutput()`).
    public func retainedOutput() async throws -> (text: String, truncated: Bool) {
        struct Retained: Decodable { let text: String; let truncated: Bool }
        let retained: Retained = try await handle.call("scope.retainedOutput")
        return (retained.text, retained.truncated)
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
/// A tool a conversation is offered: its pi-ai `Tool` fields, and the extension that defines it.
public struct OfferedTool: Decodable, Sendable, Hashable {
    public var name: String
    public var description: String
    /// The JSON schema of the tool's arguments.
    public var parameters: JSONValue
    /// The selected extension that defines the tool.
    public var `extension`: String?
}

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

/// The result of a nested call (pi-durable `NestedToolExecutionResult`). Programs read ``structuredOutput``; the
/// output for the model is not kept.
public struct NestedToolResult: Decodable, Sendable, Hashable {
    /// The nested call's tool task.
    public let taskId: TaskID
    /// The tool's value for programs: its validated ``ToolResult/structuredOutput`` when it declares
    /// ``Tool/structuredOutputSchema``; otherwise its bounded output, as a string for one text item, an image for one
    /// image, `""` for none, and the content list otherwise. `nil` on an error the harness wrote itself.
    public let structuredOutput: JSONValue?
    public let isError: Bool
    public let details: JSONValue?
    public let diagnostics: [ToolDiagnostic]
    public let usage: Usage?
    /// Execution time of the attempt that produced the result.
    public let duration: Duration?

    private enum CodingKeys: String, CodingKey { case taskId, structuredOutput, isError, details, diagnostics, usage, durationMs }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        taskId = try container.decode(TaskID.self, forKey: .taskId)
        structuredOutput = try container.decodeIfPresent(JSONValue.self, forKey: .structuredOutput)
        isError = try container.decodeIfPresent(Bool.self, forKey: .isError) ?? false
        details = try container.decodeIfPresent(JSONValue.self, forKey: .details)
        diagnostics = (try? container.decodeIfPresent([ToolDiagnostic].self, forKey: .diagnostics)) ?? []
        usage = try? container.decodeIfPresent(Usage.self, forKey: .usage)
        duration = try container.decodeIfPresent(Double.self, forKey: .durationMs).map { .milliseconds($0) }
    }

    /// The text of the output: a string, or the text items of a content list; for an error the harness wrote, its
    /// diagnostics.
    public var text: String {
        if let string = structuredOutput?.stringValue { return string }
        if let items = structuredOutput?.arrayValue { return items.compactMap { $0["text"]?.stringValue }.joined() }
        if structuredOutput == nil { return diagnostics.map(\.message).joined(separator: "\n") }
        return structuredOutput?.jsonString ?? ""
    }

    /// Decodes the structured output as `T`.
    public func decode<T: Decodable>(as type: T.Type = T.self) throws -> T {
        try (structuredOutput ?? .null).decode(as: T.self)
    }

    /// The result as a ``ToolResult``, its output made from the structured output.
    public var toolResult: ToolResult {
        var output: [ContentBlock]
        switch structuredOutput {
        case .string(let text)?: output = text.isEmpty ? [] : [.text(text)]
        case .array(let items)?: output = (try? JSONValue.array(items).decode(as: [ContentBlock].self)) ?? [.text(text)]
        case .object?:
            if let image = try? structuredOutput?.decode(as: ImageContent.self), structuredOutput?["type"] == "image" {
                output = [.image(image)]
            } else {
                output = [.text(text)]
            }
        case nil: output = diagnostics.isEmpty ? [] : [.text(text)]
        default: output = [.text(text)]
        }
        return ToolResult(
            output: output, isError: isError, details: details, diagnostics: diagnostics, usage: usage)
    }
}
