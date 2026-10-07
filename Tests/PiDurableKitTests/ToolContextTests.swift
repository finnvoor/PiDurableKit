import Foundation
import Testing
@testable import PiDurableKit

struct SubagentArguments: Codable, Sendable {
    var task: String
}

/// The README's foreground subagent: a replay-safe tool that creates a child conversation it owns, configures it,
/// submits the task, and returns the child's answer.
let subagentTool = Tool(
    "subagent", description: "Delegate a task to a subagent", parameters: .object(["task": .string("The task")]), replay: .safe
) { (arguments: SubagentArguments, call) -> ToolResult in
    let child = try await call.commit { tx in
        if let existing = try await tx.conversations(ownedBy: call.taskId, limit: 1).items.first { return existing.id }
        let created = try await tx.createConversation(ownedBy: call.taskId)
        try await tx.configure(created.id, AgentChange(instructions: "You are a researcher."))
        return created.id
    }
    try await call.details(["conversationId": child.rawValue])
    let handle = try #require(try await call.conversation(child))
    let settled = try await handle.submit(arguments.task, requestId: "subagent:\(call.taskId)").wait()
    guard case .done(_, let answer?) = settled.status else { return .error("The subagent did not answer") }
    let entry = try await call.commit { tx in try await tx.entry(answer) }
    return .text(entry?.assistantMessage?.text ?? "", details: ["conversationId": .number(Double(child.rawValue))])
}

@Suite struct ToolContextTests {
    @Test func subagentConversationIsOwnedByTheCall() async throws {
        let setup = try await FauxSetup.make(extensions: [Extension("subagent", tools: [subagentTool])])
        try await setup.faux.append(.toolCall("subagent", ["task": "Find the answer"]))
        try await setup.faux.append(.text("The child found 42."))
        try await setup.faux.append(.text("The subagent says 42."))

        let root = try await setup.root()
        let answer = try await withTimeout { try await ask(root, "Ask a subagent") }
        #expect(answer.text == "The subagent says 42.")

        let result = try #require(try await root.view().entries.first { $0.kind == .toolResult }?.toolResult)
        #expect(result.text == "The child found 42.")
        let childID = ConversationID(try #require(result.details?["conversationId"]?.intValue))
        let child = try #require(try await setup.harness.conversation(childID))
        let record = try #require(try await setup.harness.commit { tx in try await tx.conversation(childID) })
        #expect(record.owner?.conversationId == root.id)
        #expect(try await child.agent().instructions == "You are a researcher.")
        #expect(try await child.view().messages.map(\.text) == ["Find the answer", "The child found 42."])
    }

    @Test func memosAgentAndDocumentsInsideTools() async throws {
        let seen = Mutex<[String]>([])
        let inspect = Tool("inspect", description: "Inspect") { call -> ToolResult in
            let first = try await call.memo("token", default: "first")
            let second = try await call.memo("token", default: "second")
            let missing: String? = try await call.memo("missing")
            let agent = try await call.agent()
            let todos = try await call.document(todosDocument)
            seen.set([first, second, missing ?? "nil", agent.instructions ?? "", todos.items.joined(separator: ",")])
            return "ok"
        }
        let setup = try await FauxSetup.make(extensions: [Extension("inspect", tools: [inspect])])
        try await setup.faux.append(.toolCall("inspect", [:]))
        try await setup.faux.append(.text("Done"))
        let root = try await setup.root(AgentChange(instructions: "Be curious."))
        try await root.update(todosDocument) { $0.items = ["a", "b"] }
        _ = try await ask(root, "Inspect")
        #expect(seen.get() == ["first", "first", "nil", "Be curious.", "a,b"])
    }

    @Test func toolsCreateAndAwaitTasks() async throws {
        let spawn = Tool("spawn", description: "Run a task") { call -> String in
            let id = try await call.createTask(doubler, input: 21)
            let record = try await call.waitForTask(id)
            #expect(try await call.task(id)?.isTerminal == true)
            return "\(try record.outcome(as: Int.self)?.result ?? -1)"
        }
        let setup = try await FauxSetup.make(extensions: [Extension("spawn") {
            spawn
            doubler
        }])
        try await setup.faux.append(.toolCall("spawn", [:]))
        try await setup.faux.append(.text("Done"))
        let root = try await setup.root()
        _ = try await withTimeout { try await ask(root, "Spawn") }
        let result = try #require(try await root.view().entries.first { $0.kind == .toolResult }?.toolResult)
        #expect(result.text == "42")
    }

    @Test func addToolsOffersMoreTools() async throws {
        let secret = Tool("secret", description: "A secret tool") { _ in "secret" }
        let unlock = Tool("unlock", description: "Unlock the secret tool") { _ in
            ToolResult.text("Unlocked").addingTools("secret")
        }
        let setup = try await FauxSetup.make(extensions: [Extension("tools", tools: [unlock, secret])])
        try await setup.faux.append(.toolCall("unlock", [:]))
        try await setup.faux.append(.text("Done"))
        let root = try await setup.root(AgentChange(tools: .only(["unlock"])))
        #expect(try await root.agent().tools == ["unlock"])
        _ = try await ask(root, "Unlock")
        #expect(try await root.agent().tools == ["unlock", "secret"])
    }

    @Test func prepareArgumentsRepairsModelMistakes() async throws {
        struct ListArguments: Codable, Sendable { var items: [String] }
        let list = Tool("list", description: "Join items", parameters: .object(["items": .array(of: .string)])) {
            (arguments: ListArguments, _) in arguments.items.joined(separator: "+")
        }.preparingArguments { raw in
            // Models sometimes send an array as a JSON string.
            guard let text = raw["items"]?.stringValue, let data = text.data(using: .utf8),
                let items = try? JSONDecoder().decode([String].self, from: data)
            else { return raw }
            return ["items": .array(items.map(JSONValue.string))]
        }
        let setup = try await FauxSetup.make(extensions: [Extension("list", tools: [list])])
        try await setup.faux.append(.toolCall("list", ["items": #"["a","b"]"#]))
        try await setup.faux.append(.text("Done"))
        let root = try await setup.root()
        _ = try await ask(root, "List")
        let result = try #require(try await root.view().entries.first { $0.kind == .toolResult }?.toolResult)
        #expect(result.text == "a+b")
        #expect(result.isError == false)
    }

    @Test func outputLimitsKeepTheTail() async throws {
        let noisy = Tool("noisy", description: "Prints lines") { call -> ToolResult in
            for index in 1...20 { call.output("line \(index)\n") }
            return .streamedOutput
        }.limitingOutput(.init(maxLines: 3, retain: .tail))
        let setup = try await FauxSetup.make(extensions: [Extension("noisy", tools: [noisy])])
        try await setup.faux.append(.toolCall("noisy", [:]))
        try await setup.faux.append(.text("Done"))
        let root = try await setup.root()
        _ = try await ask(root, "Print")
        let result = try #require(try await root.view().entries.first { $0.kind == .toolResult }?.toolResult)
        #expect(result.text.contains("line 20"))
        #expect(!result.text.contains("line 1\n"))
    }
}
