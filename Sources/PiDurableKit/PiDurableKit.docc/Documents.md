# Documents

Typed state stored next to the transcript and changed in atomic commits.

## Overview

A ``Document`` is pi-durable's `defineDoc`: a `Codable` value per conversation (default), per harness
(`scope: .session`), or per task (`scope: .task`), optionally keyed (`keyed: true`) and with history
(`history: .rewindable`). Each commit stores only what changed.

```swift
struct Todos: Codable, Sendable { var items: [String] = [] }
let todos = Document("app.todos", initial: Todos())

try await conversation.update(todos) { $0.items.append("Write docs") }
for try await value in conversation.values(of: todos) { render(value) }
```

Read documents in tools, tasks, hooks, and sections through their contexts; write them in a ``Transaction``. Seed new
conversations' documents with `onConversationCreated` or `initialize`, and upgrade stored values with `migrate`.
