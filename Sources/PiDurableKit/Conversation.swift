import Foundation

/// A durable transcript and the agent that works on it (pi-durable `Conversation`).
///
/// A conversation handle holds no state; compare handles by ``id``.
public struct Conversation: Sendable, Identifiable, Hashable {
    public let harness: Harness
    public let id: ConversationID

    init(harness: Harness, id: ConversationID) {
        self.harness = harness
        self.id = id
    }

    public static func == (lhs: Conversation, rhs: Conversation) -> Bool {
        lhs.id == rhs.id && lhs.harness === rhs.harness
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(ObjectIdentifier(harness))
    }

    private func call<Result: Decodable & Sendable>(_ method: String, _ arguments: BridgeArguments = [:]) async throws -> Result {
        var arguments = arguments
        arguments["conversation"] = id
        return try await harness.call(method, arguments)
    }

    private func perform(_ method: String, _ arguments: BridgeArguments = [:]) async throws {
        var arguments = arguments
        arguments["conversation"] = id
        try await harness.perform(method, arguments)
    }

    // MARK: Submitting

    /// What to do with input submitted while the conversation is busy.
    public enum WhenBusy: String, Encodable, Sendable {
        /// Queue it; it starts the next run when the current one answers. The default.
        case followUp
        /// Queue it; it joins the running work after the current tool round.
        case steer
        /// Throw ``PiDurableError/conversationBusy(_:)`` and write nothing.
        case reject
    }

    /// Durably admits user input. A built-in generation task calls the model and appends the answer.
    ///
    /// - Parameters:
    ///   - text: The user's input.
    ///   - whenBusy: What to do when the conversation is busy.
    ///   - requestId: A deduplication key: submitting again with the same key returns the existing submission, so a
    ///     retry after a crash never submits twice.
    @discardableResult
    public func submit(_ text: String, whenBusy: WhenBusy = .followUp, requestId: String? = nil) async throws -> Submission {
        try await submit([.text(text)], whenBusy: whenBusy, requestId: requestId)
    }

    /// Durably admits user input made of text and images.
    @discardableResult
    public func submit(_ content: [ContentBlock], whenBusy: WhenBusy = .followUp, requestId: String? = nil) async throws
        -> Submission
    {
        let content: JSONValue =
            if content.count == 1, let text = content[0].text { .string(text) } else { try JSONValue(encoding: content) }
        let submission: JSONValue = [
            "type": "input",
            "content": content,
            "whenBusy": .string(whenBusy.rawValue),
            "requestId": requestId.map(JSONValue.string) ?? .null,
        ]
        return try await admit(submission)
    }

    /// Appends an entry without asking the model anything. While busy, it is placed at the next boundary.
    @discardableResult
    public func write(_ entry: EntryDraft, requestId: String? = nil) async throws -> Submission {
        try await admit([
            "type": "write",
            "entry": try JSONValue(encoding: entry),
            "requestId": requestId.map(JSONValue.string) ?? .null,
        ])
    }

    private func admit(_ submission: JSONValue) async throws -> Submission {
        guard case .object(var object) = submission else { fatalError("submission must be an object") }
        object = object.filter { !$0.value.isNull }
        let id: SubmissionID = try await call("conversation.submit", ["submission": JSONValue.object(object)])
        return Submission(harness: harness, id: id)
    }

    // MARK: Agent

    /// The conversation's agent, resolved against the installed extensions and settings.
    public func agent() async throws -> Agent {
        try await call("conversation.agent")
    }

    /// Changes the stored agent choices in one commit. A change applies from the next model request.
    public func configure(_ change: AgentChange) async throws {
        try await perform("conversation.configure", ["change": change])
    }

    // MARK: Control

    /// Stops the conversation: withdraws queued inputs, aborts its current work, and returns once it is idle.
    ///
    /// - Parameter background: Also abort background work this conversation owns, such as persistent subagents.
    public func abort(background: Bool = false) async throws {
        try await perform("conversation.abort", ["background": background])
    }

    /// Waits until the conversation (and the work it owns) has no running work.
    public func waitForIdle() async throws {
        try await perform("conversation.waitForIdle")
    }

    /// Starts a new context. The model no longer sees older entries, but they stay in storage.
    ///
    /// - Parameter handoff: A note the new context starts from, as a user message.
    public func reset(handoff: String? = nil) async throws {
        try await perform("conversation.reset", ["handoff": handoff])
    }

    /// Summarizes older entries so the model sees less. The conversation keeps working while the summary is made.
    ///
    /// - Returns: The compaction task; wait for it with ``Harness/waitForTask(_:)``.
    @discardableResult
    public func compact(instructions: String? = nil) async throws -> TaskID {
        try await call("conversation.compact", ["instructions": instructions])
    }

    /// A new conversation that sees this one's entries up to `entry` and continues independently.
    ///
    /// - Parameters:
    ///   - entry: The last entry the fork inherits.
    ///   - agent: Changes to the agent it inherits.
    ///   - initialize: Runs in the creating commit.
    public func fork(
        at entry: EntryID, agent: AgentChange? = nil, initialize: (@Sendable (Transaction, ConversationID) async throws -> Void)? = nil
    ) async throws -> Conversation {
        try await harness.creating(initialize) { initializer in
            try await self.call("conversation.fork", ["at": entry, "agent": agent, "initialize": initializer])
        }
    }

    // MARK: Reading

    /// The current view: active transcript and live state.
    public func view() async throws -> ConversationView {
        try await call("conversation.view")
    }

    /// The view after every commit that touches the conversation, starting with the current one.
    ///
    /// Only the newest view is buffered, so a slow consumer skips intermediate states. Ideal for SwiftUI:
    ///
    /// ```swift
    /// .task {
    ///     for try await view in conversation.views() { self.view = view }
    /// }
    /// ```
    public func views() -> AsyncThrowingStream<ConversationView, Error> {
        // Updates carry only new entries after the first, so none may be dropped; views can be.
        let updates = harness.engine.stream(
            "conversation.watch", ["harness": harness.id, "conversation": id], of: ConversationViewUpdate.self)
        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                var entries: [Entry] = []
                do {
                    for try await update in updates {
                        let view = update.view(after: entries)
                        entries = view.entries
                        continuation.yield(view)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The active entries and the model context the next request would send.
    ///
    /// - Parameter entry: The model context as of this earlier visible entry, the view `fork(at:)` would start with.
    public func context(at entry: EntryID? = nil) async throws -> (entries: [Entry], messages: [Message]) {
        struct Result: Decodable, Sendable {
            let entries: [Entry]
            let messages: [Message]
        }
        let result: Result = try await call("conversation.context", ["at": entry])
        return (result.entries, result.messages)
    }

    /// The conversation's whole history, newest first, including entries before resets and forks' parents.
    ///
    /// - Parameters:
    ///   - oldest: The oldest entry that may be returned.
    ///   - newest: The newest entry that may be returned.
    ///   - order: Newest first (the default) or oldest first. A cursor continues in its scan's order.
    ///   - limit: The page size.
    ///   - cursor: The `next` cursor of the previous page.
    public func entries(
        from oldest: EntryID? = nil, through newest: EntryID? = nil, order: ScanOrder? = nil, limit: Int = 50,
        after cursor: Cursor? = nil
    ) async throws -> Page<Entry> {
        try await call(
            "conversation.entries",
            ["minEntryId": oldest, "maxEntryId": newest, "order": order, "limit": limit, "cursor": cursor])
    }

    // MARK: Documents

    /// The current value of one of your documents, or its initial value when it was never written.
    ///
    /// - Parameters:
    ///   - document: The document.
    ///   - key: The member of a keyed document family.
    ///   - entry: For rewindable documents, the value as of this entry.
    public func document<Value>(_ document: Document<Value>, key: String? = nil, asOf entry: EntryID? = nil) async throws -> Value {
        try await harness.document(document, of: .conversation(id), key: key, asOf: entry)
    }

    /// Changes one of your documents in a single atomic commit. Only what changed is stored.
    @discardableResult
    public func update<Value>(
        _ document: Document<Value>, key: String? = nil, seed: JSONValue? = nil,
        _ change: @escaping @Sendable (inout Value) throws -> Void
    ) async throws -> Value {
        try await harness.update(document, of: .conversation(id), key: key, seed: seed, change)
    }

    /// The document's value after every commit that changes it, starting with the current one.
    public func values<Value>(of document: Document<Value>, key: String? = nil) -> AsyncThrowingStream<Value, Error> {
        harness.values(of: document, owner: .conversation(id), key: key)
    }

    // MARK: Transactions

    /// Runs `body` in one atomic commit; ``Transaction/createTask(_:input:in:ownedBy:background:)`` defaults to this
    /// conversation.
    @discardableResult
    public func commit<T: Sendable>(_ body: @escaping @Sendable (Transaction) async throws -> T) async throws -> T {
        try await harness.commit(in: id, body)
    }

    /// Appends a typed entry without asking the model anything.
    @discardableResult
    public func write<Data>(_ type: EntryType<Data>, _ data: Data, model: [Message]? = nil, requestId: String? = nil) async throws
        -> Submission
    {
        try await write(try type.draft(data, model: model), requestId: requestId)
    }

    /// The view after every commit with the exact Chord operations that produced it (pi-durable `watch()`), for
    /// replicating the view elsewhere. Unlike ``views()``, nothing is skipped; a consumer far behind receives the
    /// newest whole view with no operations.
    public func changes() -> AsyncThrowingStream<ConversationChange, Error> {
        harness.engine.stream("conversation.changes", ["harness": harness.id, "conversation": id])
    }
}

/// One commit's change to a conversation view.
public struct ConversationChange: Decodable, Sendable {
    public let view: ConversationView
    /// Chord operations from the previous view to this one; empty for the first view.
    public let ops: [JSONValue]
}
