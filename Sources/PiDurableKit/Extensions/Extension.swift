import Foundation

/// A named bundle of tools, system prompt sections, hooks, wraps, and durable tasks (pi-durable `defineExtension`).
///
/// ```swift
/// let assistant = Extension("assistant") {
///     PromptSection("preamble", tag: false, text: "You are a concise assistant on an iPhone.")
///     weather
///     Hook.beforeTool { call, _ in
///         call.name == "delete_note" ? .block("Deleting notes needs approval") : .allow
///     }
/// }
/// ```
///
/// Conversations select extensions by name. By default every conversation selects every installed extension,
/// in install order. A later extension's tool replaces an earlier one with the same name.
public struct Extension: Sendable, Identifiable {
    public var id: String { name }
    public let name: String
    public var tools: [Tool]
    public var sections: [PromptSection]
    public var hooks: [Hook]
    /// Decorators of tools and sections of any selected extension, applied where this extension is selected.
    public var wraps: [Wrap]
    /// Durable task types, resolved by name for every task whatever the conversation selects.
    public var tasks: [AnyTaskType]
    let builtin: String?
    let javaScript: (source: String, sourceURL: URL?)?

    public init(
        _ name: String, tools: [Tool] = [], sections: [PromptSection] = [], hooks: [Hook] = [], wraps: [Wrap] = [],
        tasks: [AnyTaskType] = []
    ) {
        self.name = name
        self.tools = tools
        self.sections = sections
        self.hooks = hooks
        self.wraps = wraps
        self.tasks = tasks
        self.builtin = nil
        self.javaScript = nil
    }

    public init(_ name: String, @ExtensionBuilder _ content: () -> [ExtensionComponent]) {
        self.init(name)
        for component in content() {
            switch component {
            case .tool(let tool): tools.append(tool)
            case .section(let section): sections.append(section)
            case .hook(let hook): hooks.append(hook)
            case .wrap(let wrap): wraps.append(wrap)
            case .task(let task): tasks.append(task)
            }
        }
    }

    private init(builtin: String, name: String) {
        self.name = name
        self.tools = []
        self.sections = []
        self.hooks = []
        self.wraps = []
        self.tasks = []
        self.builtin = builtin
        self.javaScript = nil
    }

    /// A pi-durable extension written in JavaScript, evaluated in the harness's runtime and installed unchanged.
    ///
    /// `source` is a CommonJS module whose `module.exports` is a pi-durable extension. It can `require`
    /// `@earendil-works/pi-durable`, `@earendil-works/pi-durable/tools`, `@earendil-works/pi-durable/env`,
    /// `@earendil-works/pi-ai`, and `@earendil-works/chord/context`:
    ///
    /// ```js
    /// const { defineExtension, defineTool } = require("@earendil-works/pi-durable");
    /// const { Type } = require("@earendil-works/pi-ai");
    ///
    /// module.exports = defineExtension({
    ///     name: "dice",
    ///     tools: [defineTool({
    ///         name: "roll", description: "Roll a die", parameters: Type.Object({ sides: Type.Number() }),
    ///         execute: async (args) => ({ content: [{ type: "text", text: String(1 + Math.floor(Math.random() * args.sides)) }] }),
    ///     })],
    /// });
    /// ```
    ///
    /// As in pi-durable, extension code is not sandboxed: it runs with the same access as pi-durable itself, so install
    /// only code you trust. Installing fails if the module does not export an extension named `name`.
    public init(_ name: String, javaScript source: String, sourceURL: URL? = nil) {
        self.name = name
        self.tools = []
        self.sections = []
        self.hooks = []
        self.wraps = []
        self.tasks = []
        self.builtin = nil
        self.javaScript = (source, sourceURL)
    }

    /// pi-durable's `read`, `write`, and `edit` tools, working in the harness's ``ExecutionEnvironment``. (There is no shell on
    /// iOS, so `bash` is left out.)
    public static func codingTools(name: String = "coding") -> Extension {
        Extension(builtin: "coding", name: name)
    }

    var specification: BridgeArguments {
        if let builtin { return ["name": name, "builtin": builtin] }
        if let javaScript {
            return ["name": name, "javaScript": javaScript.source, "sourceURL": javaScript.sourceURL?.absoluteString]
        }
        var hookFlags: [String: Bool] = [:]
        var taskHooks: [[String: String]] = []
        for hook in hooks {
            if case .task(let task, let name, _) = hook.kind {
                if !taskHooks.contains(["task": task, "name": name]) { taskHooks.append(["task": task, "name": name]) }
            } else {
                hookFlags[hook.kind.name] = true
            }
        }
        return [
            "name": name,
            "tools": tools.map(\.specification),
            "sections": sections.map(\.specification),
            "hooks": hookFlags,
            "taskHooks": taskHooks,
            "wraps": wraps.enumerated().map { index, wrap in wrap.specification(index: index) },
            "tasks": tasks.map(\.specification),
        ]
    }
}

/// One part of an ``Extension`` built with ``ExtensionBuilder``.
public enum ExtensionComponent: Sendable {
    case tool(Tool)
    case section(PromptSection)
    case hook(Hook)
    case wrap(Wrap)
    case task(AnyTaskType)
}

@resultBuilder
public enum ExtensionBuilder {
    public static func buildExpression(_ tool: Tool) -> [ExtensionComponent] { [.tool(tool)] }
    public static func buildExpression(_ tools: [Tool]) -> [ExtensionComponent] { tools.map { .tool($0) } }
    public static func buildExpression(_ section: PromptSection) -> [ExtensionComponent] { [.section(section)] }
    public static func buildExpression(_ hook: Hook) -> [ExtensionComponent] { [.hook(hook)] }
    public static func buildExpression(_ wrap: Wrap) -> [ExtensionComponent] { [.wrap(wrap)] }
    public static func buildExpression<I, S, R>(_ task: TaskType<I, S, R>) -> [ExtensionComponent] { [.task(task.erased)] }
    public static func buildBlock(_ components: [ExtensionComponent]...) -> [ExtensionComponent] { components.flatMap { $0 } }
    public static func buildOptional(_ component: [ExtensionComponent]?) -> [ExtensionComponent] { component ?? [] }
    public static func buildEither(first component: [ExtensionComponent]) -> [ExtensionComponent] { component }
    public static func buildEither(second component: [ExtensionComponent]) -> [ExtensionComponent] { component }
    public static func buildArray(_ components: [[ExtensionComponent]]) -> [ExtensionComponent] { components.flatMap { $0 } }
}

extension TaskType {
    /// This task type, for ``Extension/tasks``.
    public var any: AnyTaskType { erased }
}

/// A system prompt section (pi-durable `section`). The selected extensions' sections render in order before each
/// model request; only sections that changed are sent again, which keeps provider prompt caches warm.
public struct PromptSection: Sendable {
    /// What a section can see when it renders.
    public struct Input: Sendable {
        public let conversationId: ConversationID
        /// The request's agent; its `tools` are the tools this request offers.
        public let agent: Agent
        /// The sections already in effect in the active transcript, by key.
        public let shown: [String: String]
        let handle: ScopeHandle

        /// A document, as committed. Defaults to the conversation's.
        public func document<Value>(
            _ document: Document<Value>, of owner: DocumentOwner? = nil, key: String? = nil, asOf entry: EntryID? = nil
        ) async throws -> Value {
            try await handle.document(document, of: owner ?? .conversation(conversationId), key: key, asOf: entry)
        }
    }

    public let key: String
    /// Whether the text is wrapped as `<key>\\n…\\n</key>`.
    public let tag: Bool
    let text: String?
    let render: (@Sendable (Input) async throws -> String?)?

    /// A section with fixed text.
    public init(_ key: String, tag: Bool = true, text: String) {
        self.key = key
        self.tag = tag
        self.text = text
        self.render = nil
    }

    /// A section rendered before every request. Returning `nil` omits it. Text that changes on every request,
    /// such as the current time, defeats provider prompt caches.
    public init(_ key: String, tag: Bool = true, render: @escaping @Sendable (Input) async throws -> String?) {
        self.key = key
        self.tag = tag
        self.text = nil
        self.render = render
    }

    var specification: BridgeArguments {
        ["key": key, "tag": tag, "text": text]
    }
}

/// What a hook can do besides its arguments (pi-durable `HookApi`).
public struct HookContext: Sendable {
    public let conversationId: ConversationID
    /// The task asking: a generation, tool, or compaction task.
    public let taskId: TaskID
    /// The harness's models (pi-durable `api.models`), for calling a model from a hook.
    public let models: Models
    let handle: ScopeHandle

    /// A durable value shared by the hooks and the task, stored on first use.
    public func memo<Value: Codable & Sendable>(_ name: String, default candidate: @autoclosure () -> Value) async throws -> Value {
        try await handle.memo(name, default: candidate())
    }

    public func memo<Value: Codable & Sendable>(_ name: String, as type: Value.Type = Value.self) async throws -> Value? {
        try await handle.memo(name, as: type)
    }

    /// A document, as committed. Defaults to the conversation's.
    public func document<Value>(
        _ document: Document<Value>, of owner: DocumentOwner? = nil, key: String? = nil, asOf entry: EntryID? = nil
    ) async throws -> Value {
        try await handle.document(document, of: owner ?? .conversation(conversationId), key: key, asOf: entry)
    }
}

/// What a compaction is about to summarize, for ``Hook/beforeCompact(_:)``.
public struct CompactionRequest: Decodable, Sendable {
    /// `manual`, `threshold`, or `overflow`.
    public let reason: String
    /// The entries the summary replaces, the head marker first.
    public let entries: [Entry]
    /// Their model context, which the summarizer reads.
    public let messages: [Message]
    /// The first entry kept verbatim.
    public let firstKept: EntryID
    /// Instructions given to ``Conversation/compact(instructions:)``.
    public let instructions: String?
}

/// The outcome of a ``Hook/beforeCompact(_:)`` hook.
public enum CompactionDecision: Sendable {
    /// Don't compact this time.
    case decline
    /// Use this summary instead of asking the model.
    case summary(String)
}

/// Observes or adjusts the built-in generation, tool, and compaction tasks, in the conversations that select the
/// hook's extension (pi-durable `hook`).
public struct Hook: Sendable {
    enum Kind {
        case beforeTool(@Sendable (ToolCall, HookContext) async throws -> ToolDecision)
        case afterTool(@Sendable (ToolCall, ToolResult, HookContext) async throws -> ToolResult?)
        case onYield(@Sendable (AssistantMessage, HookContext) async throws -> String?)
        case beforeRequest(@Sendable ([Message], HookContext) async throws -> [Message]?)
        case afterResponse(@Sendable (AssistantMessage, HookContext) async throws -> Void)
        case afterTools(@Sendable (EntryID, [EntryID], HookContext) async throws -> Void)
        case beforeCompact(@Sendable (CompactionRequest, HookContext) async throws -> CompactionDecision?)
        /// A hook of a ``TaskType``, by task and hook name.
        case task(String, String, @Sendable (JSONValue, TaskHookContext) async throws -> JSONValue?)

        var name: String {
            switch self {
            case .beforeTool: "beforeTool"
            case .afterTool: "afterTool"
            case .onYield: "onYield"
            case .beforeRequest: "beforeRequest"
            case .afterResponse: "afterResponse"
            case .afterTools: "afterTools"
            case .beforeCompact: "beforeCompact"
            case .task: "task"
            }
        }
    }

    let kind: Kind

    /// Runs before a tool call's intent is recorded: allow it, rewrite its arguments, or block it with a message the
    /// model sees. Throwing blocks the call. A good place to ask the user for approval.
    public static func beforeTool(_ handler: @escaping @Sendable (ToolCall, HookContext) async throws -> ToolDecision) -> Hook {
        Hook(kind: .beforeTool(handler))
    }

    /// Runs after a tool call, before its result is recorded; return a replacement result or `nil` to keep it.
    public static func afterTool(
        _ handler: @escaping @Sendable (ToolCall, ToolResult, HookContext) async throws -> ToolResult?
    ) -> Hook {
        Hook(kind: .afterTool(handler))
    }

    /// Runs on each final answer; return a message to continue the run with it as user input, or `nil` to finish.
    public static func onYield(_ handler: @escaping @Sendable (AssistantMessage, HookContext) async throws -> String?) -> Hook {
        Hook(kind: .onYield(handler))
    }

    /// Runs before every model request attempt; return replacement messages for that request only, or `nil`.
    /// Messages you return unchanged keep every provider field (signatures, IDs).
    public static func beforeRequest(_ handler: @escaping @Sendable ([Message], HookContext) async throws -> [Message]?) -> Hook {
        Hook(kind: .beforeRequest(handler))
    }

    /// Runs on every terminal provider response, before it is classified.
    public static func afterResponse(_ handler: @escaping @Sendable (AssistantMessage, HookContext) async throws -> Void) -> Hook {
        Hook(kind: .afterResponse(handler))
    }

    /// Runs once every tool of a round is done, with the tool-calling answer and the result entries in call order.
    public static func afterTools(
        _ handler: @escaping @Sendable (_ assistant: EntryID, _ results: [EntryID], HookContext) async throws -> Void
    ) -> Hook {
        Hook(kind: .afterTools(handler))
    }

    /// Runs before a compaction summarizes; decline it, supply your own summary, or return `nil` to let the model
    /// summarize.
    public static func beforeCompact(
        _ handler: @escaping @Sendable (CompactionRequest, HookContext) async throws -> CompactionDecision?
    ) -> Hook {
        Hook(kind: .beforeCompact(handler))
    }
}

extension Hook {
    /// A handler of a hook point that one of your ``TaskType``s defines, run when the task calls
    /// ``TaskRun/hooks(_:arguments:)``. Like pi-durable `hook(task, handlers)` for your own tasks.
    ///
    /// ```swift
    /// Hook.task(payment, "beforeCharge") { arguments, _ in
    ///     arguments["amount"]?.doubleValue ?? 0 > 100 ? ["block": "Needs approval"] : nil
    /// }
    /// ```
    public static func task<Input, State, Result>(
        _ type: TaskType<Input, State, Result>, _ name: String,
        _ handler: @escaping @Sendable (_ arguments: JSONValue, TaskHookContext) async throws -> JSONValue?
    ) -> Hook {
        Hook(kind: .task(type.name, name, handler))
    }

    /// A typed task hook handler: the task's arguments decode as `Arguments`, and the result encodes from `Output`.
    ///
    /// ```swift
    /// Hook.task(payment, "beforeCharge") { (charge: Charge, _) -> Verdict? in
    ///     charge.amount > 100 ? Verdict(block: "Needs approval") : nil
    /// }
    /// ```
    public static func task<Input, Checkpoint, Result, Arguments: Decodable & Sendable, Output: Encodable & Sendable>(
        _ type: TaskType<Input, Checkpoint, Result>, _ name: String,
        _ handler: @escaping @Sendable (_ arguments: Arguments, TaskHookContext) async throws -> Output?
    ) -> Hook {
        Hook(kind: .task(type.name, name) { arguments, context in
            let decoded: Arguments = try arguments.decode()
            return try await handler(decoded, context).map { try JSONValue(encoding: $0) }
        })
    }
}

/// Where a task hook runs.
public struct TaskHookContext: Sendable {
    public let conversationId: ConversationID
    /// The task running the hook.
    public let taskId: TaskID
}

/// The outcome of a ``Hook/beforeTool(_:)`` hook.
public enum ToolDecision: Sendable {
    /// Run the call as requested.
    case allow
    /// Run the call with these arguments instead.
    case rewrite(JSONObject)
    /// Do not run the call; the model sees this message as an error result.
    case block(String)
}

/// Decorates a tool or a section by name, whichever extension provides it (pi-durable `wrapTool` and `wrapSection`).
///
/// ```swift
/// Wrap.tool("get_weather") { call, context, next in
///     let started = Date()
///     var result = try await next(nil)
///     result.details = ["seconds": .number(Date().timeIntervalSince(started))]
///     return result
/// }
/// ```
public struct Wrap: Sendable {
    /// Runs the wrapped tool, with replacement arguments or `nil` for the original ones.
    public typealias ToolNext = @Sendable (JSONObject?) async throws -> ToolResult
    /// Renders the wrapped section.
    public typealias SectionNext = @Sendable () async throws -> String?

    enum Kind {
        case tool(String, @Sendable (ToolCall, ToolCallContext, ToolNext) async throws -> ToolResult)
        case section(String, @Sendable (PromptSection.Input, SectionNext) async throws -> String?)
    }

    let kind: Kind

    public static func tool(
        _ name: String, _ wrapper: @escaping @Sendable (ToolCall, ToolCallContext, _ next: ToolNext) async throws -> ToolResult
    ) -> Wrap {
        Wrap(kind: .tool(name, wrapper))
    }

    public static func section(
        _ key: String, _ wrapper: @escaping @Sendable (PromptSection.Input, _ next: SectionNext) async throws -> String?
    ) -> Wrap {
        Wrap(kind: .section(key, wrapper))
    }

    func specification(index: Int) -> BridgeArguments {
        switch kind {
        case .tool(let name, _): ["index": index, "tool": name]
        case .section(let key, _): ["index": index, "section": key]
        }
    }
}
