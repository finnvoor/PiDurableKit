import CoreGraphics
import Foundation
import ImageIO
import Testing
import os
import UniformTypeIdentifiers
@testable import PiDurableKit

/// Polls `condition` until it holds.
func eventually(_ seconds: Double = 5, _ condition: @escaping @Sendable () async throws -> Bool) async throws {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    Issue.record("Condition did not hold within \(seconds) seconds")
}

private struct Word: Codable, Sendable { var word: String }
private struct Forecast: Codable, Sendable, Equatable {
    var city: String
    var celsius: Int
}

/// Nested calls, structured output, who may call a tool, deferred tools, and code mode.
@Suite struct ToolProgramTests {
    private let forecast = Tool(
        "forecast", description: "The forecast for a city", parameters: .object(["city": .string("City")])
    ) { (args: [String: String], _) in
        try ToolResult.structured(Forecast(city: args["city"] ?? "", celsius: 21))
    }.returningStructuredOutput(.object(["city": .string(), "celsius": .integer()]))

    @Test func structuredOutputReachesPrograms() async throws {
        let received = Mutex<Forecast?>(nil)
        let caller = Tool("plan", description: "Plan a trip") { (call: ToolCallContext) in
            let result = try await call.executeTool("forecast", arguments: ["city": "Oslo"])
            received.set(try result.decode(as: Forecast.self))
            return "planned"
        }
        let setup = try await FauxSetup.make(extensions: [Extension("trip", tools: [forecast, caller])])
        try await setup.faux.append(.toolCall("plan", [:]))
        try await setup.faux.append(.text("done"))
        let root = try await setup.root()
        _ = try await withTimeout { try await ask(root, "Plan") }
        #expect(received.get() == Forecast(city: "Oslo", celsius: 21))
        let registry = try await setup.harness.registry()
        #expect(registry.extension("trip")?.tools.first { $0.name == "forecast" }?.structuredOutputSchema?["type"] == "object")
    }

    @Test func callersAndModelTools() async throws {
        let internalOnly = Tool("lookup", description: "Internal lookup") { (_: ToolCallContext) in "found" }
            .callable(by: [.tools])
        let modelOnly = Tool("chat", description: "Model only") { (_: ToolCallContext) in "hi" }.callable(by: [.model])
        let hidden = Tool("rare", description: "A rarely needed tool") { (_: ToolCallContext) in "rare" }.deferringUntilLoaded()
        let setup = try await FauxSetup.make(extensions: [Extension("mixed", tools: [internalOnly, modelOnly, hidden])])
        let root = try await setup.root()
        var agent = try await root.agent()
        #expect(agent.tools == ["chat"])
        #expect(agent.callable == ["lookup", "rare"])
        #expect(agent.deferred == ["rare"])

        try await root.configure(AgentChange(modelTools: .edit(add: ["rare"])))
        agent = try await root.agent()
        #expect(agent.tools == ["chat", "rare"])
        #expect(agent.deferred.isEmpty)
        #expect(try await root.agentState().modelTools == .edit(remove: [], add: ["rare"]))

        try await root.configure(AgentChange(modelTools: .only(["rare"])))
        #expect(try await root.agent().tools == ["rare"])
        try await root.configure(AgentChange(reset: [.modelTools]))
        #expect(try await root.agent().tools == ["chat"])
    }

    @Test func wrapsChangeWhoCallsATool() async throws {
        let plain = Tool("plain", description: "Plain") { (_: ToolCallContext) in "plain" }
        let wrap = Extension("wrap") {
            Wrap.tool("plain", definition: { definition in
                definition.callers = [.tools]
                definition.structuredOutputSchema = ["type": "string"]
            })
        }
        let setup = try await FauxSetup.make(extensions: [Extension("plain", tools: [plain]), wrap])
        let root = try await setup.root()
        let agent = try await root.agent()
        #expect(agent.tools.isEmpty)
        #expect(agent.callable == ["plain"])
    }

    @Test func toolSearchLoadsDeferredTools() async throws {
        let hidden = Tool("convert_currency", description: "Convert an amount between currencies") { (_: ToolCallContext) in "1.1" }
            .deferringUntilLoaded()
        let setup = try await FauxSetup.make(extensions: [Extension("money", tools: [hidden]), .toolSearch()])
        try await setup.faux.append(.toolCall("tool_search", ["query": "currency"]))
        try await setup.faux.append(.text("loaded"))
        let root = try await setup.root()
        #expect(try await root.agent().tools == ["tool_search"])
        _ = try await withTimeout { try await ask(root, "Find a currency tool") }
        #expect(try await root.agent().tools.contains("convert_currency"))
    }

    @Test func nestedCallsShowInLiveStateEventsAndHooks() async throws {
        let gate = Gate()
        let parents = Mutex<[ToolCall.Parent?]>([])
        let slow = Tool("slow", description: "Slow") { (_: ToolCallContext) -> String in
            await gate.wait()
            return "slow done"
        }
        let caller = Tool("caller", description: "Calls slow") { (call: ToolCallContext) in
            try await call.executeTool("slow", key: "first").text
        }
        let watcher = Extension("watcher") {
            Hook.beforeTool { call, _ in
                parents.update { $0.append(call.parent) }
                return .allow
            }
        }
        let setup = try await FauxSetup.make(extensions: [Extension("tools", tools: [slow, caller]), watcher])
        try await setup.faux.append(.toolCall("caller", [:]))
        try await setup.faux.append(.text("done"))
        let root = try await setup.root()
        let events = try await setup.harness.watchEvents(root.id)
        let collected = Mutex<[AgentEvent]>([])
        let collector = Task {
            for try await batch in events { collected.update { $0 += batch } }
        }
        let submission = try await root.submit("Go")
        try await eventually { try await !root.liveState().nestedTools.isEmpty }
        let nested = try #require(try await root.liveState().nestedTools.first)
        #expect(nested.name == "slow")
        #expect(nested.callId.hasSuffix("/first"))
        gate.release()
        _ = try await withTimeout { try await answer(of: submission) }
        #expect(try await root.view().entries.compactMap(\.toolResult).first?.text == "slow done")
        try await eventually {
            collected.get().contains { if case .toolExecutionEnd(let call, _, let result?) = $0 { call.isNested && result.text == "slow done" } else { false } }
        }
        collector.cancel()
        let starts = collected.get().compactMap { if case .toolExecutionStart(let call, _) = $0 { call } else { nil } }
        #expect(starts.first { $0.toolName == "slow" }?.parentCallId == starts.first { $0.toolName == "caller" }?.callId)
        #expect(parents.get().count == 2)
        #expect(parents.get().compactMap { $0 }.count == 1)
    }

    @Test func retainedOutputOfACall() async throws {
        let seen = Mutex<(String, Bool)>(("", true))
        let talker = Tool("talker", description: "Talks") { (call: ToolCallContext) in
            call.output("hello ")
            call.output("world")
            try await Task.sleep(for: .milliseconds(50))
            seen.set(try await call.retainedOutput())
            return ToolResult.streamedOutput
        }
        let setup = try await FauxSetup.make(extensions: [Extension("talker", tools: [talker])])
        try await setup.faux.append(.toolCall("talker", [:]))
        try await setup.faux.append(.text("done"))
        let root = try await setup.root()
        _ = try await withTimeout { try await ask(root, "Talk") }
        #expect(seen.get().0 == "hello world")
        #expect(seen.get().1 == false)
    }

    @Test func codemodeScriptsCallTools() async throws {
        let echo = Tool("echo", description: "Echo a word", parameters: .object(["word": .string("The word")])) { (args: Word, _) in
            "echo \(args.word)"
        }
        let setup = try await FauxSetup.make(extensions: [Extension("echo", tools: [echo]), .codemode(CodemodeOptions(models: false))])
        let script = """
            const results = await Promise.all(["a", "b"].map((word) => tools.echo({ word })));
            return results.join(" | ");
            """
        try await setup.faux.append(.toolCall("codemode", ["code": .string(script)]))
        try await setup.faux.append(.text("done"))
        let root = try await setup.root()
        #expect(try await root.agent().sections.map(\.key).contains("codemode"))
        _ = try await withTimeout(30) { try await ask(root, "Script") }
        let result = try #require(try await root.view().entries.compactMap(\.toolResult).first)
        #expect(result.isError == false, "\(result.text)")
        #expect(result.text.contains("echo a | echo b"))
        #expect(result.details?["calls"]?.arrayValue?.count == 2)
    }
}

/// Code mode's VMs run in workers, each on a thread of its own.
@Suite struct CodemodeWorkerTests {
    @Test func aComputingScriptLeavesTheRuntimeFree() async throws {
        // A runtime of its own: the shared one is busy with the tests running alongside.
        let runtime = Runtime()
        let setup = try await FauxSetup.make(extensions: [.codemode(CodemodeOptions(models: false))], runtime: runtime)
        try await setup.faux.append(.toolCall("codemode", ["code": .string("let s = 0; for (let i = 0; i < 3e6; i++) s += i % 7; return s")]))
        try await setup.faux.append(.text("done"))
        let root = try await setup.root()
        let started = ContinuousClock.now
        let submission = try await root.submit("Compute")
        try await Task.sleep(for: .milliseconds(300))
        // The runtime answers while the script computes, rather than once it has finished.
        let answered = try await ContinuousClock().measure { _ = try await runtime.bundledVersions() }
        _ = try await withTimeout(60) { try await submission.wait() }
        let computed = ContinuousClock.now - started
        #expect(answered < computed / 4, "The runtime waited \(answered) for a script that took \(computed)")
        let result = try #require(try await root.view().entries.compactMap(\.toolResult).first)
        #expect(result.isError == false, "\(result.text)")
        #expect(result.text.contains("8999994"))
    }

    @Test func scriptsRunConcurrently() async throws {
        let echo = Tool("echo", description: "Echo a word", parameters: .object(["word": .string("The word")])) { (args: Word, _) in
            "echo \(args.word)"
        }
        let setup = try await FauxSetup.make(extensions: [Extension("echo", tools: [echo]), .codemode(CodemodeOptions(models: false))])
        var conversations: [Conversation] = []
        for _ in 0..<4 {
            conversations.append(try await setup.harness.createConversation(agent: AgentChange(model: setup.faux.model)))
        }
        for _ in conversations {
            try await setup.faux.append(.toolCall("codemode", ["code": .string(#"return (await Promise.all(["x", "y"].map((word) => tools.echo({ word })))).join(",")"#)]))
        }
        for _ in conversations { try await setup.faux.append(.text("done")) }
        let submissions = try await withThrowingTaskGroup(of: Submission.self) { group in
            for conversation in conversations { group.addTask { try await conversation.submit("Script") } }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        for submission in submissions { _ = try await withTimeout(30) { try await submission.wait() } }
        for conversation in conversations {
            let result = try #require(try await conversation.view().entries.compactMap(\.toolResult).first)
            #expect(result.text.contains("echo x,echo y"), "\(result.text)")
        }
    }

    @Test func memoryLimit() async throws {
        let setup = try await FauxSetup.make(extensions: [.codemode(CodemodeOptions(models: false, memoryLimitBytes: 16 << 20))])
        try await setup.faux.append(.toolCall("codemode", ["code": .string("const parts = []; for (let i = 0; i < 64; i++) parts.push(new Uint8Array(1 << 20)); return parts.length")]))
        try await setup.faux.append(.text("done"))
        let root = try await setup.root()
        _ = try await withTimeout(30) { try await ask(root, "Allocate") }
        let result = try #require(try await root.view().entries.compactMap(\.toolResult).first)
        #expect(result.isError)
        #expect(result.text.contains("out of memory"), "\(result.text)")
    }

    @Test func aScriptResumesAfterARestart() async throws {
        let runs = OSAllocatedUnfairLock<[String]>(initialState: [])
        let echo = Tool("echo", description: "Echo a word", parameters: .object(["word": .string("The word")])) { (args: Word, _) in
            runs.withLock { $0.append(args.word) }
            return "echo \(args.word)"
        }
        let slow = Tool("slow", description: "Takes a second", replay: .safe) { _ -> String in
            runs.withLock { $0.append("slow") }
            try await Task.sleep(for: .seconds(1))
            return "slow done"
        }
        let url = temporaryDirectory().appending(path: "codemode.sqlite")
        let models = Models(builtinProviders: false)
        let faux = FauxProvider()
        try await models.register(faux)
        let extensions = [Extension("tools", tools: [echo, slow]), .codemode(CodemodeOptions(models: false))]
        var harness = try await Harness.open(.sqlite(at: url), models: models, extensions: extensions)
        let script = #"const a = await tools.echo({ word: "before" }); const b = await tools.slow({}); return [a, b, await tools.echo({ word: "after" })].join(" / ")"#
        try await faux.append(.toolCall("codemode", ["code": .string(script)]))
        try await faux.append(.text("done"))
        let root = try await harness.root(agent: AgentChange(model: faux.model))
        _ = try await root.submit("Script")
        // Closed while `slow` runs.
        try await eventually(30) { runs.withLock { $0.contains("slow") } }
        try await harness.close()

        harness = try await Harness.open(.sqlite(at: url), models: models, extensions: extensions)
        let reopened = try await harness.root()
        try await withTimeout(30) { try await reopened.waitForIdle() }
        let result = try #require(try await reopened.view().entries.compactMap(\.toolResult).last)
        #expect(result.isError == false, "\(result.text)")
        #expect(result.text.contains("echo before / slow done / echo after"))
        // The finished call wasn't made again; the interrupted one, safe to replay, was.
        #expect(runs.withLock { $0 } == ["before", "slow", "slow", "after"])
        try await harness.close()
    }
}

/// Input entries, display-only writes, abandoned tasks, owned tasks, and compaction failures.
@Suite struct RunBehaviorTests {
    @Test func inputsPlacedAsApplicationEntries() async throws {
        struct Author: Codable, Sendable { var name: String }
        let chat = EntryType<Author>("app.chat")
        let setup = try await FauxSetup.make()
        try await setup.faux.append(.text("Hello Ada"))
        let root = try await setup.root()
        let answerMessage = try await answer(of: try await root.submit("Hi!", entry: try InputEntry(chat, Author(name: "Ada"))))
        #expect(answerMessage.text == "Hello Ada")
        let entry = try #require(try await root.view().entries.first { $0.is(chat) })
        #expect(entry.data(as: chat)?.name == "Ada")
        #expect(entry.userMessage?.text == "Hi!")
    }

    @Test func displayOnlyWritesAppendWhileBusy() async throws {
        let gate = Gate()
        let wait = Tool("wait", description: "Wait") { (_: ToolCallContext) -> String in
            await gate.wait()
            return "waited"
        }
        let setup = try await FauxSetup.make(extensions: [Extension("wait", tools: [wait])])
        try await setup.faux.append(.toolCall("wait", [:]))
        try await setup.faux.append(.text("done"))
        let root = try await setup.root()
        let submission = try await root.submit("Go")
        try await eventually {
            let busy = try await root.view().isBusy
            let tools = try await root.liveState().tools
            return busy && !tools.isEmpty
        }
        let written = try await withTimeout { try await root.write(EntryDraft(kind: "app.note", data: "while busy")).wait() }
        #expect(written.isSettled)
        gate.release()
        _ = try await withTimeout { try await answer(of: submission) }
    }

    @Test func tasksAbandonedOnRestart() async throws {
        let url = temporaryDirectory().appending(path: "abandon.sqlite")
        let id: TaskID
        do {
            let models = Models(builtinProviders: false)
            let harness = try await Harness.open(
                .sqlite(at: url), models: models, extensions: [Extension("tasks", tasks: [doubler.any])], resume: false)
            let root = try await harness.root()
            id = try await root.commit { tx in try await tx.createTask(doubler, input: 2, abandonOnRestart: true) }
            #expect(try await harness.task(id)?.abandonOnRestart == true)
            try await harness.close()
        }
        let models = Models(builtinProviders: false)
        let harness = try await Harness.open(.sqlite(at: url), models: models, extensions: [Extension("tasks", tasks: [doubler.any])])
        let record = try await withTimeout { try await harness.waitForTask(id) }
        guard case .aborted? = record.outcome else {
            Issue.record("Expected an aborted task, got \(String(describing: record.outcome))")
            return
        }
        try await harness.close()
    }

    @Test func tasksSeeAndAbortTheirOwnedTasks() async throws {
        let sleeper = TaskType<Empty, At, String>("test.sleeper", version: 1, initial: { _ in At(phase: "sleep") }, abort: abortTask) {
            Phase("sleep") { run in
                try await run.sleep(until: Date().addingTimeInterval(3600), then: At(phase: "woke"))
            }
            Phase("woke") { run in
                try await run.commit { _, _ in .completed("woke") }
            }
        }
        let seen = Mutex<Int>(-1)
        let parent = TaskType<Empty, At, Int>("test.parent", version: 1, initial: { _ in At(phase: "spawn") }, abort: abortTask) {
            Phase("spawn") { run in
                try await run.commit { tx, current in
                    _ = try await tx.createTask(sleeper, input: Empty(), ownedBy: current.id)
                    return .running(At(phase: "check"))
                }
            }
            Phase("check") { run in
                let owned = try await run.ownedTasks()
                seen.set(owned.count)
                for task in owned { try await run.abortOwned(task.id) }
                let remaining = try await run.ownedTasks().count
                try await run.commit { _, _ in .completed(remaining) }
            }
        }
        let setup = try await FauxSetup.make(extensions: [Extension("tasks", tasks: [sleeper.any, parent.any])])
        let root = try await setup.root()
        let id = try await root.commit { tx in try await tx.createTask(parent, input: Empty()) }
        let record = try await withTimeout { try await setup.harness.waitForTask(id) }
        #expect(seen.get() == 1)
        #expect(try record.outcome(as: Int.self)?.result == 0)
    }

    @Test func compactionFailuresStayVisible() async throws {
        let setup = try await FauxSetup.make(
            settings: Settings(retry: .init(enabled: false), compaction: .init(keepRecentTokens: 1)))
        let calls = Mutex(0)
        try await setup.faux.respond { _, _ in
            calls.update { $0 += 1 }
            return calls.get() <= 3 ? .text("A long enough answer to compact later on, with some padding.") : .error("summarizer down")
        }
        let root = try await setup.root()
        for index in 1...3 { _ = try await ask(root, "Message \(index) with padding text") }
        let task = try await root.compact()
        _ = try await withTimeout { try await setup.harness.waitForTask(task) }
        let failure = try #require(try await root.liveState().compactionFailure)
        #expect(failure.taskId == task)
        #expect(failure.reason == .manual)
    }
}

/// Session endings, storage errors, settings, and file listings.
@Suite struct SessionEndingTests {
    @Test func closedReportsWhy() async throws {
        let session = try await Session.open()
        let ended = Task { try await session.closed() }
        try await session.close()
        #expect(try await withTimeout { try await ended.value } == .closed)
        #expect(try await session.closed() == .closed)
    }

    @Test func aStorageErrorFailsTheSession() async throws {
        let storage = FailingStorage(failCommits: true)
        let session = try await Session.open(.custom(storage))
        let notes = Document("test.failNotes", scope: .session, initial: FileNote())
        await #expect(throws: (any Error).self) { try await session.update(notes) { $0.text = "x" } }
        let end = try await withTimeout { try await session.closed() }
        guard case .failed(let message) = end else {
            Issue.record("Expected a failed session")
            return
        }
        #expect(message.contains("disk full"))
        do {
            _ = try await session.document(notes)
            Issue.record("Expected the failed session to reject")
        } catch PiDurableError.sessionFailed {
        } catch {
            Issue.record("Expected sessionFailed, got \(error)")
        }
    }

    @Test func aStorageRequestErrorFailsOnlyTheCall() async throws {
        let storage = FailingStorage(failCommits: false)
        let session = try await Session.open(.custom(storage))
        do {
            _ = try await session.commit { tx in try await tx.conversation(ConversationID(42)) }
            Issue.record("Expected the read to fail")
        } catch PiDurableError.storageRequestError(let message) {
            #expect(message.contains("unknown conversation"))
        }
        let notes = Document("test.requestNotes", scope: .session, initial: FileNote())
        #expect(try await session.document(notes) == FileNote())
        try await session.close()
        #expect(try await session.closed() == .closed)
    }

    @Test func documentRetentionSetting() async throws {
        let setup = try await FauxSetup.make(settings: Settings(documentRetention: .seconds(5)))
        #expect(try await setup.harness.resolvedSettings().documentRetention == .seconds(5))
        try await setup.harness.updateSettings(Settings(documentRetention: .forever))
        #expect(try await setup.harness.resolvedSettings().documentRetention == .forever)
        #expect(try await Runtime.shared.defaultSettings().documentRetention == .milliseconds(600_000))
        let session = try await Session.open(documentRetention: .zero)
        let notes = Document("test.retainedNotes", scope: .session, initial: FileNote())
        try await session.update(notes) { $0.text = "kept in storage" }
        #expect(try await session.document(notes).text == "kept in storage")
        try await session.close()
    }

    @Test func listFilesHonorsGitignore() async throws {
        let directory = temporaryDirectory()
        let models = Models(builtinProviders: false)
        let harness = try await Harness.open(models: models, environment: .directory(directory))
        let root = try await harness.root()
        let env = try #require(try await harness.environment(for: root.id))
        for path in ["src/main.swift", "build/out.o", "notes.md", ".hidden", "node_modules/x/y.js"] {
            try await env.write("", to: "/" + path)
        }
        try await env.write("build/\n", to: "/.gitignore")
        try await env.write("ref: refs/heads/main\n", to: "/.git/HEAD")
        let listing = try await env.listFiles("/", options: ListFilesOptions(hidden: false, exclude: ["node_modules"]))
        #expect(listing.entries.map(\.path) == ["notes.md", "src", "src/main.swift"])
        #expect(listing.truncated == false)
        let limited = try await env.listFiles("/", options: ListFilesOptions(gitignore: false, maxEntries: 2))
        #expect(limited.entries.count == 2)
        #expect(limited.truncated)
        try await harness.close()
    }

    @Test func readReturnsPreparedImages() async throws {
        let directory = temporaryDirectory()
        try Self.png(width: 3000, height: 1000).write(to: directory.appending(path: "wide.png"))
        let models = Models(builtinProviders: false)
        let faux = FauxProvider()
        try await models.register(faux)
        let harness = try await Harness.open(
            models: models, extensions: [.codingTools(images: .native)], environment: .directory(directory))
        try await faux.append(.toolCall("read", ["path": "/wide.png"]))
        try await faux.append(.text("seen"))
        let root = try await harness.root(agent: AgentChange(model: faux.model))
        _ = try await withTimeout { try await ask(root, "Look") }
        let result = try #require(try await root.view().entries.compactMap(\.toolResult).first)
        #expect(result.isError == false, "\(result.text)")
        guard case .image(let image)? = result.content.first(where: { if case .image = $0 { true } else { false } }) else {
            Issue.record("Expected an image block, got \(result.content)")
            try await harness.close()
            return
        }
        let bytes = try #require(image.bytes)
        let source = try #require(CGImageSourceCreateWithData(bytes as CFData, nil))
        let width = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])?[kCGImagePropertyPixelWidth] as? Int
        #expect(width == 2000)
        try await harness.close()
    }

    @Test func nativeImageProcessorPassesSmallImagesThrough() async throws {
        let small = try Self.png(width: 10, height: 10)
        let prepared = try #require(try await NativeImageProcessor().prepare(small, mimeType: "image/png", limits: ImageLimits()))
        #expect(prepared.resized == nil)
        #expect(Data(base64Encoded: prepared.data) == small)
        let tight = try #require(
            try await NativeImageProcessor().prepare(
                try Self.png(width: 400, height: 400), mimeType: "image/bmp", limits: ImageLimits(maxWidth: 100, maxHeight: 50)))
        #expect(tight.resized?.to == PreparedImage.Size(width: 50, height: 50))
        #expect(tight.convertedFrom == "image/bmp")
    }

    static func png(width: Int, height: Int, red: Bool = false) throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red ? CGColor(red: 1, green: 0, blue: 0, alpha: 1) : CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    #if os(macOS)
    @Test func bashAnswersANonzeroExitWithAnErrorResult() async throws {
        let directory = temporaryDirectory()
        let models = Models(builtinProviders: false)
        let faux = FauxProvider()
        try await models.register(faux)
        let harness = try await Harness.open(
            models: models, extensions: [.codingTools(shell: true)], environment: .directory(directory, shell: true))
        try await faux.append(.toolCall("bash", ["command": "echo failing; exit 4"]))
        try await faux.append(.text("done"))
        let root = try await harness.root(agent: AgentChange(model: faux.model))
        _ = try await withTimeout { try await ask(root, "Run") }
        let result = try #require(try await root.view().entries.compactMap(\.toolResult).first)
        #expect(result.isError)
        #expect(result.text.contains("failing"))
        let diagnostics = try #require(try await root.view().entries.first { $0.is(.toolResult) }?.data(as: .toolResult))
        #expect(diagnostics.diagnostics.contains { $0.code == "exit_code" })
        try await harness.close()
    }
    #endif
}

/// A ``CustomStorage`` that fails: every commit with a fatal error, or reads of unknown conversations with a request
/// error. Otherwise it holds nothing.
actor FailingStorage: CustomStorage {
    let failCommits: Bool
    private var nextID = 1

    init(failCommits: Bool) {
        self.failCommits = failCommits
    }

    private let empty: JSONValue = ["items": []]

    func commit(_ writes: [JSONValue]) async throws -> Int {
        if failCommits { throw PiDurableError.runtime("disk full") }
        return 1
    }
    func mintId() async throws -> Int {
        defer { nextID += 1 }
        return nextID
    }
    func conversation(_ id: Int) async throws -> JSONValue? {
        throw PiDurableError.storageRequestError("unknown conversation \(id)")
    }
    func scanConversations(_ query: JSONValue, limit: Int, cursor: JSONValue?) async throws -> JSONValue { empty }
    func entry(_ id: Int, visibleFrom conversationId: Int?) async throws -> JSONValue? { nil }
    func findLatestHeadMarker(in conversationId: Int, atOrBefore entryId: Int?) async throws -> JSONValue? { nil }
    func scanEntries(_ query: JSONValue, limit: Int, cursor: JSONValue?) async throws -> JSONValue { empty }
    func task(_ id: Int) async throws -> JSONValue? { nil }
    func scanTasks(_ query: JSONValue, limit: Int, cursor: JSONValue?) async throws -> JSONValue { empty }
    func submission(_ id: Int) async throws -> JSONValue? { nil }
    func scanSubmissions(_ query: JSONValue, limit: Int, cursor: JSONValue?) async throws -> JSONValue { empty }
    func submission(in conversationId: Int, requestId: String) async throws -> JSONValue? { nil }
    func findDocument(_ address: JSONValue, at point: JSONValue) async throws -> JSONValue? { nil }
    func document(_ id: Int, at point: JSONValue) async throws -> JSONValue? { nil }
    func scanDocuments(_ query: JSONValue, limit: Int, cursor: JSONValue?) async throws -> JSONValue { empty }
    func close() async throws {}
}
