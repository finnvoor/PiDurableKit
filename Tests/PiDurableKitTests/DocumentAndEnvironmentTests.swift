import Foundation
import Testing
@testable import PiDurableKit

struct Preferences: Codable, Sendable, Equatable {
    var theme = "light"
    var nested = Nested()

    struct Nested: Codable, Sendable, Equatable {
        var values: [Int] = []
        var flag = false
    }
}

struct FileNote: Codable, Sendable, Equatable {
    var text = ""
}

@Suite struct DocumentScopeTests {
    @Test func sessionDocuments() async throws {
        let preferences = Document("test.preferences", scope: .session, initial: Preferences())
        let setup = try await FauxSetup.make()
        #expect(try await setup.harness.document(preferences) == Preferences())
        try await setup.harness.update(preferences) { value in
            value.theme = "dark"
            value.nested.values = [1, 2, 3]
        }
        try await setup.harness.update(preferences) { $0.nested.values.append(4) }
        let stored = try await setup.harness.document(preferences)
        #expect(stored.theme == "dark")
        #expect(stored.nested.values == [1, 2, 3, 4])
        try await setup.harness.retire(preferences)
        #expect(try await setup.harness.document(preferences) == Preferences())
    }

    @Test func keyedFamilies() async throws {
        let notes = Document("test.fileNotes", keyed: true, initial: FileNote())
        let setup = try await FauxSetup.make()
        let root = try await setup.root()
        try await root.update(notes, key: "a.txt") { $0.text = "about a" }
        try await root.update(notes, key: "b.txt") { $0.text = "about b" }
        #expect(try await root.document(notes, key: "a.txt").text == "about a")
        #expect(try await root.document(notes, key: "b.txt").text == "about b")
        #expect(try await root.document(notes, key: "c.txt") == FileNote())
        await #expect(throws: (any Error).self) { _ = try await root.document(notes) }
    }

    @Test func rewindableDocumentsReadAsOfAnEntry() async throws {
        let mood = Document("test.mood", history: .rewindable, fork: .asOf, initial: FileNote())
        let setup = try await FauxSetup.make()
        let root = try await setup.root()
        try await root.update(mood) { $0.text = "happy" }
        let marker = try await root.write(EntryDraft(kind: "app.marker")).wait()
        guard case .done(let markerEntry, _) = marker.status else {
            Issue.record("Expected a placed marker")
            return
        }
        try await root.update(mood) { $0.text = "sad" }
        #expect(try await root.document(mood).text == "sad")
        #expect(try await root.document(mood, asOf: markerEntry).text == "happy")

        let fork = try await root.fork(at: markerEntry)
        #expect(try await fork.document(mood).text == "happy")
    }

    @Test func documentsMigrateOlderVersions() async throws {
        let url = temporaryDirectory().appending(path: "docs.sqlite")
        struct V1: Codable, Sendable { var name = "" }
        struct V2: Codable, Sendable, Equatable { var fullName = "" }
        do {
            let v1 = Document("test.person", scope: .session, initial: V1())
            let setup = try await FauxSetup.make(.sqlite(at: url))
            try await setup.harness.update(v1) { $0.name = "Ada" }
            try await setup.harness.close()
        }
        let v2 = Document("test.person", version: 2, scope: .session, initial: V2(), migrate: { stored, version in
            #expect(version == 1)
            return V2(fullName: (stored["name"]?.stringValue ?? "") + " Lovelace")
        })
        let setup = try await FauxSetup.make(.sqlite(at: url))
        #expect(try await setup.harness.document(v2) == V2(fullName: "Ada Lovelace"))
        try await setup.harness.close()
    }

    @Test func conversationCreatedAndInitializeSeedDocuments() async throws {
        let models = Models(builtinProviders: false)
        let harness = try await Harness.open(models: models) { tx, record in
            try await tx.setDocument(todosDocument, Todos(items: ["created \(record.id)"]), of: .conversation(record.id))
        }
        let root = try await harness.root()
        #expect(try await root.document(todosDocument).items == ["created \(root.id)"])

        let other = try await harness.createConversation { tx, conversation in
            try await tx.updateDocument(todosDocument, of: .conversation(conversation)) { $0.items.append("initialized") }
        }
        #expect(try await other.document(todosDocument).items == ["created \(other.id)", "initialized"])
    }

    @Test func transactionsAreAtomic() async throws {
        struct Boom: Error {}
        let setup = try await FauxSetup.make()
        let root = try await setup.root()
        await #expect(throws: Boom.self) {
            try await root.commit { tx in
                try await tx.append(EntryDraft(kind: "app.note"), to: root.id)
                try await tx.setDocument(todosDocument, Todos(items: ["never"]), of: .conversation(root.id))
                throw Boom()
            }
        }
        #expect(try await root.view().entries.isEmpty)
        #expect(try await root.document(todosDocument) == Todos())

        // Reads come before the commit's first table write.
        let count = try await setup.harness.commit { tx in
            let before = try await tx.entries(in: root.id).items.count
            let entry = try await tx.append(EntryDraft(kind: "app.note"), to: root.id)
            #expect(entry.kind == "app.note")
            return before
        }
        #expect(count == 0)
        #expect(try await root.view().entries.count == 1)
    }
}

@Suite struct EnvironmentTests {
    @Test func codingToolsWorkInTheSandbox() async throws {
        let directory = temporaryDirectory()
        try "hello world\nsecond line\n".write(to: directory.appending(path: "notes.txt"), atomically: true, encoding: .utf8)
        let models = Models(builtinProviders: false)
        let faux = FauxProvider()
        try await models.register(faux)
        let harness = try await Harness.open(
            models: models, extensions: [.codingTools()], environment: .directory(directory))
        let root = try await harness.root(agent: AgentChange(model: faux.model))
        #expect(try await root.agent().tools.sorted() == ["edit", "read", "write"])

        try await faux.append(.toolCall("read", ["path": "/notes.txt"]))
        try await faux.append(.toolCall("write", ["path": "drafts/new.md", "content": "# Draft\n"]))
        try await faux.append(.toolCall("edit", ["path": "/notes.txt", "edits": [["oldText": "world", "newText": "sandbox"]]]))
        try await faux.append(.toolCall("read", ["path": "../../../../etc/hosts"]))
        try await faux.append(.text("Done"))
        _ = try await withTimeout { try await ask(root, "Work with files") }

        let results = try await root.view().entries.compactMap(\.toolResult)
        #expect(results.count == 4)
        #expect(results[0].text.contains("hello world"))
        #expect(results[0].isError == false)
        #expect(results[1].isError == false)
        #expect(results[2].isError == false)
        // `..` cannot climb out: the path resolves to /etc/hosts inside the sandbox, which does not exist.
        #expect(results[3].isError)
        // Errors show sandbox paths, never the app's container paths.
        #expect(!results.contains { $0.text.contains(directory.path(percentEncoded: false)) || $0.text.contains("/private/") })

        #expect(try String(contentsOf: directory.appending(path: "drafts/new.md"), encoding: .utf8) == "# Draft\n")
        #expect(try String(contentsOf: directory.appending(path: "notes.txt"), encoding: .utf8) == "hello sandbox\nsecond line\n")
        try await harness.close()
    }

    @Test func conversationWorkingDirectory() async throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory.appending(path: "project"), withIntermediateDirectories: true)
        let models = Models(builtinProviders: false)
        let faux = FauxProvider()
        try await models.register(faux)
        let harness = try await Harness.open(models: models, extensions: [.codingTools()], environment: .directory(directory))
        let root = try await harness.root(agent: AgentChange(model: faux.model, cwd: "/project"))
        try await faux.append(.toolCall("write", ["path": "readme.md", "content": "hi"]))
        try await faux.append(.text("Done"))
        _ = try await ask(root, "Write")
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "project/readme.md").path(percentEncoded: false)))
        try await harness.close()
    }

    @Test func toolsFailWithoutAnEnvironment() async throws {
        let setup = try await FauxSetup.make(extensions: [.codingTools()])
        try await setup.faux.append(.toolCall("read", ["path": "/x"]))
        try await setup.faux.append(.text("Done"))
        let root = try await setup.root()
        _ = try await ask(root, "Read")
        #expect(try await root.view().entries.first { $0.kind == .toolResult }?.toolResult?.isError == true)
    }

    @Test func jsonlStorageSurvivesReopen() async throws {
        let directory = temporaryDirectory().appending(path: "jsonl")
        do {
            let setup = try await FauxSetup.make(.jsonl(at: directory, fsync: true))
            try await setup.faux.append(.text("Stored in JSONL"))
            let root = try await setup.root()
            _ = try await ask(root, "Remember")
            try await root.update(todosDocument) { $0.items = ["jsonl"] }
            try await setup.harness.close()
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))
        #expect(!files.isEmpty)
        let setup = try await FauxSetup.make(.jsonl(at: directory))
        let root = try await setup.root()
        #expect(try await root.view().messages.map(\.text) == ["Remember", "Stored in JSONL"])
        #expect(try await root.document(todosDocument).items == ["jsonl"])
        try await setup.harness.close()
    }
}

@Suite struct SettingsAndModelTests {
    @Test func streamSettingsEncode() throws {
        let settings = Settings(stream: .init(
            timeout: .seconds(30), transport: "sse", metadata: ["user_id": "u1"], deferred: .window("1h")))
        let json = try JSONValue(encoding: settings)
        #expect(json["stream"]?["timeoutMs"] == 30000)
        #expect(json["stream"]?["transport"] == "sse")
        #expect(json["stream"]?["metadata"]?["user_id"] == "u1")
        #expect(json["stream"]?["deferred"]?["window"] == "1h")
    }

    @Test func refreshModelCatalogs() async throws {
        let models = Models()
        let result = try await models.refresh(providers: [.anthropic], allowNetwork: false)
        #expect(result.aborted == false)
        #expect(result.errors.isEmpty)
        #expect(try await !models.models(for: .anthropic).isEmpty)
    }
}
