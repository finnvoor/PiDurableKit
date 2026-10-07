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
| `harness.root()`, `createConversation()`, `fork()` | `harness.root(agent:)`, `harness.createConversation(agent:)`, `conversation.fork(at:)` |
| `conversation.submit({ type: "input", … })` | `conversation.submit("…", whenBusy:, requestId:)` |
| `conversation.submit({ type: "write", … })` | `conversation.write(EntryDraft(…))` |
| `submission.wait()`, `tx.entry(AssistantEntry, id)` | `submission.wait()`, `tx.entry(id)?.assistantMessage` |
| `conversation.configure(change)` | `conversation.configure(AgentChange(…))` |
| `defineExtension`, `defineTool`, `section`, `hook` | `Extension`, `Tool`, `PromptSection`, `Hook` |
| `wrapTool`, `wrapSection` | `Wrap.tool`, `Wrap.section` |
| an extension written in JavaScript | `Extension(name, javaScript: source)` |
| `defineTask`, `TaskRuntime` | `TaskType`, `Phase`, `TaskRun` |
| `harness.commit()`, `conversation.commit()`, `Tx` | `harness.commit { tx in … }`, `conversation.commit { tx in … }`, `Transaction` |
| `ToolExecutionApi` (`commit`, `conversation`, `memo`, …) | `ToolCallContext` |
| `conversation.watch()` / `viewState()` | `conversation.changes()` / `conversation.views()`, `conversation.view()` |
| `watchEvents(harness, id)` → `snapshot`, `start(listener)` | `harness.watchEvents(id)` → `snapshot`, `for try await events in stream` |
| `defineDoc`, `defineDocFamily` + `tx.doc()` | `Document(…, scope:, history:, keyed:, migrate:)`, `update(_:_:)`, `values(of:)` |
| `defineEntry` | `EntryType`, `conversation.write(_:_:)`, `entry.data(as:)` |
| `taskGraph()`, `watchTaskGraph()`, `inspect()`, `getTask()` | `taskGraph()`, `taskGraphs()`, `inspect()`, `task(_:)` |
| `HarnessOptions.env`, `CodingTools` | `ExecutionEnvironment.directory(_:)` / `.perConversation { target in … }`, `Extension.codingTools()` |
| `harness.subscribeCommits()` | `harness.commits()` |
| `SqliteStorage` over a `SqliteDatabase` facade | `Storage.sqlite(database:)` with your `SQLiteDatabase` |
| pi-ai `models.completeSimple()`, `streamSimple()` | `models.complete(_:context:options:)`, `models.stream(_:context:options:)` |
| `ROOT_CONVERSATION_ID`, `ReadAfterWrite`, `StorageRejected` | `ConversationID.root`, `PiDurableError.readAfterWrite`, `.storageRejected` |
| `conversationCreated`, `init`, `now`, `onReport` | `onConversationCreated:`, `initialize:`, `clock:`, `onReport:` |
| `JsonlStorage`, `models.refresh()` | `Storage.jsonl(at:)`, `models.refresh()` |

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
    execute: async (args) => ({ content: [{ type: "text", text: String(1 + Math.floor(Math.random() * args.sides)) }] }),
  })],
});
"""#
try await harness.install(Extension("dice", javaScript: source))
```

The module is CommonJS and can `require` `@earendil-works/pi-durable` (and `/tools`, `/env`), `@earendil-works/pi-ai`,
and `@earendil-works/chord/context`. As in pi-durable, extension code is not sandboxed, so install only code you trust;
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
`waitForTask`, and `details`/`diagnostic`. Results can `addingTools(…)`, and tools can repair arguments
(`preparingArguments`) or bound their output (`limitingOutput`).

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
return ToolResult(content: [.text(summary.text)], usage: summary.usage)   // the spend counts in pi.usage
```

`models.stream(...)` yields text and thinking deltas, completed tool calls, and the final message.

### Files

```swift
let harness = try await Harness.open(
    .sqlite(at: url), models: models, extensions: [.codingTools()],
    environment: .directory(URL.documentsDirectory.appending(path: "Workspace")))
```

The agent sees the directory as `/` and cannot leave it; a conversation's `cwd` is a path inside it. There is no
shell on iOS, so `bash` is not included. To give each conversation its own sandbox, choose it per conversation, like
pi-durable's `env` function:

```swift
environment: .perConversation { target in
    let project = try await target.document(projectDocument).folder
    return project.isEmpty ? nil : .directory(projects.appending(path: project))
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
let settled = try await harness.submission(submission.id).wait()
```

Install the same extensions after a restart so pending tool calls can resume.

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

### Replicating a harness

`harness.commits()` delivers every commit's changes as soon as they are stored: conversations, entries, tasks,
submissions, and document operations.

## Models and providers

`Models()` registers every built-in pi-ai provider. iOS has no environment variables, so pass keys explicitly (store them in the Keychain):

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

Headers work as in pi-ai: a model's `headers` (inheriting its provider's) go with that model's requests, and
`Settings.Stream.headers` go with every request.

> Shipping provider API keys inside an app exposes them to anyone who inspects it. For production, point a `CustomProvider` (or `Settings.Stream.headers`) at your own backend proxy.

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

`TextEncoder`/`TextDecoder`, `AbortController`, `EventTarget`, `Blob`/`FormData`, and `Headers`/`Request`/`Response` are implemented in TypeScript; `ReadableStream` comes from `web-streams-polyfill` and newer ECMAScript built-ins from `core-js`. All JavaScript runs on one serial queue per `Runtime`, which is also the executor of the actor that owns the `JSContext`. Swift and JavaScript talk through a small JSON bridge (`JS/src/bridge.ts`).

Use `Runtime(configuration:)` to give agents their own JavaScript thread or a custom `URLSessionConfiguration`, and pass it to `Models(runtime:)`.

## Updating pi-durable

The bundled versions are pinned exactly in `JS/package.json` and exposed as `PiDurable.version`, `PiDurable.piAIVersion`, and `PiDurable.chordVersion`.

```sh
cd JS
npm ci
npm run update            # latest pi-durable, with the pi-ai and chord releases it depends on
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
