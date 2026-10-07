import Foundation
import SQLite3
import Testing
@testable import PiDurableKit

/// One test per pi-durable API surface added to round out the wrapper.
@Suite struct CoverageTests {
    @Test func rootConversationID() async throws {
        let setup = try await FauxSetup.make()
        #expect(try await setup.root().id == .root)
    }

    @Test func readAfterWriteIsTyped() async throws {
        let setup = try await FauxSetup.make()
        let root = try await setup.root()
        let error = await #expect(throws: PiDurableError.self) {
            try await root.commit { tx in
                try await tx.append(EntryDraft(kind: "app.note"), to: root.id)
                _ = try await tx.entries(in: root.id)
            }
        }
        guard case .readAfterWrite = error else {
            Issue.record("Expected readAfterWrite, got \(String(describing: error))")
            return
        }
    }

    @Test func entryRanges() async throws {
        let setup = try await FauxSetup.make()
        let root = try await setup.root()
        var ids: [EntryID] = []
        for index in 0..<5 {
            let entry = try await root.commit { tx in try await tx.append(EntryDraft(kind: "app.n", data: .number(Double(index))), to: root.id) }
            ids.append(entry.id)
        }
        let page = try await root.entries(from: ids[1], through: ids[3])
        #expect(page.items.map(\.id) == [ids[3], ids[2], ids[1]])
    }

    @Test func scanOrder() async throws {
        let setup = try await FauxSetup.make()
        let root = try await setup.root()
        var ids: [EntryID] = []
        for index in 0..<4 {
            let entry = try await root.commit { tx in try await tx.append(EntryDraft(kind: "app.n", data: .number(Double(index))), to: root.id) }
            ids.append(entry.id)
        }
        let first = try await root.entries(from: ids[0], order: .ascending, limit: 2)
        #expect(first.items.map(\.id) == [ids[0], ids[1]])
        let rest = try await root.entries(from: ids[0], limit: 2, after: try #require(first.next))
        #expect(rest.items.map(\.id) == [ids[2], ids[3]])
        let newest = try await root.commit { tx in try await tx.entries(in: root.id, order: .descending, limit: 1) }
        #expect(newest.items.map(\.id) == [ids[3]])
    }

    @Test func contextAsOfAnEarlierEntry() async throws {
        let setup = try await FauxSetup.make()
        try await setup.faux.append(.text("first answer"))
        try await setup.faux.append(.text("second answer"))
        let root = try await setup.root()
        _ = try await ask(root, "One")
        let firstAnswer = try #require(try await root.view().entries.last)
        _ = try await ask(root, "Two")
        #expect(try await root.context().messages.count == 4)
        let earlier = try await root.context(at: firstAnswer.id)
        #expect(earlier.messages.count == 2)
        #expect(earlier.entries.last?.id == firstAnswer.id)
    }

    @Test func durationsAndTaskTimes() async throws {
        let setup = try await FauxSetup.make(extensions: [Extension("weather", tools: [weatherTool])])
        try await setup.faux.append(.toolCall("get_weather", ["city": "Paris"]))
        try await setup.faux.append(.text("Sunny"))
        let root = try await setup.root()
        _ = try await ask(root, "Weather?")
        let messages = try await root.view().entries.compactMap(\.message)
        let toolResult = try #require(messages.compactMap { if case .toolResult(let m) = $0 { m } else { nil } }.first)
        #expect(toolResult.duration != nil)
        let tasks = try await root.commit { tx in try await tx.tasks(TaskQuery(conversationId: root.id)) }
        let finished = tasks.items.filter { if case .terminal = $0.status { true } else { false } }
        #expect(!finished.isEmpty)
        for task in finished {
            let started = try #require(task.startedAt)
            let ended = try #require(task.endedAt)
            #expect(started <= ended)
        }
    }

    @Test func contextRetentionSetting() throws {
        let json = try JSONValue(encoding: Settings(followUpMode: .all, contextRetention: .seconds(2)))
        #expect(json["contextRetentionMs"] == 2000)
        #expect(json["followUpMode"] == "all")
    }

    @Test func toolResultDiagnostics() async throws {
        let noisy = Tool("noisy", description: "Reports diagnostics") { call -> ToolResult in
            try await call.diagnostic(ToolDiagnostic("recorded while running", severity: .info, code: "running"))
            return ToolResult(content: [.text("done")], diagnostics: [ToolDiagnostic("Output truncated", severity: .warn, code: "truncated")])
        }
        let setup = try await FauxSetup.make(extensions: [Extension("noisy", tools: [noisy])])
        try await setup.faux.append(.toolCall("noisy", [:]))
        try await setup.faux.append(.text("ok"))
        let root = try await setup.root()
        _ = try await ask(root, "Go")
        let entry = try #require(try await root.view().entries.first { $0.kind == .toolResult })
        let diagnostics = try (entry.data?["diagnostics"] ?? []).decode(as: [ToolDiagnostic].self)
        #expect(diagnostics.map(\.code) == ["running", "truncated"])
        #expect(diagnostics.last?.severity == .warn)
    }

    @Test func sectionsSeeTheResolvedAgent() async throws {
        let seen = Mutex<Agent?>(nil)
        let prompt = Extension("prompt") {
            weatherTool
            PromptSection("tools") { input in
                seen.set(input.agent)
                return "Tools: \(input.agent.tools.joined(separator: ", "))"
            }
        }
        let setup = try await FauxSetup.make(extensions: [prompt])
        try await setup.faux.append(.text("ok"))
        let root = try await setup.root(AgentChange(instructions: "Be brief.", cwd: "/work"))
        _ = try await ask(root, "Hi")
        let agent = try #require(seen.get())
        #expect(agent.tools == ["get_weather"])
        #expect(agent.instructions == "Be brief.")
        #expect(agent.cwd == "/work")
        #expect(agent.model == setup.faux.model)
    }

    @Test func toolsWatchAndReadDocumentsAsOf() async throws {
        let mood = Document("test.toolMood", history: .rewindable, initial: FileNote())
        let watcher = Tool("watch", description: "Watches a document") { call -> String in
            let updates = call.values(of: mood)
            var iterator = updates.makeAsyncIterator()
            let first = try await iterator.next()
            try await call.commit { tx in try await tx.setDocument(mood, FileNote(text: "changed"), of: .conversation(call.conversationId)) }
            let second = try await iterator.next()
            return "\(first?.text ?? "nil") -> \(second?.text ?? "nil")"
        }
        let past = Tool("past", description: "Reads a past value", parameters: .object(["entry": .integer])) {
            (arguments: [String: Int], call) -> String in
            try await call.document(mood, asOf: EntryID(arguments["entry"] ?? 0)).text
        }
        let setup = try await FauxSetup.make(extensions: [Extension("docs", tools: [watcher, past])])
        let root = try await setup.root()
        try await root.update(mood) { $0.text = "before" }
        let marker = try await root.commit { tx in try await tx.append(EntryDraft(kind: "app.marker"), to: root.id) }
        try await setup.faux.append(.toolCall("watch", [:]))
        try await setup.faux.append(.toolCall("past", ["entry": .number(Double(marker.id.rawValue))]))
        try await setup.faux.append(.text("ok"))
        _ = try await withTimeout { try await ask(root, "Go") }
        let results = try await root.view().entries.compactMap(\.toolResult).map(\.text)
        #expect(results == ["before -> changed", "before"])
    }

    @Test func familiesStartFromTheirSeed() async throws {
        struct Counter: Codable, Sendable, Equatable { var start: Int; var count: Int }
        let counters = Document(
            "test.seeded", keyed: true, initial: Counter(start: 0, count: 0),
            initialForSeed: { seed in Counter(start: seed.intValue ?? -1, count: seed.intValue ?? -1) })
        let setup = try await FauxSetup.make()
        let root = try await setup.root()
        let created = try await root.update(counters, key: "a", seed: 10) { $0.count += 1 }
        #expect(created == Counter(start: 10, count: 11))
        // An existing member ignores later seeds.
        #expect(try await root.update(counters, key: "a", seed: 99) { $0.count += 1 } == Counter(start: 10, count: 12))
    }

    @Test func checkpointWhenDecidesFullValues() async throws {
        let url = temporaryDirectory().appending(path: "checkpoints.sqlite")
        let always = Document("test.cp.always", history: .rewindable, initial: FileNote(), checkpointWhen: { _, _, _ in true })
        let never = Document("test.cp.never", history: .rewindable, initial: FileNote())
        let setup = try await FauxSetup.make(.sqlite(at: url))
        let root = try await setup.root()
        for index in 0..<3 {
            try await root.update(always) { $0.text = "a\(index)" }
            try await root.update(never) { $0.text = "n\(index)" }
        }
        try await setup.harness.close()

        func bases(_ kind: String) throws -> Int {
            var database: OpaquePointer?
            sqlite3_open(url.path(percentEncoded: false), &database)
            defer { sqlite3_close(database) }
            var statement: OpaquePointer?
            sqlite3_prepare_v2(database, """
                SELECT count(*) FROM document_revisions r JOIN documents d ON d.id = r.document_id
                WHERE r.kind = 'base' AND d.kind LIKE '%\(kind)%'
                """, -1, &statement, nil)
            defer { sqlite3_finalize(statement) }
            sqlite3_step(statement)
            return Int(sqlite3_column_int64(statement, 0))
        }
        // Each update is its own commit; the first one also creates the document.
        let alwaysBases = try bases("test.cp.always")
        let neverBases = try bases("test.cp.never")
        #expect(alwaysBases == 3, "\(alwaysBases)")
        #expect(neverBases == 1, "\(neverBases)")
    }

    @Test func typedTaskHooks() async throws {
        struct Charge: Codable, Sendable { var amount: Int }
        struct Verdict: Codable, Sendable { var block: String }
        let charge = TaskType<Charge, At, String>("test.typedCharge", version: 1, initial: { _ in At(phase: "run") }, abort: abortTask) {
            Phase("run") { run in
                let verdicts = try await run.hooks("beforeCharge", arguments: run.input, as: Verdict.self)
                let block = verdicts.compactMap { $0?.block }.first
                try await run.commit { _, _ in block.map { .failed($0) } ?? .completed("charged \(run.input.amount)") }
            }
        }
        let limits = Extension("limits") {
            Hook.task(charge, "beforeCharge") { (charge: Charge, _) -> Verdict? in
                charge.amount > 100 ? Verdict(block: "Over the limit") : nil
            }
        }
        let setup = try await FauxSetup.make(extensions: [Extension("shop") { charge }, limits])
        let root = try await setup.root()
        let small = try await root.commit { tx in try await tx.createTask(charge, input: Charge(amount: 20)) }
        let large = try await root.commit { tx in try await tx.createTask(charge, input: Charge(amount: 500)) }
        #expect(try await setup.harness.waitForTask(small, as: String.self).result == "charged 20")
        let outcome = try await setup.harness.waitForTask(large, as: String.self)
        guard case .failed(let message, _) = outcome else {
            Issue.record("Expected failure, got \(outcome)")
            return
        }
        #expect(message == "Over the limit")
    }

    @Test func environmentPerConversation() async throws {
        struct Sandbox: Codable, Sendable { var name = "" }
        let sandbox = Document("test.sandbox", initial: Sandbox())
        let base = temporaryDirectory()
        let models = Models(builtinProviders: false)
        let faux = FauxProvider()
        try await models.register(faux)
        let harness = try await Harness.open(
            models: models, extensions: [.codingTools()],
            environment: .perConversation { target in
                let name = try await target.document(sandbox).name
                return name.isEmpty ? nil : .directory(base.appending(path: name))
            })
        let alice = try await harness.createConversation(agent: AgentChange(model: faux.model)) { tx, id in
            try await tx.setDocument(sandbox, Sandbox(name: "alice"), of: .conversation(id))
        }
        let bob = try await harness.createConversation(agent: AgentChange(model: faux.model)) { tx, id in
            try await tx.setDocument(sandbox, Sandbox(name: "bob"), of: .conversation(id))
        }
        try await faux.append(.toolCall("write", ["path": "/hello.txt", "content": "alice"]))
        try await faux.append(.text("ok"))
        _ = try await ask(alice, "Write")
        try await faux.append(.toolCall("write", ["path": "/hello.txt", "content": "bob"]))
        try await faux.append(.text("ok"))
        _ = try await ask(bob, "Write")
        #expect(try String(contentsOf: base.appending(path: "alice/hello.txt"), encoding: .utf8) == "alice")
        #expect(try String(contentsOf: base.appending(path: "bob/hello.txt"), encoding: .utf8) == "bob")

        // A conversation without a sandbox gets no environment, so file tools fail.
        let nobody = try await harness.createConversation(agent: AgentChange(model: faux.model))
        try await faux.append(.toolCall("write", ["path": "/x.txt", "content": "x"]))
        try await faux.append(.text("ok"))
        _ = try await ask(nobody, "Write")
        #expect(try await nobody.view().entries.first { $0.kind == .toolResult }?.toolResult?.isError == true)
        try await harness.close()
    }

    @Test func commitsStream() async throws {
        let setup = try await FauxSetup.make()
        let root = try await setup.root()
        let collector = Task {
            try await withTimeout {
                var publications: [CommitPublication] = []
                for try await publication in setup.harness.commits() {
                    publications.append(publication)
                    if publication.changes.contains(where: { if case .entry(let entry) = $0 { entry.kind == "app.note" } else { false } }) {
                        return publications
                    }
                }
                return publications
            }
        }
        try await Task.sleep(for: .milliseconds(100))
        try await root.update(todosDocument) { $0.items = ["x"] }
        try await root.commit { tx in try await tx.append(EntryDraft(kind: "app.note"), to: root.id) }
        let publications = try await collector.value
        let documentChanges = publications.flatMap(\.changes).compactMap { change -> DocumentChange? in
            if case .document(let document) = change { return document }
            return nil
        }
        #expect(documentChanges.contains { $0.kind == "app.todos" && $0.value?["items"] == ["x"] })
        #expect(zip(publications, publications.dropFirst()).allSatisfy { $0.seq < $1.seq })
    }

    @Test func modelsCompleteAndStream() async throws {
        let models = Models(builtinProviders: false)
        let faux = FauxProvider()
        try await models.register(faux)
        try await faux.append(.text("Direct answer"))
        let context = ModelContext(
            systemPrompt: "Be brief.", messages: [.user(UserMessage(content: [.text("Hi")]))], tools: [ModelTool(weatherTool)])
        let message = try await models.complete(faux.model, context: context)
        #expect(message.text == "Direct answer")
        #expect(message.usage.totalTokens > 0)

        try await faux.append(.text("Streamed answer"), .toolCall("get_weather", ["city": "Oslo"]))
        var text = ""
        var calls: [ToolCall] = []
        var final: AssistantMessage?
        for try await event in models.stream(faux.model, context: context) {
            switch event {
            case .textDelta(_, let delta): text += delta
            case .toolCall(_, let call): calls.append(call)
            case .done(let message): final = message
            default: break
            }
        }
        #expect(text == "Streamed answer")
        #expect(calls.first?.arguments["city"] == "Oslo")
        #expect(final?.stopReason == .toolUse)
    }

    @Test func storageOnYourOwnSQLiteDatabase() async throws {
        let path = temporaryDirectory().appending(path: "custom.sqlite").path(percentEncoded: false)
        let database = try TestSQLiteDatabase(path: path)
        do {
            let setup = try await FauxSetup.make(.sqlite(database: database))
            try await setup.faux.append(.text("Stored through Swift"))
            let root = try await setup.root()
            _ = try await ask(root, "Remember")
            try await root.update(todosDocument) { $0.items = ["custom"] }
            // A failing commit writes nothing (pi-durable stages writes before the storage transaction).
            struct Boom: Error {}
            await #expect(throws: Boom.self) {
                try await root.commit { tx in
                    try await tx.append(EntryDraft(kind: "app.note"), to: root.id)
                    throw Boom()
                }
            }
            try await setup.harness.close()
        }
        #expect(database.transactions > 3)

        let reopened = try TestSQLiteDatabase(path: path)
        let setup = try await FauxSetup.make(.sqlite(database: reopened))
        let root = try await setup.root()
        #expect(try await root.view().messages.map(\.text) == ["Remember", "Stored through Swift"])
        #expect(try await root.document(todosDocument).items == ["custom"])
        #expect(try await root.view().entries.contains { $0.kind == "app.note" } == false)
        try await setup.harness.close()
    }
}
