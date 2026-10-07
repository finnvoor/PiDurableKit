import Foundation
import os

/// Swift code a harness hands to JavaScript besides its extensions.
struct HarnessCallbacks: Sendable {
    var onConversationCreated: (@Sendable (Transaction, ConversationRecord) async throws -> Void)?
    var clock: (@Sendable () -> Date)?
    var onReport: (@Sendable (String) -> Void)?
    var environment: (@Sendable (EnvironmentTarget) async throws -> ExecutionEnvironment?)?
}

/// Routes calls from JavaScript into Swift code: tools, sections, hooks, wraps, tasks, commits, documents, credentials,
/// sign-in, and faux responders.
final class HostRouter: Sendable {
    typealias Commit = @Sendable (_ tx: Int, _ extra: JSONValue) async throws -> JSONValue?

    private struct Registration {
        weak var harness: Harness?
        var extensions: [String: Extension] = [:]
        var callbacks = HarnessCallbacks()
    }

    private struct State {
        var harnesses: [Int: Registration] = [:]
        var responders: [String: @Sendable ([Message], Int) async throws -> FauxResponse] = [:]
        var mutations: [Int: @Sendable (JSONValue) throws -> JSONValue] = [:]
        var commits: [Int: Commit] = [:]
        var documents: [String: DocumentCallbacks] = [:]
        var nextID = 1
        var credentials: [Int: any CredentialStore] = [:]
        var databases: [Int: any SQLiteDatabase] = [:]
        var transactions: [Int: SQLiteTransaction] = [:]
        var logins: [Int: LoginSession] = [:]

        mutating func makeID() -> Int {
            defer { nextID += 1 }
            return nextID
        }
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let engineReference = OSAllocatedUnfairLock<WeakEngine>(initialState: WeakEngine())

    private struct WeakEngine: @unchecked Sendable {
        weak var engine: Engine?
    }

    func attach(_ engine: Engine) {
        engineReference.withLock { $0.engine = engine }
    }

    private var engine: Engine {
        get throws {
            guard let engine = engineReference.withLock({ $0.engine }) else { throw CancellationError() }
            return engine
        }
    }

    // MARK: Registration

    func registerHarness(_ id: Int, extensions: [Extension], callbacks: HarnessCallbacks) {
        state.withLock { state in
            state.harnesses[id] = Registration(
                harness: nil,
                extensions: Dictionary(extensions.map { ($0.name, $0) }, uniquingKeysWith: { _, last in last }),
                callbacks: callbacks)
        }
    }

    func attachHarness(_ harness: Harness) {
        state.withLock { $0.harnesses[harness.id]?.harness = harness }
    }

    func install(_ extension: Extension, harness: Int) {
        state.withLock { $0.harnesses[harness]?.extensions[`extension`.name] = `extension` }
    }

    func uninstall(_ name: String, harness: Int) {
        state.withLock { _ = $0.harnesses[harness]?.extensions.removeValue(forKey: name) }
    }

    func removeHarness(_ harness: Int) {
        state.withLock { _ = $0.harnesses.removeValue(forKey: harness) }
    }

    func setResponder(
        models: Int, provider: ProviderID, _ responder: @escaping @Sendable ([Message], Int) async throws -> FauxResponse
    ) {
        state.withLock { $0.responders["\(models)/\(provider)"] = responder }
    }

    func setCredentialStore(_ store: any CredentialStore, models: Int) {
        state.withLock { $0.credentials[models] = store }
    }

    func removeModels(_ models: Int) {
        state.withLock { state in
            state.credentials[models] = nil
            state.responders = state.responders.filter { !$0.key.hasPrefix("\(models)/") }
        }
    }

    func registerLogin(_ session: LoginSession) -> Int {
        state.withLock { state in
            let id = state.makeID()
            state.logins[id] = session
            return id
        }
    }

    func removeLogin(_ id: Int) {
        state.withLock { _ = $0.logins.removeValue(forKey: id) }
    }

    func registerMutation(_ mutation: @escaping @Sendable (JSONValue) throws -> JSONValue) -> Int {
        state.withLock { state in
            let id = state.makeID()
            state.mutations[id] = mutation
            return id
        }
    }

    func removeMutation(_ id: Int) {
        state.withLock { _ = $0.mutations.removeValue(forKey: id) }
    }

    /// Makes a Swift SQLite database reachable from pi-durable's SQLite storage.
    func register(_ database: any SQLiteDatabase) -> Int {
        state.withLock { state in
            let id = state.makeID()
            state.databases[id] = database
            return id
        }
    }

    func registerCommit(_ commit: @escaping Commit) -> Int {
        state.withLock { state in
            let id = state.makeID()
            state.commits[id] = commit
            return id
        }
    }

    func removeCommit(_ id: Int) {
        state.withLock { _ = $0.commits.removeValue(forKey: id) }
    }

    /// Remembers a document's callbacks (migration, seeded initial values, checkpoint policy), which JavaScript calls
    /// synchronously.
    func register<Value>(_ document: Document<Value>) {
        let callbacks = document.callbacks
        guard callbacks.migrate != nil || callbacks.initialForSeed != nil || callbacks.checkpointWhen != nil else { return }
        state.withLock { $0.documents[document.kind] = callbacks }
    }

    // MARK: Dispatch

    func handle(method: String, arguments data: Data) async throws -> Data? {
        let arguments = try decodeJSON(JSONValue.self, from: data)
        let result: (any Encodable)? =
            switch method {
            case "tool.execute": try await executeTool(arguments)
            case "section.render": try await renderSection(arguments)
            case "hook.beforeTool": try await beforeTool(arguments)
            case "hook.afterTool": try await afterTool(arguments)
            case "hook.onYield": try await onYield(arguments)
            case "hook.beforeRequest": try await beforeRequest(arguments)
            case "hook.afterResponse": try await afterResponse(arguments)
            case "hook.afterTools": try await afterTools(arguments)
            case "hook.beforeCompact": try await beforeCompact(arguments)
            case "hook.task": try await taskHook(arguments)
            case "wrap.tool": try await wrapTool(arguments)
            case "wrap.section": try await wrapSection(arguments)
            case "task.phase": try await runTask(arguments, phase: arguments["phase"]?.stringValue ?? "")
            case "task.abort": try await runTask(arguments, phase: nil)
            case "commit.run": try await runCommit(arguments)
            case "harness.conversationCreated": try await conversationCreated(arguments)
            case "harness.report": report(arguments)
            case "harness.environment": try await chooseEnvironment(arguments)
            case "faux.respond": try await respond(arguments)
            case "sqlite.exec": try await sqliteExec(arguments)
            case "sqlite.run": try await sqliteRun(arguments)
            case "sqlite.get": try await sqliteGet(arguments)
            case "sqlite.all": try await sqliteAll(arguments)
            case "sqlite.begin": try await sqliteBegin(arguments)
            case "sqlite.end": try await sqliteEnd(arguments)
            case "sqlite.close": try await sqliteClose(arguments)
            case "doc.mutate": try mutate(arguments)
            case "credentials.read": try await credentialStore(arguments).credential(for: provider(arguments))
            case "credentials.write": try await writeCredential(arguments)
            case "credentials.list": try await listCredentials(arguments)
            case "login.prompt": try await loginPrompt(arguments)
            case "login.notify": loginNotify(arguments)
            default: throw PiDurableError.runtime("Unknown host method \(method)")
            }
        guard let result else { return nil }
        return try BridgeArguments.json(result)
    }

    /// Synchronous calls from JavaScript; returns `{"value": …}` or `{"error": …}` JSON.
    func handleSync(method: String, arguments data: Data) -> String {
        do {
            let arguments = try decodeJSON(JSONValue.self, from: data)
            let value: JSONValue =
                switch method {
                case "tool.prepare": try prepareArguments(arguments)
                case "task.initial": try taskType(arguments).initial(arguments["input"] ?? .null)
                case "task.migrate":
                    try migrateTask(arguments)
                case "doc.migrate": try migrateDocument(arguments)
                case "doc.initial": try seededInitial(arguments)
                case "doc.checkpoint": try checkpoint(arguments)
                case "harness.now": try now(arguments)
                default: throw PiDurableError.runtime("Unknown synchronous host method \(method)")
                }
            return String(decoding: try BridgeArguments.json(["value": value] as [String: JSONValue]), as: UTF8.self)
        } catch {
            let info: [String: String] = [
                "name": String(describing: type(of: error)),
                "message": (error as? LocalizedError)?.errorDescription ?? String(describing: error),
            ]
            let json = (try? String(decoding: JSONEncoder().encode(info), as: UTF8.self)) ?? "{}"
            return String(decoding: (try? BridgeArguments.json(["error": json])) ?? Data("{}".utf8), as: UTF8.self)
        }
    }

    // MARK: Lookup

    private func registration(_ arguments: JSONValue) throws -> Registration {
        let id = arguments["harness"]?.intValue ?? -1
        guard let registration = state.withLock({ $0.harnesses[id] }) else { throw CancellationError() }
        return registration
    }

    private func harness(_ arguments: JSONValue) throws -> Harness {
        guard let harness = try registration(arguments).harness else { throw CancellationError() }
        return harness
    }

    private func extensionNamed(_ arguments: JSONValue) throws -> Extension {
        let name = arguments["extension"]?.stringValue ?? ""
        guard let found = try registration(arguments).extensions[name] else {
            throw PiDurableError.notFound("Extension \(name) is not installed")
        }
        return found
    }

    private func scope(_ arguments: JSONValue) throws -> ScopeHandle {
        ScopeHandle(engine: try engine, id: arguments["handle"]?.intValue ?? 0)
    }

    private func conversation(_ arguments: JSONValue) -> ConversationID {
        ConversationID(arguments["conversationId"]?.intValue ?? 0)
    }

    private func taskID(_ arguments: JSONValue) -> TaskID {
        TaskID(arguments["taskId"]?.intValue ?? 0)
    }

    private func hookContext(_ arguments: JSONValue) throws -> HookContext {
        HookContext(
            conversationId: conversation(arguments), taskId: taskID(arguments), models: try harness(arguments).models,
            handle: try scope(arguments))
    }

    private func toolContext(_ arguments: JSONValue) throws -> ToolCallContext {
        ToolCallContext(
            conversationId: conversation(arguments),
            callId: arguments["callId"]?.stringValue ?? "",
            taskId: taskID(arguments),
            harness: try harness(arguments),
            handle: try scope(arguments)
        )
    }

    private func sectionInput(_ arguments: JSONValue) throws -> PromptSection.Input {
        var shown: [String: String] = [:]
        for (key, value) in arguments["shown"]?.objectValue ?? [:] {
            if let text = value.stringValue { shown[key] = text }
        }
        return PromptSection.Input(
            conversationId: conversation(arguments),
            agent: try (arguments["agent"] ?? [:]).decode(as: Agent.self),
            shown: shown,
            handle: try scope(arguments)
        )
    }

    // MARK: Tools and sections

    private func tool(_ arguments: JSONValue) throws -> Tool {
        let found = try extensionNamed(arguments)
        let name = arguments["tool"]?.stringValue ?? ""
        guard let tool = found.tools.first(where: { $0.name == name }) else {
            throw PiDurableError.notFound("Tool \(name) is not part of extension \(found.name)")
        }
        return tool
    }

    private func executeTool(_ arguments: JSONValue) async throws -> ToolResult {
        try await tool(arguments).execute(arguments["arguments"] ?? [:], try toolContext(arguments))
    }

    private func prepareArguments(_ arguments: JSONValue) throws -> JSONValue {
        let raw = arguments["arguments"] ?? .null
        return try tool(arguments).prepareArguments?(raw) ?? raw
    }

    private func renderSection(_ arguments: JSONValue) async throws -> String? {
        let found = try extensionNamed(arguments)
        let key = arguments["key"]?.stringValue ?? ""
        guard let section = found.sections.first(where: { $0.key == key }) else { return nil }
        if let text = section.text { return text }
        return try await section.render?(try sectionInput(arguments))
    }

    // MARK: Hooks

    private func hooks(_ arguments: JSONValue) throws -> [Hook.Kind] {
        try extensionNamed(arguments).hooks.map(\.kind)
    }

    private func beforeTool(_ arguments: JSONValue) async throws -> JSONValue? {
        var call = try (arguments["call"] ?? [:]).decode(as: ToolCall.self)
        var rewritten = false
        for case .beforeTool(let handler) in try hooks(arguments) {
            switch try await handler(call, try hookContext(arguments)) {
            case .allow: continue
            case .block(let message): return ["block": .string(message)]
            case .rewrite(let newArguments):
                call.arguments = newArguments
                rewritten = true
            }
        }
        return rewritten ? ["arguments": .object(call.arguments)] : nil
    }

    private func afterTool(_ arguments: JSONValue) async throws -> ToolResult? {
        let call = try (arguments["call"] ?? [:]).decode(as: ToolCall.self)
        var result = try (arguments["result"] ?? [:]).decode(as: ToolResult.self)
        var replaced = false
        for case .afterTool(let handler) in try hooks(arguments) {
            if let replacement = try await handler(call, result, try hookContext(arguments)) {
                result = replacement
                replaced = true
            }
        }
        return replaced ? result : nil
    }

    private func onYield(_ arguments: JSONValue) async throws -> JSONValue? {
        let answer = try (arguments["answer"] ?? [:]).decode(as: AssistantMessage.self)
        for case .onYield(let handler) in try hooks(arguments) {
            if let message = try await handler(answer, try hookContext(arguments)) {
                return ["continue": .string(message)]
            }
        }
        return nil
    }

    private func beforeRequest(_ arguments: JSONValue) async throws -> JSONValue? {
        var messages = try (arguments["messages"] ?? []).decode(as: [Message].self)
        var replaced = false
        for case .beforeRequest(let handler) in try hooks(arguments) {
            if let replacement = try await handler(messages, try hookContext(arguments)) {
                messages = replacement
                replaced = true
            }
        }
        return replaced ? ["messages": try JSONValue(encoding: messages)] : nil
    }

    private func afterResponse(_ arguments: JSONValue) async throws -> JSONValue? {
        let message = try (arguments["message"] ?? [:]).decode(as: AssistantMessage.self)
        for case .afterResponse(let handler) in try hooks(arguments) {
            try await handler(message, try hookContext(arguments))
        }
        return nil
    }

    private func afterTools(_ arguments: JSONValue) async throws -> JSONValue? {
        let assistant = EntryID(arguments["assistant"]?.intValue ?? 0)
        let results = (arguments["results"]?.arrayValue ?? []).compactMap { $0.intValue.map { EntryID(rawValue: $0) } }
        for case .afterTools(let handler) in try hooks(arguments) {
            try await handler(assistant, results, try hookContext(arguments))
        }
        return nil
    }

    private func beforeCompact(_ arguments: JSONValue) async throws -> JSONValue? {
        let request = try (arguments["compaction"] ?? [:]).decode(as: CompactionRequest.self)
        for case .beforeCompact(let handler) in try hooks(arguments) {
            switch try await handler(request, try hookContext(arguments)) {
            case .decline?: return ["decline": true]
            case .summary(let text)?: return ["summary": .string(text)]
            case nil: continue
            }
        }
        return nil
    }

    private func taskHook(_ arguments: JSONValue) async throws -> JSONValue? {
        let task = arguments["task"]?.stringValue
        let name = arguments["name"]?.stringValue
        let context = TaskHookContext(conversationId: conversation(arguments), taskId: taskID(arguments))
        for case .task(let hookTask, let hookName, let handler) in try hooks(arguments) where hookTask == task && hookName == name {
            if let result = try await handler(arguments["arguments"] ?? .null, context) { return result }
        }
        return nil
    }

    // MARK: Wraps

    private func wrap(_ arguments: JSONValue) throws -> Wrap.Kind {
        let found = try extensionNamed(arguments)
        let index = arguments["wrap"]?.intValue ?? -1
        guard found.wraps.indices.contains(index) else { throw PiDurableError.notFound("Wrap \(index) of \(found.name)") }
        return found.wraps[index].kind
    }

    private func wrapTool(_ arguments: JSONValue) async throws -> ToolResult {
        guard case .tool(let name, let wrapper) = try wrap(arguments) else {
            throw PiDurableError.runtime("Not a tool wrap")
        }
        let context = try toolContext(arguments)
        let call = ToolCall(id: context.callId, name: name, arguments: arguments["arguments"]?.objectValue ?? [:])
        let handle = try scope(arguments)
        return try await wrapper(call, context) { replacement in
            let json: JSONValue = try await handle.call(
                "wrap.next", ["arguments": replacement.map(JSONValue.object)])
            return try json.decode(as: ToolResult.self)
        }
    }

    private func wrapSection(_ arguments: JSONValue) async throws -> String? {
        guard case .section(_, let wrapper) = try wrap(arguments) else {
            throw PiDurableError.runtime("Not a section wrap")
        }
        let handle = try scope(arguments)
        return try await wrapper(try sectionInput(arguments)) {
            let text: String? = try await handle.call("wrap.next")
            return text
        }
    }

    // MARK: Tasks

    private func taskType(_ arguments: JSONValue) throws -> AnyTaskType {
        let found = try extensionNamed(arguments)
        let name = arguments["task"]?.stringValue ?? ""
        guard let task = found.tasks.first(where: { $0.name == name }) else {
            throw PiDurableError.notFound("Task \(name) is not part of extension \(found.name)")
        }
        return task
    }

    private func runTask(_ arguments: JSONValue, phase: String?) async throws -> JSONValue? {
        let record = try (arguments["record"] ?? [:]).decode(as: TaskRecord.self)
        try await taskType(arguments).run(phase, try scope(arguments), try harness(arguments), record)
        return nil
    }

    private func migrateTask(_ arguments: JSONValue) throws -> JSONValue {
        guard let migrate = try taskType(arguments).migrate else { throw PiDurableError.runtime("Task has no migration") }
        return try migrate(arguments["input"] ?? .null, arguments["checkpoint"] ?? .null, arguments["fromVersion"]?.intValue ?? 0)
    }

    // MARK: Commits and documents

    private func runCommit(_ arguments: JSONValue) async throws -> JSONValue? {
        let id = arguments["commit"]?.intValue ?? 0
        guard let commit = state.withLock({ $0.commits[id] }) else { throw PiDurableError.runtime("Unknown commit") }
        return try await commit(arguments["tx"]?.intValue ?? 0, arguments)
    }

    private func conversationCreated(_ arguments: JSONValue) async throws -> JSONValue? {
        let registration = try registration(arguments)
        guard let callback = registration.callbacks.onConversationCreated, let harness = registration.harness else { return nil }
        let record = try (arguments["record"] ?? [:]).decode(as: ConversationRecord.self)
        let transaction = Transaction(handle: ScopeHandle(engine: try engine, id: arguments["tx"]?.intValue ?? 0), harness: harness)
        try await callback(transaction, record)
        return nil
    }

    private func chooseEnvironment(_ arguments: JSONValue) async throws -> JSONValue? {
        guard let choose = try registration(arguments).callbacks.environment else { return nil }
        let target = EnvironmentTarget(
            conversationId: ConversationID(arguments["conversationId"]?.intValue ?? 0), cwd: arguments["cwd"]?.stringValue,
            handle: try scope(arguments))
        guard let environment = try await choose(target) else { return nil }
        return ["root": .string(try environment.root())]
    }

    private func report(_ arguments: JSONValue) -> JSONValue? {
        (try? registration(arguments))?.callbacks.onReport?(arguments["message"]?.stringValue ?? "")
        return nil
    }

    private func now(_ arguments: JSONValue) throws -> JSONValue {
        let date = try registration(arguments).callbacks.clock?() ?? Date()
        return .number((date.timeIntervalSince1970 * 1000).rounded())
    }

    private func mutate(_ arguments: JSONValue) throws -> JSONValue {
        let id = arguments["mutation"]?.intValue ?? 0
        guard let mutation = state.withLock({ $0.mutations[id] }) else {
            throw PiDurableError.runtime("Unknown document mutation")
        }
        return try mutation(arguments["value"] ?? [:])
    }

    private func documentCallbacks(_ arguments: JSONValue) throws -> DocumentCallbacks {
        let kind = arguments["kind"]?.stringValue ?? ""
        guard let callbacks = state.withLock({ $0.documents[kind] }) else {
            throw PiDurableError.runtime("Document \(kind) is not registered")
        }
        return callbacks
    }

    private func migrateDocument(_ arguments: JSONValue) throws -> JSONValue {
        guard let migrate = try documentCallbacks(arguments).migrate else { throw PiDurableError.runtime("No migration") }
        return try migrate(arguments["value"]?.objectValue ?? [:], arguments["fromVersion"]?.intValue ?? 0)
    }

    private func seededInitial(_ arguments: JSONValue) throws -> JSONValue {
        guard let initial = try documentCallbacks(arguments).initialForSeed else { throw PiDurableError.runtime("No seed") }
        return try initial(arguments["seed"] ?? .null)
    }

    private func checkpoint(_ arguments: JSONValue) throws -> JSONValue {
        guard let checkpointWhen = try documentCallbacks(arguments).checkpointWhen else { return false }
        return .bool(checkpointWhen(
            arguments["value"]?.objectValue ?? [:], arguments["ops"]?.arrayValue ?? [],
            arguments["deltasSinceBase"]?.intValue ?? 0))
    }

    // MARK: SQLite databases

    private func database(_ arguments: JSONValue) throws -> any SQLiteDatabase {
        let id = arguments["database"]?.intValue ?? 0
        guard let database = state.withLock({ $0.databases[id] }) else { throw PiDurableError.runtime("SQLite database is closed") }
        return database
    }

    private func sqliteExecutor(_ arguments: JSONValue) throws -> any SQLiteExecutor {
        guard let transaction = arguments["transaction"]?.intValue else { return try database(arguments) }
        guard let executor = state.withLock({ $0.transactions[transaction] })?.executor else {
            throw PiDurableError.runtime("SQLite transaction handle is no longer active")
        }
        return executor
    }

    private func parameters(_ arguments: JSONValue) -> [SQLiteValue] {
        (arguments["params"]?.arrayValue ?? []).map(SQLiteValue.init(json:))
    }

    private func row(_ row: SQLiteRow) -> JSONValue {
        .object(row.mapValues(\.json))
    }

    private func sqliteExec(_ arguments: JSONValue) async throws -> JSONValue? {
        try await sqliteExecutor(arguments).execute(arguments["sql"]?.stringValue ?? "")
        return nil
    }

    private func sqliteRun(_ arguments: JSONValue) async throws -> JSONValue? {
        try await sqliteExecutor(arguments).run(arguments["sql"]?.stringValue ?? "", parameters(arguments))
        return nil
    }

    private func sqliteGet(_ arguments: JSONValue) async throws -> JSONValue {
        let result = try await sqliteExecutor(arguments).get(arguments["sql"]?.stringValue ?? "", parameters(arguments))
        return result.map(row) ?? .null
    }

    private func sqliteAll(_ arguments: JSONValue) async throws -> [JSONValue] {
        try await sqliteExecutor(arguments).all(arguments["sql"]?.stringValue ?? "", parameters(arguments)).map(row)
    }

    private func sqliteBegin(_ arguments: JSONValue) async throws -> Int {
        let database = try database(arguments)
        let transaction = SQLiteTransaction()
        let id = state.withLock { state in
            let id = state.makeID()
            state.transactions[id] = transaction
            return id
        }
        do {
            try await transaction.begin(on: database)
        } catch {
            state.withLock { _ = $0.transactions.removeValue(forKey: id) }
            throw error
        }
        return id
    }

    private func sqliteEnd(_ arguments: JSONValue) async throws -> JSONValue? {
        let id = arguments["transaction"]?.intValue ?? 0
        guard let transaction = state.withLock({ $0.transactions.removeValue(forKey: id) }) else { return nil }
        try await transaction.end(commit: arguments["commit"]?.boolValue ?? false)
        return nil
    }

    private func sqliteClose(_ arguments: JSONValue) async throws -> JSONValue? {
        let database = try database(arguments)
        state.withLock { _ = $0.databases.removeValue(forKey: arguments["database"]?.intValue ?? 0) }
        try await database.close()
        return nil
    }

    // MARK: Models

    private func respond(_ arguments: JSONValue) async throws -> FauxResponse {
        let key = "\(arguments["models"]?.intValue ?? 0)/\(arguments["provider"]?.stringValue ?? "")"
        guard let responder = state.withLock({ $0.responders[key] }) else {
            throw PiDurableError.notFound("No faux responder for \(key)")
        }
        let messages = (try? (arguments["messages"] ?? []).decode(as: [Message].self)) ?? []
        return try await responder(messages, arguments["callCount"]?.intValue ?? 0)
    }

    private func credentialStore(_ arguments: JSONValue) throws -> any CredentialStore {
        let models = arguments["models"]?.intValue ?? 0
        guard let store = state.withLock({ $0.credentials[models] }) else {
            throw PiDurableError.runtime("The models collection was released")
        }
        return store
    }

    private func provider(_ arguments: JSONValue) -> ProviderID {
        ProviderID(arguments["provider"]?.stringValue ?? "")
    }

    private func writeCredential(_ arguments: JSONValue) async throws -> JSONValue? {
        let credential = arguments["credential"].flatMap { $0.objectValue.map(Credential.init(json:)) }
        try await credentialStore(arguments).setCredential(credential, for: provider(arguments))
        return nil
    }

    private func listCredentials(_ arguments: JSONValue) async throws -> [JSONValue] {
        let store = try credentialStore(arguments)
        var result: [JSONValue] = []
        for provider in try await store.providers() {
            guard let kind = try await store.credential(for: provider)?.kind else { continue }
            result.append(["providerId": .string(provider.rawValue), "type": .string(kind.rawValue)])
        }
        return result
    }

    private func login(_ arguments: JSONValue) throws -> LoginSession {
        let id = arguments["login"]?.intValue ?? 0
        guard let session = state.withLock({ $0.logins[id] }) else { throw CancellationError() }
        return session
    }

    private func loginPrompt(_ arguments: JSONValue) async throws -> String {
        let session = try login(arguments)
        return try await session.interaction.prompt(LoginPrompt(json: arguments["prompt"] ?? [:]))
    }

    private func loginNotify(_ arguments: JSONValue) -> JSONValue? {
        guard let session = try? login(arguments), let event = LoginEvent(json: arguments["event"] ?? [:]) else { return nil }
        session.notify(event)
        return nil
    }
}
