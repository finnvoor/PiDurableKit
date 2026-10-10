import Foundation
import Testing
@testable import PiDurableKit

@Suite struct StreamingTests {
    @Test func eventsDescribeARun() async throws {
        let setup = try await FauxSetup.make(extensions: [Extension("weather", tools: [weatherTool])])
        try await setup.faux.append(.toolCall("get_weather", ["city": "Paris"]))
        try await setup.faux.append(.text("It is sunny in Paris today."))
        let root = try await setup.root()

        let stream = try await setup.harness.watchEvents(root.id)
        #expect(stream.snapshot.entries.isEmpty)
        let collector = Task { try await withTimeout {
            var batches: [[AgentEvent]] = []
            for try await batch in stream {
                batches.append(batch)
                if batch.contains(where: { if case .runEnd = $0 { true } else { false } }) { break }
            }
            return batches
        } }
        try await root.submit("Weather?")
        let batches = try await collector.value
        // One batch per commit.
        #expect(batches.count > 1)
        let events = batches.flatMap { $0 }
        #expect(events.contains { if case .runStart = $0 { true } else { false } })
        #expect(events.contains { if case .toolExecutionStart(_, "get_weather", let args) = $0 { args["city"] == "Paris" } else { false } })
        #expect(events.contains { if case .toolExecutionEnd(_, "get_weather", let entry?) = $0 { entry.kind == .toolResult } else { false } })

        var streamed = ""
        for event in events {
            guard case .messageUpdate(let changes, _) = event else { continue }
            for change in changes {
                if case .textDelta(_, let delta) = change { streamed += delta }
            }
        }
        let final = events.compactMap { event -> AssistantMessage? in
            if case .messageEnd(let entry) = event { return entry.assistantMessage }
            return nil
        }.last
        #expect(final?.text == "It is sunny in Paris today.")
        #expect(streamed.isEmpty || "It is sunny in Paris today.".hasPrefix(streamed) || streamed.hasSuffix("today."))
    }

    /// `views()` receives only appended entries after the first view; a reset replaces the transcript, and every view
    /// must still match a fresh read.
    @Test func viewsStayCompleteAcrossAppendsAndResets() async throws {
        let setup = try await FauxSetup.make()
        let root = try await setup.root()
        var views = root.views().makeAsyncIterator()
        _ = try await views.next()
        func expectMatches() async throws {
            let expected = try await root.view().entries.map(\.id)
            let deadline = ContinuousClock.now + .seconds(5)
            while ContinuousClock.now < deadline {
                let view = try #require(try await views.next())
                if view.entries.map(\.id) == expected { return }
            }
            Issue.record("views() never matched view(): expected \(expected)")
        }
        for index in 0..<3 {
            try await root.write(EntryDraft(kind: "app.note", data: .number(Double(index))))
            try await expectMatches()
        }
        try await root.reset()
        try await expectMatches()
        try await root.write(EntryDraft(kind: "app.note", data: "after reset"))
        try await expectMatches()
    }

    @Test func viewsFollowCommits() async throws {
        let setup = try await FauxSetup.make(tokensPerSecond: 40)
        try await setup.faux.append(.text("A streamed answer with a handful of words in it, long enough to commit partials."))
        let root = try await setup.root()

        let collector = Task { try await withTimeout {
            var sawBusy = false
            var sawPartial = false
            for try await view in root.views() {
                if view.isBusy { sawBusy = true }
                if view.streamingMessage != nil { sawPartial = true }
                if sawBusy, !view.isBusy, view.entries.contains(where: { $0.kind == .assistant }) {
                    return (sawBusy, sawPartial, view)
                }
            }
            throw CancellationError()
        } }
        try await Task.sleep(for: .milliseconds(100))
        try await root.submit("Go")
        let (sawBusy, sawPartial, view) = try await collector.value
        #expect(sawBusy)
        #expect(sawPartial)
        #expect(view.messages.map(\.role) == ["user", "assistant"])
        #expect(view.usage.totalTokens > 0)
    }

    @Test func stoppingAStreamReleasesIt() async throws {
        let setup = try await FauxSetup.make()
        let root = try await setup.root()
        for _ in 0..<3 {
            var iterator = root.views().makeAsyncIterator()
            let first = try await iterator.next()
            #expect(first?.conversation.id == root.id)
        }
        try await setup.harness.close()
    }
}

@Suite struct InboxTests {
    @Test func followUpsQueueWhileBusy() async throws {
        let setup = try await FauxSetup.make(tokensPerSecond: 100)
        try await setup.faux.append(.text("First answer is a little long so the run stays busy."))
        try await setup.faux.append(.text("Second answer."))
        let root = try await setup.root()

        let first = try await root.submit("one")
        let second = try await root.submit("two")
        let secondRecord = try await second.status()
        #expect(secondRecord.status == .queued)

        _ = try await answer(of: first)
        #expect(try await answer(of: second).text == "Second answer.")
    }

    @Test func steerJoinsTheRunAfterTheToolRound() async throws {
        // The tool runs until the test lets it finish, so the steer arrives during the tool round.
        let (release, releaser) = AsyncStream<Void>.makeStream()
        let gate = Tool("gate", description: "Waits") { _ in
            for await _ in release { break }
            return "opened"
        }
        let setup = try await FauxSetup.make(extensions: [Extension("gate", tools: [gate])])
        let requests = Requests()
        try await setup.faux.respond { messages, count in
            await requests.append(messages)
            return count == 1 ? FauxResponse(.toolCall("gate", [:])) : FauxResponse(.text("Lisbon it is."))
        }
        let root = try await setup.root()

        let first = try await root.submit("Plan a weekend in Porto")
        try await withTimeout {
            for try await view in root.views() where view.live.tools.contains(where: { $0.status == .running }) {
                break
            }
        }
        let steer = try await root.submit("Actually, Lisbon", whenBusy: .steer)
        #expect(try await steer.status().status == .queued)
        releaser.yield()

        #expect(try await answer(of: steer).text == "Lisbon it is.")
        _ = try await first.wait()
        // One run answered both: the model's second request has the steer after the tool result.
        let all = await requests.all
        #expect(all.count == 2)
        let last = try #require(all.last)
        guard case .user(let user)? = last.last, case .toolResult? = last.dropLast().last else {
            Issue.record("Expected the tool result and then the steer, got \(last)")
            return
        }
        #expect(user.text == "Actually, Lisbon")
    }

    @Test func steerDuringATextReplyGetsItsOwnAnswer() async throws {
        let setup = try await FauxSetup.make(tokensPerSecond: 100)
        try await setup.faux.append(.text("First answer is a little long so the run stays busy."))
        try await setup.faux.append(.text("Steered answer."))
        let root = try await setup.root()

        let first = try await root.submit("one")
        let steer = try await root.submit("two", whenBusy: .steer)
        #expect(try await answer(of: first).text == "First answer is a little long so the run stays busy.")
        #expect(try await answer(of: steer).text == "Steered answer.")
    }

    private actor Requests {
        var all: [[Message]] = []
        func append(_ messages: [Message]) { all.append(messages) }
    }

    @Test func rejectWhenBusy() async throws {
        let setup = try await FauxSetup.make(tokensPerSecond: 50)
        try await setup.faux.append(.text("A slow answer that keeps the conversation busy for a while."))
        let root = try await setup.root()
        let first = try await root.submit("one")
        let error = await #expect(throws: PiDurableError.self) {
            try await root.submit("two", whenBusy: .reject)
        }
        guard case .conversationBusy = error else {
            Issue.record("Expected conversationBusy, got \(String(describing: error))")
            return
        }
        try await root.abort()
        let record = try await first.wait()
        guard case .unanswered(_, let reason, _) = record.status else {
            Issue.record("Expected unanswered, got \(record.status)")
            return
        }
        #expect(reason == "aborted")
    }

    @Test func queuedSubmissionsCanBeWithdrawn() async throws {
        let setup = try await FauxSetup.make(tokensPerSecond: 50)
        try await setup.faux.append(.text("A slow answer that keeps the conversation busy for a while."))
        let root = try await setup.root()
        try await root.submit("one")
        let queued = try await root.submit("two")
        #expect(try await root.view().inbox.map(\.id) == [queued.id])
        #expect(try await queued.abort() == .aborted)
        #expect(try await root.view().inbox.isEmpty)
        try await root.abort()
    }
}

struct Todos: Codable, Sendable, Equatable {
    var items: [String] = []
}

let todosDocument = Document("app.todos", initial: Todos())

@Suite struct DocumentTests {
    @Test func documentsReadUpdateAndWatch() async throws {
        let setup = try await FauxSetup.make()
        let root = try await setup.root()
        #expect(try await root.document(todosDocument) == Todos())

        let watcher = Task { try await withTimeout {
            var seen: [Todos] = []
            for try await value in root.values(of: todosDocument) {
                seen.append(value)
                if value.items.count == 2 { break }
            }
            return seen
        } }
        try await Task.sleep(for: .milliseconds(50))

        try await root.update(todosDocument) { $0.items.append("Write docs") }
        let updated = try await root.update(todosDocument) { $0.items.append("Ship it") }
        #expect(updated.items == ["Write docs", "Ship it"])
        #expect(try await root.document(todosDocument).items == ["Write docs", "Ship it"])
        let seen = try await watcher.value
        #expect(seen.last?.items == ["Write docs", "Ship it"])
    }

    @Test func toolsCanThrowFromDocumentUpdates() async throws {
        struct Nope: Error {}
        let setup = try await FauxSetup.make()
        let root = try await setup.root()
        await #expect(throws: (any Error).self) {
            try await root.update(todosDocument) { _ in throw Nope() }
        }
        #expect(try await root.document(todosDocument) == Todos())
    }
}

@Suite struct PersistenceTests {
    @Test func sqliteSurvivesReopen() async throws {
        let directory = temporaryDirectory()
        let url = directory.appending(path: "agent.sqlite")

        do {
            let setup = try await FauxSetup.make(.sqlite(at: url))
            try await setup.faux.append(.text("Remembered"))
            let root = try await setup.root()
            _ = try await ask(root, "Remember this")
            try await root.update(todosDocument) { $0.items = ["persisted"] }
            try await setup.harness.close()
        }

        let setup = try await FauxSetup.make(.sqlite(at: url))
        let root = try await setup.root()
        let view = try await root.view()
        #expect(view.messages.map(\.text) == ["Remember this", "Remembered"])
        #expect(try await root.document(todosDocument).items == ["persisted"])
        try await setup.faux.append(.text("Still here"))
        #expect(try await ask(root, "Again").text == "Still here")
        try await setup.harness.close()
    }

    @Test func aStorageOpensInOneHarnessAtATime() async throws {
        let directory = temporaryDirectory()
        for storage in [Storage.sqlite(at: directory.appending(path: "agent.sqlite")), .jsonl(at: directory.appending(path: "log"))] {
            let first = try await FauxSetup.make(storage)
            await #expect(throws: PiDurableError.self) { try await FauxSetup.make(storage) }
            try await first.harness.close()
            // Closing releases the lock, and a failed open took none.
            let second = try await FauxSetup.make(storage)
            try await second.harness.close()
        }
    }

    @Test func releasingAStorageLockTwiceIsHarmless() throws {
        let path = temporaryDirectory().appending(path: "agent.sqlite").path(percentEncoded: false)
        let lock = try StorageLock(storagePath: path)
        lock.release()
        // The descriptor number is free for reuse now; a second release must not close whoever has it.
        let reused = Darwin.open("/dev/null", O_RDONLY)
        lock.release()
        #expect(fcntl(reused, F_GETFD) != -1)
        Darwin.close(reused)
        #expect(throws: Never.self) { try StorageLock(storagePath: path).release() }
    }

    @Test func unfinishedRunsResumeAfterReopen() async throws {
        let directory = temporaryDirectory()
        let url = directory.appending(path: "agent.sqlite")
        let submissionID: SubmissionID

        do {
            // A slow tool keeps the run unfinished when the harness closes.
            let slow = Tool("slow", description: "Slow", replay: .safe) { _ in
                try await Task.sleep(for: .seconds(30))
                return "slow done"
            }
            let setup = try await FauxSetup.make(.sqlite(at: url), extensions: [Extension("slow", tools: [slow])])
            try await setup.faux.append(.toolCall("slow", [:]))
            let root = try await setup.root()
            let submission = try await root.submit("Run the slow tool")
            submissionID = submission.id
            // Wait until the tool is running, then close underneath it.
            try await withTimeout {
                for try await view in root.views() where view.live.tools.contains(where: { $0.status == .running }) {
                    break
                }
            }
            try await setup.harness.close()
        }

        // Reopen with a fast implementation of the same replay-safe tool.
        let fast = Tool("slow", description: "Slow", replay: .safe) { _ in "fast done" }
        let setup = try await FauxSetup.make(.sqlite(at: url), extensions: [Extension("slow", tools: [fast])])
        try await setup.faux.append(.text("Finished after restart"))
        let answer = try await answer(of: setup.harness.submission(submissionID))
        #expect(answer.text == "Finished after restart")
        let root = try await setup.root()
        let result = try #require(try await root.view().entries.first { $0.kind == .toolResult }?.toolResult)
        #expect(result.text == "fast done")
        try await setup.harness.close()
    }
}
