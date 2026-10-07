# Getting Started

Open a harness, create a conversation, and get answers.

## Models and credentials

``Models`` registers every built-in pi-ai provider. iOS has no environment variables, so keep credentials in a
``CredentialStore``, usually the Keychain:

```swift
let models = Models(credentials: .keychain)
try await models.setAPIKey(anthropicKey, for: .anthropic)
```

Or sign in to a subscription; see <doc:SigningIn>.

## A harness

A ``Harness`` is one open storage plus the machinery that runs agents on it. SQLite storage survives restarts:

```swift
let url = URL.applicationSupportDirectory.appending(path: "agent.sqlite")
let harness = try await Harness.open(.sqlite(at: url), models: models, extensions: [assistant])
```

Work a previous launch left unfinished continues once the harness opens. Install the same extensions every launch, so
their pending tool calls and tasks can resume.

## Conversations and submissions

```swift
let root = try await harness.root(agent: AgentChange(model: .anthropic("claude-sonnet-4-5")))
let submission = try await root.submit("Plan my week")
let settled = try await submission.wait()
```

`submit` durably admits the input; a built-in generation task answers it. ``Submission/wait()`` returns when it is
answered (`done`, with the answer entry) or can no longer be (`unanswered`, with a reason). Pass a `requestId` to make a
retried submission return the existing one instead of submitting twice.

## Showing a conversation

``Conversation/views()`` delivers the conversation's view after every commit, ideal for SwiftUI:

```swift
.task {
    for try await view in conversation.views() { self.view = view }
}
```

For coding-agent style deltas, use ``Harness/watchEvents(_:)``.
