# Building Extensions

Tools, prompt sections, hooks, wraps, and durable tasks, bundled under a name.

## Overview

An ``Extension`` is pi-durable's unit of behavior. Install extensions when opening a harness, or later with
``Harness/install(_:)``; a conversation selects extensions by name (by default every installed one) and can change its
selection with ``AgentChange``.

```swift
let assistant = Extension("assistant") {
    PromptSection("preamble", tag: false, text: "You are a concise assistant on an iPhone.")
    Tool("get_weather", description: "Weather in a city", parameters: .object(["city": .string("City")])) {
        (arguments: Weather, call) in "Sunny in \(arguments.city)"
    }
    Hook.beforeTool { call, _ in call.name == "delete_note" ? .block("Needs approval") : .allow }
}
```

## Tools

Each tool call runs as its own durable task. ``ToolCallContext`` is pi-durable's tool API: stream output, report
details and diagnostics, commit transactions, create and await tasks, drive other conversations (subagents), keep memos
that survive reruns, and read or watch documents.

## Hooks and wraps

``Hook`` observes or adjusts the built-in generation, tool, and compaction tasks, and your own task types. ``Wrap``
decorates a tool or section of any extension by name.
