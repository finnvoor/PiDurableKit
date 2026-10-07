import Foundation
import Testing
@testable import PiDurableKit

@Suite struct HookTests {
    @Test func beforeRequestRewritesTheRequest() async throws {
        let seen = Mutex<[String]>([])
        let inject = Extension("inject") {
            Hook.beforeRequest { messages, _ in
                messages + [.user(UserMessage(content: [.text("Injected context")]))]
            }
        }
        let setup = try await FauxSetup.make(extensions: [inject])
        try await setup.faux.respond { messages, _ in
            seen.set(messages.filter { $0.role == "user" }.map(\.text))
            return .text("ok")
        }
        let root = try await setup.root()
        _ = try await ask(root, "Hello")
        #expect(seen.get() == ["Hello", "Injected context"])
        // The rewrite applies to that request only; the transcript is unchanged.
        #expect(try await root.view().messages.map(\.text) == ["Hello", "ok"])
    }

    @Test func unchangedMessagesKeepProviderFields() throws {
        let json = #"{"role":"assistant","content":[{"type":"text","text":"Hi","textSignature":"sig-1"}],"api":"x","provider":"p","model":"m","usage":{"input":1,"output":1,"cacheRead":0,"cacheWrite":0,"totalTokens":2,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"stopReason":"stop","responseId":"resp_9","timestamp":1}"#
        let message = try JSONDecoder().decode(Message.self, from: Data(json.utf8))
        let unchanged = try JSONValue(encoding: message)
        #expect(unchanged["responseId"] == "resp_9")
        #expect(unchanged["content"]?[0]?["textSignature"] == "sig-1")

        guard case .assistant(var assistant) = message else {
            Issue.record("Expected an assistant message")
            return
        }
        assistant.content = [.text("Changed")]
        let changed = try JSONValue(encoding: Message.assistant(assistant))
        #expect(changed["responseId"] == "resp_9")
        #expect(changed["content"]?[0]?["text"] == "Changed")
    }

    @Test func afterResponseAndAfterToolsObserveTheRun() async throws {
        let responses = Mutex<[String]>([])
        let rounds = Mutex<[(EntryID, [EntryID])]>([])
        let observe = Extension("observe") {
            weatherTool
            Hook.afterResponse { message, _ in responses.update { $0.append(message.stopReason.rawValue) } }
            Hook.afterTools { assistant, results, _ in rounds.update { $0.append((assistant, results)) } }
        }
        let setup = try await FauxSetup.make(extensions: [observe])
        try await setup.faux.append(.toolCall("get_weather", ["city": "Oslo"]))
        try await setup.faux.append(.text("Cold."))
        let root = try await setup.root()
        _ = try await ask(root, "Weather?")
        #expect(responses.get() == ["toolUse", "stop"])
        let view = try await root.view()
        let toolCalling = try #require(view.entries.first { $0.assistantMessage?.stopReason == .toolUse })
        let result = try #require(view.entries.first { $0.kind == .toolResult })
        let round = try #require(rounds.get().first)
        #expect(round.0 == toolCalling.id)
        #expect(round.1 == [result.id])
    }

    @Test func beforeCompactSuppliesASummary() async throws {
        let requests = Mutex<[String]>([])
        let summarize = Extension("summarize") {
            Hook.beforeCompact { request, _ in
                requests.update { $0.append(request.reason) }
                return .summary("Custom summary of \(request.entries.count) entries")
            }
        }
        let setup = try await FauxSetup.make(
            extensions: [summarize], settings: Settings(compaction: .init(keepRecentTokens: 1)))
        try await setup.faux.respond { _, _ in .text("An answer that is long enough to be worth summarizing later on.") }
        let root = try await setup.root()
        for index in 1...3 { _ = try await ask(root, "Message number \(index) with some padding text") }

        let task = try await root.compact(instructions: "Keep it short")
        let record = try await withTimeout { try await setup.harness.waitForTask(task) }
        #expect(record.outcome?.isCompleted == true)
        try await root.waitForIdle()
        #expect(requests.get() == ["manual"])
        let summary = try #require(try await root.view().entries.first { $0.kind == .compaction })
        #expect(summary.text.contains("Custom summary of"))
    }

    @Test func beforeCompactCanDecline() async throws {
        let decline = Extension("decline") { Hook.beforeCompact { _, _ in .decline } }
        let setup = try await FauxSetup.make(extensions: [decline], settings: Settings(compaction: .init(keepRecentTokens: 1)))
        try await setup.faux.respond { _, _ in .text("An answer that is long enough to be worth summarizing later on.") }
        let root = try await setup.root()
        for index in 1...3 { _ = try await ask(root, "Message number \(index) with some padding text") }
        let task = try await root.compact()
        _ = try await withTimeout { try await setup.harness.waitForTask(task) }
        try await root.waitForIdle()
        #expect(try await root.view().entries.contains { $0.kind == .compaction } == false)
    }

    @Test func hookContextMemosAndDocuments() async throws {
        let seen = Mutex<[String]>([])
        let observe = Extension("observe") {
            weatherTool
            Hook.beforeTool { _, context in
                let memo = try await context.memo("attempt", default: "first")
                let todos = try await context.document(todosDocument)
                seen.set([memo, todos.items.joined(), "\(context.conversationId)"])
                return .allow
            }
        }
        let setup = try await FauxSetup.make(extensions: [observe])
        try await setup.faux.append(.toolCall("get_weather", ["city": "Rome"]))
        try await setup.faux.append(.text("Warm."))
        let root = try await setup.root()
        try await root.update(todosDocument) { $0.items = ["x"] }
        _ = try await ask(root, "Weather?")
        #expect(seen.get() == ["first", "x", "\(root.id)"])
    }
}

@Suite struct SectionAndWrapTests {
    @Test func sectionsSeeShownSectionsAndDocuments() async throws {
        let shown = Mutex<[[String: String]]>([])
        let prompt = Extension("prompt") {
            PromptSection("todos") { input in
                shown.update { $0.append(input.shown) }
                return try await input.document(todosDocument).items.joined(separator: ", ")
            }
        }
        let setup = try await FauxSetup.make(extensions: [prompt])
        try await setup.faux.respond { _, _ in .text("ok") }
        let root = try await setup.root()
        try await root.update(todosDocument) { $0.items = ["milk", "eggs"] }
        _ = try await ask(root, "one")
        _ = try await ask(root, "two")
        let renders = shown.get()
        #expect(renders.first?["todos"] == nil)
        #expect(renders.last?["todos"]?.contains("milk, eggs") == true)
    }

    @Test func toolWrapsDecorateAnotherExtensionsTool() async throws {
        let timing = Extension("timing") {
            Wrap.tool("get_weather") { call, _, next in
                var result = try await next(["city": .string("Wrapped \(call.arguments["city"]?.stringValue ?? "")")])
                result.content = [.text("[wrapped] " + (result.content?.compactMap(\.text).joined() ?? ""))]
                return result
            }
        }
        let setup = try await FauxSetup.make(extensions: [Extension("weather", tools: [weatherTool]), timing])
        try await setup.faux.append(.toolCall("get_weather", ["city": "Paris"]))
        try await setup.faux.append(.text("Done"))
        let root = try await setup.root()
        _ = try await ask(root, "Weather?")
        let result = try #require(try await root.view().entries.first { $0.kind == .toolResult }?.toolResult)
        #expect(result.text == "[wrapped] Sunny and 22°C in Wrapped Paris")
    }

    @Test func sectionWrapsDecorateSections() async throws {
        let base = Extension("base") { PromptSection("rules", text: "Be brief.") }
        let louder = Extension("louder") {
            Wrap.section("rules") { _, next in (try await next()).map { $0 + " Use capitals." } }
        }
        let setup = try await FauxSetup.make(extensions: [base, louder])
        try await setup.faux.append(.text("OK"))
        let root = try await setup.root()
        _ = try await ask(root, "Hi")
        let (_, messages) = try await root.context()
        let system = try #require(messages.compactMap { message -> SystemMessage? in
            if case .system(let system) = message { return system }
            return nil
        }.first)
        let text = ([system.text] + system.sections.values.compactMap { $0 }).joined(separator: "\n")
        #expect(text.contains("Be brief. Use capitals."))
    }
}

struct Note: Codable, Sendable, Equatable {
    var text: String
}

@Suite struct EntryAndChangeTests {
    @Test func typedEntries() async throws {
        let note = EntryType<Note>("app.note")
        let setup = try await FauxSetup.make()
        let root = try await setup.root()
        try await root.write(note, Note(text: "first")).wait()
        try await root.commit { tx in
            try await tx.append(note, Note(text: "second"), to: root.id, model: [.user(UserMessage(content: [.text("A note")]))])
        }
        let entries = try await root.view().entries
        #expect(entries.compactMap { $0.data(as: note) } == [Note(text: "first"), Note(text: "second")])
        #expect(entries.last?.model?.first?.text == "A note")
        #expect(entries.first?.data(as: EntryType<Note>("app.other")) == nil)
    }

    @Test func changesCarryChordOperations() async throws {
        let setup = try await FauxSetup.make()
        let root = try await setup.root()
        let collector = Task {
            try await withTimeout {
                var changes: [ConversationChange] = []
                for try await change in root.changes() {
                    changes.append(change)
                    if change.view.entries.contains(where: { $0.kind == "app.note" }) { return changes }
                }
                return changes
            }
        }
        try await Task.sleep(for: .milliseconds(100))
        try await root.write(EntryDraft(kind: "app.note", data: ["text": "hi"])).wait()
        let changes = try await collector.value
        #expect(changes.first?.ops.isEmpty == true)
        #expect(changes.last?.ops.isEmpty == false)
    }
}
