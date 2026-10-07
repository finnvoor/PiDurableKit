# ``PiDurableKit``

Durable AI agents for iPhone, iPad, Mac, and Vision Pro: pi-durable running in JavaScriptCore, with a Swift API that mirrors it.

## Overview

Conversations, model turns, tool calls, and your own state are committed to storage before anything is shown. If the
app is killed mid-turn, reopening the storage picks the work up where it stopped.

PiDurableKit is a thin wrapper around [pi-durable](https://www.npmjs.com/package/@earendil-works/pi-durable). Its
concepts and names follow pi-durable's, so its README applies; ``PiDurable/documentation`` ships that README and the
type declarations of the bundled ``PiDurable/version``.

```swift
let models = Models(credentials: .keychain)
try await models.setAPIKey(anthropicKey, for: .anthropic)
let harness = try await Harness.open(.sqlite(at: url), models: models, extensions: [assistant])
let root = try await harness.root(agent: AgentChange(model: .anthropic("claude-sonnet-4-5")))

let settled = try await root.submit("What is the capital of France?").wait()
if case .done(_, let answer?) = settled.status {
    let entry = try await root.commit { tx in try await tx.entry(answer) }
    print(entry?.assistantMessage?.text ?? "")
}
```

## Topics

### Essentials

- <doc:GettingStarted>
- ``Harness``
- ``Conversation``
- ``Submission``
- ``Storage``

### Bundled pi-durable

- ``PiDurable``

### Models

- ``Models``
- ``ModelRef``
- ``CustomProvider``
- ``FauxProvider``
- <doc:SigningIn>

### Extensions

- <doc:BuildingExtensions>
- ``Extension``
- ``Tool``
- ``ToolCallContext``
- ``ToolResult``
- ``PromptSection``
- ``Hook``
- ``Wrap``
- <doc:JavaScriptExtensions>

### Agents

- ``AgentChange``
- ``Agent``
- ``Settings``
- ``ExecutionEnvironment``

### State

- <doc:Documents>
- ``Document``
- ``EntryType``
- ``Transaction``

### Durable tasks

- <doc:DurableTasks>
- ``TaskType``
- ``TaskRun``
- ``TaskRecord``
- ``TaskGraph``

### Observing

- ``ConversationView``
- ``AgentEventStream``
- ``CommitPublication``
