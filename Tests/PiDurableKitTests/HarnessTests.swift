import Foundation
import Testing
@testable import PiDurableKit

struct WeatherArguments: Codable, Sendable {
    var city: String
}

let weatherTool = Tool(
    "get_weather",
    description: "Look up the current weather in a city",
    parameters: .object(["city": .string("City name")])
) { (arguments: WeatherArguments, call) in
    call.output("Looking up \(arguments.city)…\n")
    try await call.details(["city": arguments.city])
    return "Sunny and 22°C in \(arguments.city)"
}

@Suite struct HarnessTests {
    @Test func toolCallRoundTrip() async throws {
        let setup = try await FauxSetup.make(extensions: [Extension("weather", tools: [weatherTool])])
        try await setup.faux.append(.toolCall("get_weather", ["city": "Paris"]))
        try await setup.faux.append(.text("It is sunny in Paris."))

        let root = try await setup.root()
        let answer = try await ask(root, "Weather in Paris?")
        #expect(answer.text == "It is sunny in Paris.")

        let view = try await root.view()
        let kinds = view.entries.map(\.kind)
        #expect(kinds.contains(.user))
        #expect(kinds.contains(.toolResult))
        let result = try #require(view.entries.first { $0.kind == .toolResult }?.toolResult)
        #expect(result.text == "Sunny and 22°C in Paris")
        #expect(result.details == ["city": "Paris"])
        #expect(result.isError == false)
        #expect(view.isBusy == false)
        try await setup.harness.close()
    }

    @Test func toolErrorsReachTheModel() async throws {
        struct Failure: Error, LocalizedError {
            var errorDescription: String? { "The weather service is down" }
        }
        let failing = Tool("get_weather", description: "Weather", parameters: .object(["city": .string])) {
            (_: WeatherArguments, _) -> String in throw Failure()
        }
        let setup = try await FauxSetup.make(extensions: [Extension("weather", tools: [failing])])
        try await setup.faux.append(.toolCall("get_weather", ["city": "Paris"]))
        try await setup.faux.append(.text("Sorry."))
        let root = try await setup.root()
        _ = try await ask(root, "Weather?")
        let result = try #require(try await root.view().entries.first { $0.kind == .toolResult }?.toolResult)
        #expect(result.isError)
        #expect(result.text.contains("The weather service is down"))
    }

    @Test func beforeToolHookBlocks() async throws {
        let guarded = Extension("guard") {
            weatherTool
            Hook.beforeTool { call, _ in
                call.name == "get_weather" ? .block("Weather needs approval") : .allow
            }
        }
        let setup = try await FauxSetup.make(extensions: [guarded])
        try await setup.faux.append(.toolCall("get_weather", ["city": "Paris"]))
        try await setup.faux.append(.text("Blocked."))
        let root = try await setup.root()
        _ = try await ask(root, "Weather?")
        let result = try #require(try await root.view().entries.first { $0.kind == .toolResult }?.toolResult)
        #expect(result.isError)
        #expect(result.text.contains("Weather needs approval"))
    }

    @Test func beforeToolHookRewritesArguments() async throws {
        let rewriting = Extension("rewrite") {
            weatherTool
            Hook.beforeTool { _, _ in .rewrite(["city": "Berlin"]) }
        }
        let setup = try await FauxSetup.make(extensions: [rewriting])
        try await setup.faux.append(.toolCall("get_weather", ["city": "Paris"]))
        try await setup.faux.append(.text("Done."))
        let root = try await setup.root()
        _ = try await ask(root, "Weather?")
        let result = try #require(try await root.view().entries.first { $0.kind == .toolResult }?.toolResult)
        #expect(result.text == "Sunny and 22°C in Berlin")
    }

    @Test func onYieldContinuesTheRun() async throws {
        let persistent = Extension("persistent") {
            Hook.onYield { answer, _ in answer.text == "Draft" ? "Keep going." : nil }
        }
        let setup = try await FauxSetup.make(extensions: [persistent])
        try await setup.faux.append(.text("Draft"))
        try await setup.faux.append(.text("Final"))
        let root = try await setup.root()
        let answer = try await ask(root, "Write something")
        #expect(answer.text == "Final")
    }

    @Test func sectionsAndInstructionsBuildTheSystemPrompt() async throws {
        let prompt = Extension("prompt") {
            PromptSection("preamble", tag: false, text: "You are a concise assistant.")
            PromptSection("conversation") { input in "Conversation \(input.conversationId)" }
        }
        let setup = try await FauxSetup.make(extensions: [prompt])
        try await setup.faux.append(.text("Hi"))
        let root = try await setup.root(AgentChange(instructions: "Answer in French."))
        _ = try await ask(root, "Hello")

        let (_, messages) = try await root.context()
        let systems = messages.compactMap { message -> SystemMessage? in
            if case .system(let system) = message { return system }
            return nil
        }
        let system = try #require(systems.first)
        let text = ([system.text] + system.sections.values.compactMap { $0 }).joined(separator: "\n")
        #expect(text.contains("You are a concise assistant."))
        #expect(text.contains("<conversation>\nConversation \(root.id)\n</conversation>"))
        #expect(text.contains("Answer in French."))
    }

    @Test func fauxResponderSeesTheTranscript() async throws {
        let setup = try await FauxSetup.make()
        try await setup.faux.respond { messages, _ in
            .text("Echo: \(messages.last { $0.role == "user" }?.text ?? "")")
        }
        let root = try await setup.root()
        #expect(try await ask(root, "one").text == "Echo: one")
        #expect(try await ask(root, "two").text == "Echo: two")
    }

    @Test func agentConfiguration() async throws {
        let first = Extension("first", tools: [weatherTool])
        let second = Extension("second")
        let setup = try await FauxSetup.make(extensions: [first, second])
        let root = try await setup.root()

        var agent = try await root.agent()
        #expect(agent.extensions == ["first", "second"])
        #expect(agent.tools == ["get_weather"])
        #expect(agent.model == setup.faux.model)

        try await root.configure(AgentChange(thinkingLevel: .high, extensions: .remove(first), instructions: "Be brief."))
        agent = try await root.agent()
        #expect(agent.extensions == ["second"])
        #expect(agent.tools.isEmpty)
        #expect(agent.thinkingLevel == .high)
        #expect(agent.instructions == "Be brief.")

        try await root.configure(AgentChange(reset: [.extensions, .instructions]))
        agent = try await root.agent()
        #expect(agent.extensions == ["first", "second"])
        #expect(agent.instructions == nil)
    }

    @Test func installAndUninstallExtensions() async throws {
        let setup = try await FauxSetup.make()
        let root = try await setup.root()
        #expect(try await root.agent().tools.isEmpty)
        try await setup.harness.install(Extension("weather", tools: [weatherTool]))
        #expect(try await root.agent().tools == ["get_weather"])
        #expect(try await setup.harness.installedExtensions() == ["weather"])
        try await setup.harness.uninstall("weather")
        #expect(try await root.agent().tools.isEmpty)
    }

    @Test func requestIdDeduplicatesSubmissions() async throws {
        let setup = try await FauxSetup.make()
        try await setup.faux.append(.text("Hello"))
        let root = try await setup.root()
        let first = try await root.submit("Hi", requestId: "greeting-1")
        let second = try await root.submit("Hi", requestId: "greeting-1")
        #expect(first.id == second.id)
        let record = try await first.wait()
        guard case .done = record.status else {
            Issue.record("Expected done, got \(record.status)")
            return
        }
    }

    @Test func unansweredInputThrowsSubmissionError() async throws {
        let setup = try await FauxSetup.make(settings: Settings(retry: .init(enabled: false)))
        try await setup.faux.append([.error("Provider exploded")])
        let root = try await setup.root()
        await #expect(throws: Unanswered.self) {
            _ = try await ask(root, "Hi")
        }
    }

    @Test func multipleConversationsAndForks() async throws {
        let setup = try await FauxSetup.make()
        try await setup.faux.respond { messages, _ in
            .text("Seen \(messages.filter { $0.role == "user" }.count) user messages")
        }
        let root = try await setup.root()
        _ = try await ask(root, "one")
        _ = try await ask(root, "two")

        let other = try await setup.harness.createConversation(agent: AgentChange(model: setup.faux.model))
        #expect(try await ask(other, "hello").text == "Seen 1 user messages")

        let firstAnswer = try #require(try await root.view().entries.first { $0.kind == .assistant })
        let fork = try await root.fork(at: firstAnswer.id)
        #expect(try await ask(fork, "three").text == "Seen 2 user messages")

        let conversations = try await setup.harness.commit { tx in try await tx.conversations() }
        #expect(Set(conversations.items.map(\.id)).isSuperset(of: [root.id, other.id, fork.id]))
        #expect(conversations.items.first { $0.id == fork.id }?.parent?.conversationId == root.id)

        let history = try await root.entries(limit: 2)
        #expect(history.items.count == 2)
        #expect(history.next != nil)
    }

    @Test func resetStartsANewContext() async throws {
        let setup = try await FauxSetup.make()
        try await setup.faux.respond { messages, _ in
            .text("\(messages.filter { $0.role == "user" }.map(\.text))")
        }
        let root = try await setup.root()
        _ = try await ask(root, "one")
        try await root.reset(handoff: "We talked about one.")
        let answer = try await ask(root, "two")
        #expect(answer.text == #"["We talked about one.", "two"]"#)
    }

    @Test func usageIsTracked() async throws {
        let setup = try await FauxSetup.make()
        try await setup.faux.append(.text("A fairly long answer to make some tokens"))
        let root = try await setup.root()
        _ = try await ask(root, "Hi there")
        let usage = try await setup.harness.usage()
        #expect(usage.totalTokens > 0)
        #expect(usage.models.keys.contains("faux/faux-1"))
    }

    @Test func writesAppendEntries() async throws {
        let setup = try await FauxSetup.make()
        let root = try await setup.root()
        let submission = try await root.write(EntryDraft(kind: "app.note", data: ["text": "User opened a file"]))
        let record = try await submission.wait()
        guard case .done(let entryID, _) = record.status else {
            Issue.record("Expected done, got \(record.status)")
            return
        }
        let entry = try #require(try await root.commit { tx in try await tx.entry(entryID) })
        #expect(entry.kind == "app.note")
        #expect(entry.data?["text"] == "User opened a file")
    }
}
