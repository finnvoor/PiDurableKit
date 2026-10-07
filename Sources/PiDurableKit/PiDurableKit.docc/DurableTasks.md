# Durable Tasks

State machines that checkpoint every step and continue after a restart.

## Overview

A ``TaskType`` is pi-durable's `defineTask`. Its checkpoint names the phase that runs next; each phase commits the
next checkpoint, a wait for other tasks, or an outcome.

```swift
struct Step: TaskCheckpoint { var phase: String }

let payment = TaskType<String, Step, String>(
    "app.payment", version: 1, initial: { _ in Step(phase: "charge") },
    abort: { run in try await run.commit { _, _ in .aborted(nil) } }
) {
    Phase("charge") { run in
        let receipt = try await charge(run.input, key: try await run.memo("key", default: UUID().uuidString))
        try await run.commit { _, _ in .completed(receipt) }
    }
}
```

Install task types in an ``Extension``; create tasks in a ``Transaction``, or from a tool with
``ToolCallContext/createTask(_:input:ownedByConversation:background:)``. Child tasks are created with
`ownedBy: current.id` and awaited with ``NextState/waiting(_:on:policy:)``. ``Harness/taskGraph()`` and
``Harness/inspect()`` show what is running.
