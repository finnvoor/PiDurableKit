# PiDurableKit

Durable AI agents for iPhone, iPad, Mac, and Vision Pro, powered by [`@earendil-works/pi-durable`](https://www.npmjs.com/package/@earendil-works/pi-durable) running in JavaScriptCore.

Conversations, model turns, tool calls, and your own state are committed to storage before anything is shown. If iOS kills your app mid-turn, reopening the storage picks the work up where it stopped.

```swift
import PiDurableKit

let models = Models(credentials: .keychain)
try await models.setAPIKey(anthropicKey, for: .anthropic)
let harness = try await Harness.open(.sqlite(at: .documentsDirectory.appending(path: "agent.sqlite")), models: models)
let root = try await harness.root(agent: AgentChange(model: .anthropic("claude-sonnet-4-5")))

let submission = try await root.submit("What is the capital of France?")
let settled = try await submission.wait()
if case .done(_, let answer?) = settled.status {
    let entry = try await root.commit { tx in try await tx.entry(answer) }
    print(entry?.assistantMessage?.text ?? "")
}
```

- Swift tools, system prompt sections, hooks, and wraps, written as plain closures
- Subagents, durable tasks with child tasks, and atomic transactions
- Every pi-ai provider (Anthropic, OpenAI, Google, OpenRouter, Groq, xAI, Mistral, …) plus any OpenAI- or Anthropic-compatible server
- SQLite or JSONL persistence with crash recovery, or in-memory storage
- pi-durable's `read`/`write`/`edit` tools in a sandboxed directory
- Streaming: `AsyncSequence`s of conversation views (for SwiftUI) and coding-agent style events
- Steering, follow-ups, abort, reset, compaction, forks, typed documents and entries, usage and cost
- OAuth sign-in to Claude Pro/Max, ChatGPT, GitHub Copilot, and OpenRouter, with tokens in the Keychain and automatic refresh
- A scripted faux provider for tests and SwiftUI previews

Requires iOS 17, macOS 14, tvOS 17, or visionOS 1.

## Installation

```swift
.package(url: "https://github.com/<you>/PiDurableKit.git", from: "1.0.0")
```

and add `PiDurableKit` to your target's dependencies.

## Concepts

The Swift API mirrors pi-durable's, with Swift concurrency in place of Chord contexts (cancel the Swift task to cancel a wait; cancelling a wait never cancels the work).

| pi-durable | PiDurableKit |
|---|---|
| `createModels({ credentials })` + providers | `Models(credentials:)`, `models.register(CustomProvider(…))` |
| `Harness.open(storage, { models, registry, settings })` | `Harness.open(.sqlite(at:), models:, extensions:, settings:)` |
| `harness.root()`, `createConversation()`, `fork()` | `harness.root(agent:)`, `harness.createConversation(ownedBy:agent:)`, `conversation.fork(at:ownedBy:)` |
| `tx.scanConversations()`, `tx.conversation()`, `tx.entry()` | `harness.conversations(ownedBy:)`, `conversation.record()`, `conversation.entry(_:)` |
| `conversation.submit({ type: "input", … })` | `conversation.submit("…", whenBusy:, requestId:)` |
| `conversation.submit({ type: "write", … })` | `conversation.write(EntryDraft(…))` |
| `submission.wait()`, `tx.entry(AssistantEntry, id)` | `submission.wait()`, `tx.entry(id)?.assistantMessage` |
| `harness.submission(id)`, `abortSubmission(id, context, conversationId)` | `harness.submission(_:)`, `harness.abortSubmission(_:in:)` |
| `conversation.context({ at })` → `head`, `entries`, `contributions`, `messages` | `conversation.context(at:)` → `ContextView` |
| `EntryDraft.head`, `EntryDraft.edits` (`ContextEdit`) | `EntryDraft(kind:head: .itself / .entry(id), edits: [.omit(id), .replace(id, with:)])` |
| `conversation.configure(change)` | `conversation.configure(AgentChange(…))` |
| `defineExtension`, `defineTool`, `section`, `hook` | `Extension`, `Tool`, `PromptSection`, `Hook` |
| `wrapTool`, `wrapSection` | `Wrap.tool(_:definition:prepareArguments:execute:)`, `Wrap.section` |
| `hook(GenerationTask, { onYield })` with user content | `Hook.onYield` (text), `Hook.onYieldContent` (text and images) |
| an extension written in JavaScript | `Extension(name, javaScript: source)` |
| `defineTask`, `TaskRuntime` | `TaskType`, `Phase`, `TaskRun` |
| `harness.commit()`, `conversation.commit()`, `Tx` | `harness.commit { tx in … }`, `conversation.commit { tx in … }`, `Transaction` |
| `ToolExecutionApi` (`commit`, `conversation`, `memo`, `env`, `registry`, `outputWindow`, `retainedOutput`, …) | `ToolCallContext` (`environment()`, `registry()`, `outputWindow`, `output(_:skipped:)`, `retainedOutput()`, …) |
| `api.executeTool(name, args, { key, progress })` → `NestedToolExecutionResult` | `call.executeTool(_:arguments:key:progress:)` → `NestedToolResult` |
| `ToolExecutionResult` `output`, `structuredOutput`; `structuredOutputSchema` | `ToolResult(output:structuredOutput:)`, `ToolResult.structured(_:)`; `tool.returningStructuredOutput(_:)` |
| `ToolRegistration.callers`, `deferred`; `pi.agent` `modelTools` | `tool.callable(by:)`, `tool.deferringUntilLoaded()`; `AgentChange(modelTools:)`, `Agent.callable`, `Agent.deferred` |
| `@earendil-works/pi-durable/tool-search`, `/codemode` | `Extension.toolSearch()`, `Extension.codemode(_:)` |
| `createCodingTools({ images })`, `/images` (Photon) | `Extension.codingTools(images: .native)` (ImageIO), or your `ImageProcessor` |
| `TaskRuntime` `env()`, `settings`, `registry`, `ownedTasks()`, `abortOwned()` | `run.environment()`, `run.settings()`, `run.registry()`, `run.ownedTasks()`, `run.abortOwned(_:)` |
| `TaskOptions.abandonOnRestart` | `tx.createTask(…, abandonOnRestart: true)`, `call.createTask(…, abandonOnRestart:)` |
| `submit({ type: "input", content, entry: { kind, data } })` | `conversation.submit("…", entry: InputEntry(kind:data:))` |
| `registry.snapshot()`, `resolveSettings()`, `DEFAULT_*_POLICY` | `harness.registry()`, `harness.resolvedSettings()`, `Runtime.defaultSettings()` |
| `conversation.watch()` / `viewState()` | `conversation.changes()` / `conversation.views()`, `conversation.view()` |
| `watchEvents(harness, id)` → `snapshot`, `start(listener)` | `harness.watchEvents(id)` → `snapshot`, `for try await events in stream` |
| `defineDoc`, `defineDocFamily` + `tx.doc()` | `Document(…, scope:, history:, keyed:, migrate:)`, `update(_:_:)`, `values(of:)` |
| `defineEntry` | `EntryType`, `conversation.write(_:_:)`, `entry.data(as:)` |
| `UserEntry`, `AssistantEntry`, `ToolResultEntry`, `CompactionEntry`, … | `EntryType.user`, `.assistant`, `.toolResult`, `.compaction`, …, `entry.is(_:)` |
| `AgentDoc`, `LiveDoc`, `InboxDoc`, `UsageDoc`, `ProviderDoc` | `conversation.agentState(asOf:)`, `liveState()`, `inbox()`, `usage()`, `providerSessionId()` |
| `tx.latestHeadMarker()`, `tx.submissionByRequest()` | `tx.latestHeadMarker(in:)`, `tx.submission(in:requestId:)` |
| `tx.createSubmission()`, `settleSubmission()`, `placeSubmission()` | `tx.createSubmission(_:)`, `tx.settleSubmission(_:_:)`, `tx.placeSubmission(_:at:)` |
| `taskGraph()`, `watchTaskGraph()`, `inspect()`, `getTask()` | `taskGraph()`, `taskGraphs()`, `inspect()`, `task(_:)` |
| `HarnessOptions.env`, `CodingTools` | `ExecutionEnvironment.directory(_:)` / `.custom(_:)` / `.local` (macOS) / `.perConversation { target in … }`, `Extension.codingTools(shell:)` |
| `ExecutionEnv` (`readTextFile`, `openBinaryReader`, `exec`, `watch`, …) | `ExecutionEnv` from `harness.environment(for:)` or a call's `environment()` |
| a custom `ExecutionEnv` | `CustomExecutionEnvironment` |
| `createReadTool()`, `createBashTool({ commandPrefix, prepare })`, `createPowerShellTool()` | `Extension.builtinTools(name:_:)` with `.read`, `.write`, `.edit`, `.bash(commandPrefix:prepare:)`, `.powerShell(…)` |
| `harness.subscribeCommits()`, `subscribeClose()`, `closed` | `harness.commits()`, `harness.closing()`, `harness.closed()` → `SessionEnd` |
| `ExecutionEnv.listFiles()` | `env.listFiles(_:options:)` |
| `HarnessSettings.documentRetentionMs` | `Settings(documentRetention:)`, `Session.open(documentRetention:)` |
| `createSession(storage)` | `Session.open(_:)` |
| a custom `Storage` | `Storage.custom(_:)` with your `CustomStorage` |
| `registerStorageConformance`, `registerEnvConformance` | `Runtime.runStorageConformance(_:)`, `Runtime.runEnvironmentConformance(_:)` |
| Chord `apply(value, ops)` | `Runtime.applyOperations(_:to:)` |
| `SqliteStorage` over a `SqliteDatabase` facade | `Storage.sqlite(database:)` with your `SQLiteDatabase` |
| `SqliteStorage.open(db, { prefix })`, `openNodeSqliteStorage(path, { prefix })` | `Storage.sqlite(database:tablePrefix:)`, `.sqlite(at:tablePrefix:)` |
| pi-ai `models.completeSimple()`, `streamSimple()` | `models.complete(_:context:options:)`, `models.stream(_:context:options:)` |
| a pi-ai provider over Apple's FoundationModels (Swift-only) | `models.register(FoundationModelsProvider())`, `ModelRef.appleOnDevice`, `.applePrivateCloudCompute` |
| `ROOT_CONVERSATION_ID`, `INSTRUCTIONS_KEY` | `ConversationID.root`, `PromptSection.instructionsKey` |
| `ReadAfterWrite`, `SessionFailed`, `StorageRequestError`, `ConversationBusy`, `FileError`, `ExecutionError`, `Jsonl*Error` | `PiDurableError.readAfterWrite`, `.sessionFailed(message:cause:)`, `.storageRequestError`, `.conversationBusy(id)`, `.file(code:message:path:)`, `.execution(code:message:spillPath:)`, `.jsonlCorrupted`, `.jsonlPoisoned` |
| `conversationCreated`, `init`, `now`, `onReport(error, info)` | `onConversationCreated:`, `initialize:`, `clock:`, `onReport:` → `HarnessReport` |
| `HarnessOptions.setTimer`, `onWake`, `harness.wake()` | `Harness.open(timer:onWake:)`, `HarnessTimer`, `harness.wake()` → `Wake`, `Session.open(timer:)` |
| `HarnessOptions.identity`, pi-ai `ClientIdentity`, `withClientIdentity()`, request `identity` | `Harness.open(identity:)`, `ClientIdentity`, `Runtime.Client.attribution`, `models.withIdentity(_:)`, `ModelOptions(identity:)` |
| `HarnessOptions.telemetry`, chord `createSqliteTelemetry()`, pi-telemetry `InMemoryTelemetryContext` | `Harness.open(telemetry:)`, `Telemetry.sqlite(at:)` / `.sqlite(database:)` / `.memory()`, `telemetry.traces(_:)`, `metrics(_:)` |
| `TaskOptions.trace`, `links`; `TaskRecord.trace`, `SubmissionRecord.trace` | `createTask(…, trace:links:)` with `TaskTrace`, `TaskRecord.trace`, `SubmissionRecord.trace` |
| `HarnessOptions.models` / `settings` as functions | `harness.replaceModels(_:)`, `harness.updateSettings(_:)` |
| `settings.afterFailedRun`, `restartLimit`, `compaction.modelOverrides` | `Settings(afterFailedRun:restartLimit:)`, `Settings.Compaction(modelOverrides:)` |
| `runtime.sleepUntil()`, `{ status: "sleeping" }`, `runtime.setTimer()`, `runtime.report(error, from)` | `run.sleep(until:then:)`, `NextState.sleeping(_:until:)`, `run.timer(after:_:)`, `run.report(_:from:)` |
| `TaskRecord.restarts`, `harness.retryTask()`, blocked `restart_limit` | `TaskRecord.restarts`, `harness.retryTask(_:)`, `BlockedReason.restartLimit` |
| `ToolExecutionApi.now()` | `ToolCallContext.now()` |
| `JsonlStorage`, `models.refresh()`, `models.getAuth()` | `Storage.jsonl(at:)` / `.jsonl(in:directory:)`, `models.refresh()`, `models.isConfigured(_:)` |

## Tools

```swift
struct WeatherArguments: Decodable, Sendable { var city: String }

let weather = Tool(
    "get_weather",
    description: "Look up the current weather in a city",
    parameters: .object(["city": .string("City name")])
) { (args: WeatherArguments, call) in
    call.output("Looking up \(args.city)…\n")   // streamed to the UI while the tool runs
    return "Sunny and 22°C in \(args.city)"      // a String, a ToolResult, or a JSONValue
}

let assistant = Extension("assistant") {
    PromptSection("preamble", tag: false, text: "You are a concise assistant on an iPhone.")
    PromptSection("today") { _ in Date.now.formatted(date: .complete, time: .omitted) }
    weather
    Hook.beforeTool { call, _ in
        await askUserForApproval(call) ? .allow : .block("The user declined")
    }
}

let harness = try await Harness.open(.sqlite(at: url), models: models, extensions: [assistant])
```

Each call is its own durable task. Throwing gives the model an error result. A call interrupted by a crash reruns after a restart only when the tool is declared `replay: .safe`; otherwise the model gets an `interrupted` error. Return `ToolResult.text(…).terminating()` to end the run without another model request.

Install, replace, or remove extensions at runtime with `harness.install(_:)` and `harness.uninstall(_:)`. Choose per conversation with `configure`:

```swift
try await conversation.configure(AgentChange(
    model: .openAI("gpt-4.1"),
    thinkingLevel: .high,
    extensions: .remove(assistant),
    instructions: "Only answer in French."
))
try await conversation.configure(AgentChange(reset: [.extensions, .instructions]))
```

### JavaScript extensions

pi-durable extensions written in JavaScript install unchanged, the way a Node app installs its own:

```swift
let source = #"""
const { defineExtension, defineTool } = require("@earendil-works/pi-durable");
const { Type } = require("@earendil-works/pi-ai");
module.exports = defineExtension({
  name: "dice",
  tools: [defineTool({
    name: "roll", description: "Roll a die", parameters: Type.Object({ sides: Type.Number() }),
    execute: async (args) => ({ output: [{ type: "text", text: String(1 + Math.floor(Math.random() * args.sides)) }] }),
  })],
});
"""#
try await harness.install(Extension("dice", javaScript: source))
```

The module is CommonJS and can `require` `@earendil-works/pi-durable` (and `/tools`, `/env`, `/tool-search`,
`/codemode`), `@earendil-works/pi-codemode/portable`, `@earendil-works/pi-ai`, `@earendil-works/chord/context`, `@earendil-works/chord/output` (bounded tool output),
`@earendil-works/chord/sqlite`, `@earendil-works/chord/telemetry-sqlite`, and `@earendil-works/pi-telemetry`. A document
an extension defines needs a `checkpointWhen` policy (`() => false` stores every change as a delta). As in pi-durable, extension code is not sandboxed, so install only code you trust;
it cannot reach PiDurableKit's own bridge to storage. Like any extension, install it again after a restart before
resuming (`Harness.open(…, resume: false)`, `install`, `resume()`) so its pending tool calls continue.

`PiDurable.documentation` is pi-durable's own `README.md` and TypeScript declarations for the bundled version, as its
npm package ships them (the bundle keeps only minified code). Give it to an agent that writes extensions, the way pi
points its agent at pi's docs.

An app can use both to let its agent write extensions into its workspace and load them into the running session: copy
the documentation into the workspace, point a prompt section at it, and install the modules the agent writes with a
tool that calls `install(_:)`. That flow is app policy, not part of the package.

### Subagents and transactions

A tool call can commit transactions and drive other conversations. This is pi-durable's foreground subagent: the
child conversation is owned by the call, so aborting the call aborts the child, and a crash-rerun finds the same child.

```swift
let subagent = Tool("subagent", description: "Delegate a task", parameters: .object(["task": .string]), replay: .safe) {
    (args: SubagentArguments, call) -> String in
    let child = try await call.commit { tx in
        if let existing = try await tx.conversations(ownedBy: call.taskId, limit: 1).items.first { return existing.id }
        let created = try await tx.createConversation(ownedBy: call.taskId)
        try await tx.configure(created.id, AgentChange(model: .anthropic("claude-haiku-4-5"), extensions: .remove(assistant)))
        return created.id
    }
    let handle = try await call.conversation(child)!
    let settled = try await handle.submit(args.task, requestId: "subagent:\(call.taskId)").wait()
    guard case .done(_, let answer?) = settled.status else { return "\(settled.status)" }
    return try await call.commit { tx in try await tx.entry(answer)?.assistantMessage?.text ?? "" }
}
```

`ToolCallContext` also offers `memo` (values that survive a rerun), `agent()`, `document(_:)`, `createTask`,
`waitForTask`, and `details`/`diagnostic`. `tools()` lists the tools the conversation offers the model, with their
schemas, and `callableTools()` those other tools can call. Results can `addingTools(…)`, and tools can repair arguments
(`preparingArguments`) or bound their output (`limitingOutput`).

### Nested calls and structured output

A tool can call another tool as a durable nested call, its own `pi.tool` task owned by the call. Its result returns to
the caller instead of the transcript, and a tool that declares a schema gives programs a value instead of text:

```swift
let forecast = Tool("forecast", description: "Forecast", parameters: .object(["city": .string()])) { (args: City, _) in
    try ToolResult.structured(Forecast(city: args.city, celsius: 21))   // for programs; its JSON text for the model
}.returningStructuredOutput(.object(["city": .string(), "celsius": .integer()]))

let plan = Tool("plan", description: "Plan a trip", replay: .safe) { (call: ToolCallContext) in
    async let oslo = call.executeTool("forecast", arguments: ["city": "Oslo"], key: "oslo")
    async let rome = call.executeTool("forecast", arguments: ["city": "Rome"], key: "rome")
    let forecasts = try await [oslo, rome].map { try $0.decode(as: Forecast.self) }
    return "Warmest: \(forecasts.max { $0.celsius < $1.celsius }!.city)"
}
```

Nested calls validate, run the tool hooks (`ToolCall.parent` names the caller), and show in `view.live.nestedTools` and
in agent events (`ToolEventCall.parentCallId`). Keys let a replay-safe caller's rerun reattach to the calls it already
made. `tool.callable(by: [.tools])` keeps a tool from the model; `deferringUntilLoaded()` keeps it from the model until
loaded with `AgentChange(modelTools: .edit(add: […]))` or `Extension.toolSearch()`, the model's `tool_search`.

`Extension.codemode()` adds pi-durable's durable code mode: a `codemode` tool whose JavaScript scripts call the
conversation's tools (`await tools.forecast({ city: "Oslo" })`) as nested calls, in a QuickJS sandbox bundled as
WebAssembly. A script survives a restart: it replays from a journal of the results it got and continues. Each script
runs in a JavaScriptCore context on a thread of its own, so one that computes doesn't hold up the runtime; its tools
still run in the runtime. It works on iOS devices. QuickJS computes slowly there as on a Mac (a 5-million-step loop
takes about 4 seconds), and a script that mostly calls tools adds little (about 0.1 seconds). `interruptBudget` bounds
how long a script computes without calling a tool (by default about 40 seconds on an iPhone 18 Pro), and
`memoryLimitBytes` how much memory it allocates.

`harness.commit { tx in … }` and `conversation.commit { tx in … }` run any set of reads and writes atomically: create
conversations and forks, append entries, create tasks, configure agents, and read or write documents. Throwing rolls
everything back.

### Durable tasks

```swift
struct Step: TaskCheckpoint { var phase: String }                     // a checkpoint names its next phase
struct Checkout: TaskCheckpoint { var phase = "pay"; var payments: [TaskID] = [] }

let payment = TaskType<String, Step, String>(
    "app.payment", version: 1, initial: { _ in Step(phase: "charge") },
    abort: { run in try await run.commit { _, _ in .aborted(nil) } }
) {
    Phase("charge") { run in
        let key = try await run.memo("idempotencyKey", default: UUID().uuidString)   // stable across reruns
        let receipt = try await charge(run.input, key: key)
        try await run.commit { _, _ in .completed(receipt) }
    }
}

let checkout = TaskType<[String], Checkout, [String]>(
    "app.checkout", version: 1, initial: { _ in Checkout() },
    abort: { run in try await run.commit { _, _ in .aborted(nil) } }
) {
    Phase("pay") { run in
        try await run.commit { tx, current in
            var payments: [TaskID] = []
            for card in run.input { payments.append(try await tx.createTask(payment, input: card, ownedBy: current.id)) }
            return .waiting(Checkout(phase: "done", payments: payments), on: payments, policy: .failFast)
        }
    }
    Phase("done") { run in
        let receipts = try await run.outcomes(of: run.checkpoint.payments, as: String.self).compactMap(\.result)
        try await run.commit { _, _ in .completed(receipts) }
    }
}

let shop = Extension("shop") { payment; checkout }
let id = try await conversation.commit { tx in try await tx.createTask(checkout, input: ["visa", "amex"]) }
let outcome = try await harness.waitForTask(id, as: [String].self)   // .completed, .failed, .aborted, …
```

Every phase transition is a checkpoint; after a crash the task continues from the last one. Pass `version:` and
`migrate:` to upgrade live tasks, and `abort:` to undo a task's effects when it is aborted. `harness.taskGraph()`,
`taskGraphs()`, and `inspect()` show what is running.

A task waits for time by ending its phase asleep: `try await run.sleep(until: date, then: Step(phase: "remind"))`, or
`.sleeping(checkpoint, until:)` from a commit. A sleeping task holds no invocation and survives restarts; once the harness
clock reaches the date, it continues in the checkpoint's phase. `run.timer(after:_:)` paces work inside a phase.

A task that crashes cut off five times in a row without committing a new state is parked rather than run again
(`Settings(restartLimit:)`): `inspect()` shows it blocked with `.restartLimit`, `onReport` gets `.taskParked`, and
`harness.retryTask(_:)` runs it again.

### More hooks and wraps

```swift
Extension("guard") {
    Hook.beforeRequest { messages, _ in messages + [.user(UserMessage(content: [.text("Answer briefly.")]))] }
    Hook.afterResponse { message, context in log(message.usage) }
    Hook.afterTools { assistant, results, context in … }
    Hook.beforeCompact { request, _ in request.reason == "manual" ? nil : .decline }   // or .summary("…")
    Wrap.tool("get_weather") { call, context, next in try await next(nil) }            // decorate any extension's tool
    Wrap.section("preamble") { input, next in (try await next()).map { $0 + "\nBe kind." } }
}
```

Hooks get a `HookContext` with `memo` and `document(_:)`; sections get `input.shown` (sections already in effect) and
`input.document(_:)`.

### Calling a model from a tool or task

```swift
let summary = try await call.harness.models.complete(.anthropic("claude-haiku-4-5"), context: ModelContext(
    systemPrompt: "Summarize in one sentence.", messages: [.user(UserMessage(content: [.text(text)]))]))
return ToolResult(output: [.text(summary.text)], usage: summary.usage)   // the spend counts in pi.usage
```

`models.stream(...)` yields text and thinking deltas, completed tool calls, and the final message.

### Files

```swift
let harness = try await Harness.open(
    .sqlite(at: url), models: models, extensions: [.codingTools(images: .native)],
    environment: .directory(URL.documentsDirectory.appending(path: "Workspace")))
```

`read` returns images too; `images: .native` orients, converts, and shrinks them to the model's limits with ImageIO
(pi-durable's Photon processor, natively), and without it images within the byte limit pass through as they are.

The agent sees the directory as `/` and cannot leave it; a conversation's `cwd` is a path inside it. There is no
shell on iOS, so `bash` is not included. On macOS, `.directory(url, shell: true)` adds a shell (commands run in the
directory's real location and are not confined), and `.local` is the Mac's own file system and shell, like pi-durable's
`NodeExecutionEnv`; pair either with `Extension.codingTools(shell: true)` or
`Extension.builtinTools(name: "shell", [.bash(commandPrefix: "source .venv/bin/activate")])`. To give each
conversation its own sandbox, choose it per conversation, like pi-durable's `env` function:

```swift
environment: .perConversation { target in
    let project = try await target.document(projectDocument).folder
    return project.isEmpty ? nil : .directory(projects.appending(path: project))
}
```

Your own file system, such as a remote machine or an in-memory store, implements `CustomExecutionEnvironment` (file
operations, and optionally `run` for commands) and plugs in with `.custom(_:)`. Check it with
`Runtime.shared.runEnvironmentConformance { .custom(MyFileSystem()) }`, pi-durable's own conformance suite.

The app can use a conversation's environment directly, to show its files or run a command in its directory, and tools,
task phases, and sections reach the one built for their call:

```swift
let env = try await harness.environment(for: conversation.id)!
let files = try await env.listDirectory(".")
let tree = try await env.listFiles(".", options: ListFilesOptions(exclude: ["node_modules"]))   // honors .gitignore
try await env.write("notes", to: "notes.md")
let result = try await env.run(.argv(["git", "status", "--porcelain"])) { chunk in print(chunk.stream, chunk.text) }
for try await change in env.watch([WatchTarget("/", recursive: true)]) { reload(change) }

let tool = Tool("count_files", description: "Count files") { (call: ToolCallContext) in
    "\(try await call.environment()?.listDirectory(".").count ?? 0)"
}
```

## SwiftUI

```swift
struct ChatView: View {
    let conversation: Conversation
    @State private var view: ConversationView?
    @State private var draft = ""

    var body: some View {
        List {
            ForEach(view?.entries ?? []) { entry in
                if entry.kind == .user || entry.kind == .assistant { Text(entry.text) }
            }
            if let partial = view?.streamingMessage { Text(partial.text).foregroundStyle(.secondary) }
            ForEach(view?.live.tools ?? []) { tool in Label(tool.output ?? tool.name, systemImage: "hammer") }
        }
        .safeAreaInset(edge: .bottom) {
            TextField("Message", text: $draft).onSubmit {
                let text = draft
                draft = ""
                Task { try await conversation.submit(text) }
            }
        }
        .task {
            do {
                for try await view in conversation.views() { self.view = view }
            } catch {}
        }
    }
}
```

`views()` buffers only the newest view, so a busy UI skips intermediate states. For fine-grained deltas (text appends, tool output), use agent events:

```swift
let stream = try await harness.watchEvents(conversation.id)
initialize(stream.snapshot)
for try await events in stream {          // one batch per commit
    for event in events { apply(event) }
}
```

## Busy conversations

```swift
try await conversation.write(EntryDraft(kind: "app.note", data: "seen"))  // display-only: appended at once, even mid-run
try await conversation.submit("Hi!", entry: InputEntry(kind: "app.chat", data: ["author": "Ada"]))  // input as your own entry
try await conversation.submit("Also run the tests")                      // follow-up (default)
try await conversation.submit("Use pnpm, not npm", whenBusy: .steer)    // joins the running work
try await conversation.submit("Only if idle", whenBusy: .reject)        // throws .conversationBusy
try await conversation.abort()                                         // stop and withdraw queued inputs
```

## Persistence and recovery

```swift
let harness = try await Harness.open(.sqlite(at: url), models: models, extensions: [assistant])
let root = try await harness.root()          // the same root as last time
// Unfinished runs continue automatically (pass `resume: false` to delay).

let submission = try await root.submit("Hello", requestId: "greeting-1")
// After a crash, the same requestId finds the same submission instead of submitting twice:
let again = try await root.submit("Hello", requestId: "greeting-1")
let settled = try await harness.submission(submission.id)?.wait()
```

Install the same extensions after a restart so pending tool calls can resume.

pi-durable 1.4 migrates a SQLite storage to its schema version 2 when it opens it, and earlier versions can't open a
migrated database: once an app ships this version, its users' storages can't go back to an older PiDurableKit.

`harness.wake()` says when the harness next needs a running process: `active` while work can run, `at` for the earliest
sleep. With `Harness.open(onWake:)`, the harness arms no timer for sleeping tasks and tells the app instead, which can
schedule a background task and call `harness.resume()` when it runs. `Harness.open(timer:)` arms the harness's other
timers, for example with `HarnessTimer.dispatch(declineBackground: true)` in a process that should be free to suspend.

`onReport` gets a `HarnessReport`: the message, and what it was about (`.sessionFailed`, `.taskFaulted`, `.taskParked`,
`.extensionError`, `.hostError`, …), with the task and extension when known.

`Harness.open(telemetry:)` records content-free spans, events, and metrics (submissions, task phases, entries, model
requests, by ID) in a `Telemetry` recorder: `Telemetry.sqlite(at:)` keeps them for a week in a SQLite file,
`Telemetry.memory()` in memory. Read them back with `telemetry.traces(_:)`, `trace(_:)`, and `metrics(_:)`;
`Telemetry.schemas()` describes every name.

A storage call that throws fails the harness, which closes itself: later calls throw `PiDurableError.sessionFailed`, and
`harness.closed()` returns `.failed(message)`. Reopen it; reopening recovers from what was committed.

## Your own state

```swift
struct Todos: Codable, Sendable { var items: [String] = [] }
let todos = Document("app.todos", initial: Todos())

try await conversation.update(todos) { $0.items.append("Write docs") }   // one atomic commit
let current = try await conversation.document(todos)
for try await value in conversation.values(of: todos) { … }
```

Documents can also live in the session (`scope: .session`, read with `harness.document(_:)`) or a task
(`scope: .task`), form keyed families (`keyed: true`, then `key:`), keep their history (`history: .rewindable`, then
`asOf:`), and migrate (`version: 2, migrate: { stored, fromVersion in … }`). Each write stores only what changed.
`Harness.open(onConversationCreated:)` and `root(initialize:)` / `createConversation(initialize:)` seed documents in
the creating commit.

Typed transcript entries:

```swift
let note = EntryType<Note>("app.note")
try await conversation.write(note, Note(text: "Opened settings"))
let notes = view.entries.compactMap { $0.data(as: note) }
```

### Storage on your own SQLite database

pi-durable's portable SQLite storage runs on any database that implements its small facade, so it can share a database
with the rest of your app, use encryption, or live in an app group:

```swift
final class AppDatabase: SQLiteDatabase { /* execute, run, get, all, transaction, close */ }
let harness = try await Harness.open(.sqlite(database: AppDatabase(…)), models: models)
```

The contract is pi-durable's: a transaction's work uses the handle passed to its body, and every other operation waits
until it finishes.

To keep pi-durable's tables apart from your own in a shared database, or to keep several storages in one file, give
each a table prefix: `.sqlite(database: AppDatabase(…), tablePrefix: "agent_")` (also `.sqlite(at:tablePrefix:)`).
Changing a prefix doesn't move existing data.

### Replicating a harness

`harness.commits()` delivers every commit's changes as soon as they are stored: conversations, entries, tasks,
submissions, and document operations. `Runtime.applyOperations(_:to:)` applies a document change's operations to the
previous value.

### Other storage and plain sessions

`Storage.jsonl(in:directory:)` keeps pi-durable's JSONL storage on a `CustomExecutionEnvironment`, for example a synced
or encrypted file system. `Storage.custom(_:)` takes pi-durable's whole `Storage` interface implemented in Swift
(`CustomStorage`, records as JSON); validate it, or your `SQLiteDatabase`, with
`Runtime.shared.runStorageConformance { .custom(MyStorage()) }`.

`Session.open(_:)` opens a plain pi-durable session (`createSession`) without agents or a task scheduler: atomic commits
of conversations, entries, and documents, the same storage formats, and its commit stream.

pi-durable's `IndexedDbStorage` is for browsers; JavaScriptCore has no IndexedDB, so it isn't available here.

## Models and providers

`Models()` registers every built-in pi-ai provider. iOS has no environment variables, so pass keys explicitly (store them in the Keychain):

As in pi, the built-in providers also get models released after this package was built, from pi.dev's catalog (`ModelCatalog`, kept in Caches for offline use). Call `models.refresh()` at launch to check for them (at most every four hours per provider with a credential), then list the models again. `Models(catalog: nil)` keeps to the bundled models.

```swift
let models = Models(credentials: .keychain)
try await models.setAPIKey(anthropicKey, for: .anthropic)
try await models.setAPIKey(openAIKey, for: .openAI)
let catalog = try await models.models(for: .anthropic)

// Your own providers (pi-ai `createProvider`, like a models.json custom provider):
try await models.register(CustomProvider(
    id: "gateway", baseURL: URL(string: "https://gateway.example.com/v1")!, api: .openAICompletions,
    apiKey: gatewayKey, headers: ["X-Tenant": "acme"],                       // sent with every model's requests
    models: [
        .init(id: "llama3.1:8b", contextWindow: 131_072, compat: ["supportsDeveloperRole": false]),
        .init(id: "claude", api: .anthropicMessages, headers: ["X-Route": "anthropic"]),   // mixed APIs, per-model headers
    ]))
```

`models.unregister("gateway")` takes a provider away again (any provider, built-in ones included); its stored
credential stays until `models.logout(from:)`.

Headers work as in pi-ai: a model's `headers` (inheriting its provider's) go with that model's requests, and
`Settings.Stream.headers` go with every request.

A custom provider can sign in with OAuth instead of an API key. Give it an `oauth` (a browser sign-in with PKCE and a
loopback redirect, or a device code, and the token endpoint) and sign in with `models.login(to:interaction:)`, as for
the built-in sign-ins; requests send the access token as the key and refresh it before it expires:

```swift
try await models.register(CustomProvider(
    id: "service", baseURL: URL(string: "https://api.example.com/v1")!, api: .openAIResponses,
    oauth: .init(
        signIn: .browser(authorizationURL: URL(string: "https://auth.example.com/authorize")!,
                         redirectURI: URL(string: "http://localhost:1455/callback")!),   // or .deviceCode(deviceAuthorizationURL:)
        tokenURL: URL(string: "https://auth.example.com/oauth/token")!, clientID: "…", scope: "…"),
    models: [.init(id: "model")]))
try await models.login(to: "service", interaction: .webAuthenticationSession())
```

With `signIn: nil`, store tokens from a sign-in made elsewhere instead:
`models.setCredential(.oauth(accessToken:refreshToken:expiresAt:), for: "service")`.

A custom provider can also serve a built-in provider's models, such as a gateway in front of it, or the same API with
other credentials: give it `catalog: .anthropic`, and its models are Anthropic's catalog (the built-in models and
pi.dev's newer ones), each pointed at the custom provider, refreshed as `models.refresh` refreshes it, under its own
credential.

`ProviderInfo.acceptsAPIKey` says which providers take an API key; some built-in ones only have a sign-in.

> Shipping provider API keys inside an app exposes them to anyone who inspects it. For production, point a `CustomProvider` (or `Settings.Stream.headers`) at your own backend proxy.

### Apple Foundation Models

Apple's on-device model, Private Cloud Compute, and any other FoundationModels `LanguageModel` work as a provider
(iOS 27, macOS 27, visionOS 27), with no keys:

```swift
let models = Models()
try await models.register(FoundationModelsProvider())          // "apple": on-device and private-cloud-compute
let harness = try await Harness.open(
    .sqlite(at: url), models: models, extensions: [assistant],
    settings: Settings(compaction: .forContextWindow(8192)))     // compaction sized for the on-device window
let root = try await harness.root(agent: AgentChange(model: .appleOnDevice))   // or .applePrivateCloudCompute

// Pick the models, or bring your own:
try await models.register(FoundationModelsProvider(models: [
    .onDevice(SystemLanguageModel(useCase: .contentTagging), id: "tagging"),
    .init("my-model", model: MyLanguageModel()),
]))
```

Everything else works as with any provider: tools (parallel calls included) run durably in pi-durable, never in the
session; nested calls, code mode, hooks, steering, follow-ups, aborts, compaction, and restarts behave the same. Answers
and reasoning stream; images reach models with vision (others get a placeholder); usage lands in `pi.usage` at no cost;
thinking levels apply to models that reason (Private Cloud Compute).

- **Compaction.** The on-device window is 8,192 tokens (Private Cloud Compute's 32,768). pi-durable's default compaction
  keeps 20,000 tokens and could never compact such a window, so open the harness with
  `Settings(compaction: .forContextWindow(…))`. A harness that also serves large-window models can give these models
  their own thresholds instead: `Settings.Compaction(modelOverrides: [.appleOnDevice: .forContextWindow(8192)])`. An
  overflow says so in its error.
- **Availability.** `FoundationModelsProvider.Model.isAvailable` (or `SystemLanguageModel.default.availability`) tells
  whether Apple Intelligence is on and the model downloaded; offer the model only then. A model still downloading, a
  rate limit, or an unreachable Private Cloud Compute fails with an error pi-durable retries; guardrail violations and
  refusals are not retried.
- **Caching.** Foundation Models caches a prompt inside its `LanguageModelSession` only, so the provider keeps each
  conversation's session (by pi-durable's provider session ID) and extends it while the next request continues the
  same transcript: later turns, tool rounds, and prompt section changes, which are appended in place, read the cache. A
  reset, compaction, fork, edit, tool change, or restart starts a new session. The most recently used 8 sessions are
  kept, none idle for over 15 minutes; `Settings.Stream(cacheRetention: "none")` starts every request fresh. Foundation
  Models reports no cached tokens for a request that ends at a tool call, though it reads the cache, and the iOS
  Simulator reports none at all.
- **Limits.** A tool whose parameters Foundation Models cannot express is not offered to these models: a parameter
  without a `type` (`Type.Any()`, `Type.Unknown()`), with a list of types (`"type": ["string", "null"]`), or built
  from `oneOf`/`allOf` (use `anyOf`). `minLength`, `format`, and `patternProperties` are ignored. Deferred requests
  don't apply. Private Cloud Compute needs Apple's entitlement in your app.

### Signing in with a subscription (OAuth)

Providers with an OAuth sign-in (Anthropic for Claude Pro/Max, OpenAI for ChatGPT, GitHub Copilot, OpenRouter, …) report it in `ProviderInfo.oauth`. Keep credentials in the Keychain so the sign-in survives relaunches:

```swift
let models = Models(credentials: .keychain)

// In a button action:
try await models.login(to: .anthropic, interaction: .webAuthenticationSession())
// From now on requests use the subscription; tokens refresh automatically and the refresh is written back.
let harness = try await Harness.open(.sqlite(at: url), models: models)

try await models.logout(from: .anthropic)
```

The sign-in page opens in an `ASWebAuthenticationSession` sheet. Providers redirect to `http://localhost:<port>/callback` (the redirect URI their OAuth clients are registered with), so PiDurableKit runs pi-ai's loopback redirect server inside the app with Network.framework, bound to the loopback interface only. When the redirect arrives, the code is exchanged for tokens and the sheet closes by itself. Should the browser show the redirect's page first, it is a plain green checkmark (or red cross) with pi-ai's message, in place of pi-ai's own branded page (`JS/src/shims/oauth-page.ts`). Dismissing the sheet cancels the sign-in, and so does cancelling the task that called `login`.

Sign in with ChatGPT registers the app installation with OpenAI; `login` passes `Models.installationID` (a UUID kept in `UserDefaults`) unless you give your own `installationID:`.

Device-code sign-ins (GitHub Copilot) open the verification page and copy the code to the pasteboard; pass `onDeviceCode:` to show it yourself. For full control, build a `LoginInteraction` from closures: `presentSignInPage` (show a URL until cancelled), `prompt` (answer select/text/code questions), and `notify` (progress, URLs, device codes).

`CredentialStore` is a three-method protocol, so you can also keep credentials somewhere else, such as an app-group Keychain (`.keychain(service:accessGroup:)`) or your own server. pi-ai serializes refreshes per provider, so concurrent requests never refresh one token twice.

> Subscription sign-ins use the providers' first-party OAuth clients, the same ones pi and other coding agents use. Check that this is allowed for your use before shipping it.

### Testing and previews

```swift
let models = Models(builtinProviders: false)
let faux = FauxProvider()
try await models.register(faux)
try await faux.append(.toolCall("get_weather", ["city": "Paris"]))
try await faux.append(.text("It is sunny in Paris."))
// or answer dynamically:
try await faux.respond { messages, _ in .text("Echo: \(messages.last?.text ?? "")") }

let harness = try await Harness.open(models: models, extensions: [assistant])
let root = try await harness.root(agent: AgentChange(model: faux.model))
```

## How it works

`Sources/PiDurableKit/Resources/pi-durable.js` is a single JavaScriptCore bundle of pi-durable, pi-ai, and chord, built by esbuild from `JS/`. JavaScriptCore has no web platform, so the bundle carries small polyfills whose platform parts are implemented in Swift:

| JavaScript | Swift |
|---|---|
| `fetch`, streaming `Response.body` | `URLSession` data delegate |
| `node:sqlite` (pi-durable's SQLite storage) | `SQLite3` |
| `setTimeout`, `setInterval` | `DispatchQueue` |
| `crypto.getRandomValues` | `SecRandomCopyBytes` |
| `console` | `os.Logger` (or `Runtime.Configuration.log`) |
| `crypto.subtle.digest` (PKCE) | CryptoKit |
| `node:http` (OAuth loopback redirect) | Network.framework `NWListener` on the loopback interface |
| pi-ai `CredentialStore` | `CredentialStore` (Keychain, memory, or yours) |
| pi-durable `ExecutionEnv` (sandbox files) | POSIX file calls on the sandbox's real directory |
| `Shell.exec` (macOS `.local`, `.directory(_:shell:)`) | `posix_spawn` in its own process group |
| `WebAssembly.compile`, `instantiate` (code mode's QuickJS) | JavaScriptCore's synchronous `WebAssembly.Module` (its promise APIs need a run loop) |
| A worker thread for code mode's VM | A second JavaScriptCore context on its own queue, as pi-codemode's `RemoteCodemodeSandbox` remote |
| pi-durable `ImageProcessor` | ImageIO (`NativeImageProcessor`) |

`TextEncoder`/`TextDecoder`, `AbortController`, `EventTarget`, `Blob`/`FormData`, and `Headers`/`Request`/`Response` are implemented in TypeScript; `ReadableStream` comes from `web-streams-polyfill` and newer ECMAScript built-ins from `core-js`. All JavaScript runs on one serial queue per `Runtime`, which is also the executor of the actor that owns the `JSContext`. Swift and JavaScript talk through a small JSON bridge (`JS/src/bridge/`).

Use `Runtime(configuration:)` to give agents their own JavaScript thread or a custom `URLSessionConfiguration`, and pass it to `Models(runtime:)`.

Providers see the app, not pi: requests carry its `User-Agent` (`Pelican/1.2 (iOS 27.0)`) and its attribution headers, if it has any, instead of pi-durable's attribution to pi, and OpenAI's sign-in, OpenAI Codex's originator and xAI's referrer use its name, where pi-ai would say "pi". `Runtime.Client` holds them, from the app's bundle by default; set `Runtime.Configuration.client` to change them, with `attribution:` for OpenRouter's app title and referrer. Its `identity` (pi-ai `ClientIdentity`) goes to every `Models` and harness; `Harness.open(identity:)`, `models.withIdentity(_:)`, and `ModelOptions(identity:)` override it for a harness, a collection, or a request. `JS/build.mjs` patches the other places to `clientName()` from `JS/src/shims/client.ts`, failing the build if an update moves them. Radius's OAuth client ID (`pi-gateway`) stays: it's the ID Radius knows.

## Updating pi-durable

The bundled versions are pinned exactly in `JS/package.json` and exposed as `PiDurable.version`, `PiDurable.piAIVersion`, `PiDurable.chordVersion`, and `PiDurable.piCodemodeVersion`.

```sh
cd JS
npm ci
npm run update            # latest pi-durable, with the pi-ai, chord, and pi-codemode releases it depends on
npm run update -- 1.0.5   # or a specific version
cd .. && swift test
```

`update` installs the release, type-checks the bridge against the new type definitions (so upstream API changes fail loudly), rebuilds the bundle, and regenerates `Generated/Versions.swift`. Commit the result.

In CI, `.github/workflows/update-pi-durable.yml` does this daily (or on demand with a version), runs the macOS and iOS Simulator test suites, and opens a pull request — a draft when tests fail. `.github/workflows/ci.yml` checks that the committed bundle matches `package-lock.json` and runs the tests on every push.

## Licenses

PiDurableKit's own code is dedicated to the public domain under [CC0 1.0](LICENSE).

The JavaScript bundle includes open source packages under MIT, Apache-2.0, BSD-3-Clause, and Unlicense terms
(pi-durable, pi-ai, chord, the Anthropic, OpenAI, and Google SDKs, and their dependencies). Their licenses require
shipping their notices with your app: show `PiDurable.thirdPartyNotices` on an acknowledgements screen, or add it to
your Settings bundle. The build regenerates the notices from the bundled packages on every update, and fails if a
bundled package has no license to include.

## Documentation

The package has a DocC catalog (`Product ▸ Build Documentation` in Xcode); CI builds it with warnings as errors.

## Development

```sh
cd JS && npm ci && npm run build   # after changing JS/src
swift test                          # macOS
xcodebuild test -scheme PiDurableKit -destination 'platform=iOS Simulator,name=iPhone 17'
```

`cd JS && npm test` runs the JavaScript unit tests. The Swift tests run real pi-ai provider SDKs (Anthropic, OpenAI Responses, OpenAI-compatible) and pi-ai's real Anthropic OAuth flow (PKCE, loopback redirect, token exchange, refresh) against a mock HTTP server, plus the faux provider for harness behavior, persistence, and crash recovery.
