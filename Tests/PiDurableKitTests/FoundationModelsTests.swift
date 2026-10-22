#if canImport(FoundationModels)
import Foundation
import FoundationModels
import Testing
@testable import PiDurableKit

/// Whether Apple's on-device model can answer here (Apple Intelligence enabled, model downloaded).
let onDeviceModelAvailable: Bool = {
    if #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) { return SystemLanguageModel.default.isAvailable }
    return false
}()

/// Whether Private Cloud Compute can answer here: it needs an app with Apple's Private Cloud Compute entitlement, so
/// set `PIDURABLEKIT_TEST_PCC=1` when running the tests from such an app.
let privateCloudComputeAvailable: Bool = {
    guard ProcessInfo.processInfo.environment["PIDURABLEKIT_TEST_PCC"] == "1" else { return false }
    if #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) { return PrivateCloudComputeLanguageModel().isAvailable }
    return false
}()

private struct City: Codable, Sendable { var city: String }

/// The Foundation Models provider against the real on-device model.
@Suite(.enabled(if: onDeviceModelAvailable, "Needs Apple's on-device model"), .serialized)
struct FoundationModelsTests {
    @available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
    func setup(extensions: [Extension] = []) async throws -> (Harness, Conversation) {
        let models = Models(builtinProviders: false)
        try await models.register(FoundationModelsProvider())
        let harness = try await Harness.open(
            models: models, extensions: extensions, settings: Settings(compaction: .forContextWindow(8192)))
        let root = try await harness.root(agent: AgentChange(model: .appleOnDevice))
        return (harness, root)
    }

    @Test func registersTheModels() async throws {
        guard #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) else { return }
        let models = Models(builtinProviders: false)
        try await models.register(FoundationModelsProvider())
        let catalog = try await models.models(for: .apple)
        #expect(catalog.map(\.modelId) == ["on-device", "private-cloud-compute"])
        // The model's own size, or 4096 while a model that isn't ready yet reports none.
        #expect([SystemLanguageModel.default.contextSize, 4096].contains(catalog.first?.contextWindow ?? 0))
        // Private Cloud Compute's reasoning levels, and none for the on-device model.
        #expect(catalog.map(\.thinkingLevels) == [[.off], [.low, .medium, .high]])
        #expect(FoundationModelsResponder.reasoningLevel("off") == .light)
        #expect(FoundationModelsResponder.reasoningLevel("medium") == .moderate)
        #expect(FoundationModelsResponder.reasoningLevel("max") == .deep)
        #expect(try await models.isConfigured(.apple))
    }

    @Test func answersAndStreams() async throws {
        guard #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) else { return }
        let (harness, root) = try await setup()
        let events = try await harness.watchEvents(root.id)
        let deltas = Mutex(0)
        let collector = Task {
            for try await batch in events {
                for case .messageUpdate(let changes, _) in batch {
                    deltas.update { $0 += changes.count }
                }
            }
        }
        let answer = try await withTimeout(60) {
            try await ask(root, "Write a short paragraph about pineapples, about 80 words long.")
        }
        collector.cancel()
        #expect(answer.text.lowercased().contains("pineapple"))
        #expect(answer.provider == .apple)
        #expect(answer.usage.output > 0)
        #expect(deltas.get() > 0)
        try await harness.close()
    }

    @Test func toolCallsRunInPiDurable() async throws {
        guard #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) else { return }
        let calls = Mutex<[String]>([])
        let weather = Tool(
            "get_weather", description: "Get the current weather for a city", parameters: .object(["city": .string("The city")])
        ) { (args: City, _) in
            calls.update { $0.append(args.city) }
            return "It is 31 degrees and sunny in \(args.city)."
        }
        let (harness, root) = try await setup(extensions: [Extension("weather", tools: [weather])])
        let answer = try await withTimeout(90) {
            try await ask(root, "What is the weather in Paris right now? Use the get_weather tool, then tell me the temperature.")
        }
        #expect(calls.get().contains { $0.localizedCaseInsensitiveContains("paris") })
        let entries = try await root.view().entries
        #expect(entries.contains { $0.kind == .toolResult })
        #expect(answer.text.contains("31"))
        try await harness.close()
    }

    @Test func continuesTheConversation() async throws {
        guard #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) else { return }
        let (harness, root) = try await setup()
        _ = try await withTimeout(60) { try await ask(root, "My favorite color is teal. Just say OK.") }
        let answer = try await withTimeout(60) { try await ask(root, "What is my favorite color? Answer in one word.") }
        #expect(answer.text.lowercased().contains("teal"))
        try await harness.close()
    }

    @Test func imagesReachTheModel() async throws {
        guard #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) else { return }
        guard SystemLanguageModel.default.capabilities.contains(.vision) else { return }
        let (harness, root) = try await setup()
        let red = try SessionEndingTests.png(width: 64, height: 64, red: true)
        let submission = try await root.submit([
            .text("What single color fills this image? Answer with one word."),
            .image(ImageContent(data: red, mimeType: "image/png")),
        ])
        let answer = try await withTimeout(60) { try await PiDurableKitTests.answer(of: submission) }
        #expect(answer.text.lowercased().contains("red"))
        try await harness.close()
    }

    @Test(.enabled(if: privateCloudComputeAvailable, "Needs Private Cloud Compute"))
    func privateCloudCompute() async throws {
        guard #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) else { return }
        let models = Models(builtinProviders: false)
        try await models.register(FoundationModelsProvider())
        let harness = try await Harness.open(models: models)
        let root = try await harness.root(agent: AgentChange(model: .applePrivateCloudCompute, thinkingLevel: .low))
        let answer = try await withTimeout(120) { try await ask(root, "What is 17 times 23? Answer with just the number.") }
        #expect(answer.text.contains("391"))
        #expect(answer.model == "private-cloud-compute")
        try await harness.close()
    }

    @Test func overflowsReadAsContextOverflows() async throws {
        guard #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) else { return }
        let message = FoundationModelsResponder.message(
            for: LanguageModelError.contextSizeExceeded(.init(contextSize: 8192, tokenCount: 9000, debugDescription: "too long")))
        #expect(message.contains("exceeds the context window"))
        let (harness, root) = try await setup()
        let long = (1...1500).map { "Note \($0): the library opens at \($0 % 12 + 1) o'clock on day \($0 % 7 + 1)." }
            .joined(separator: " ")
        let settled = try await withTimeout(120) { try await root.submit(long).wait() }
        guard case .unanswered(_, _, let detail) = settled.status else {
            Issue.record("Expected an unanswered input, got \(settled.status)")
            return
        }
        #expect(detail?.stringValue?.contains("context window") == true, "\(String(describing: detail))")
        try await harness.close()
    }

    @Test func compactsWithinTheSmallWindow() async throws {
        guard #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) else { return }
        let (harness, root) = try await setup()
        // About 4,800 tokens of earlier conversation: past the blocking threshold of an 8,192-token window.
        for index in 1...16 {
            let note = (1...20).map { "Fact \(index).\($0): the shop on street \($0 + index) sells \(index * $0) apples." }
                .joined(separator: " ")
            _ = try await root.commit { tx in
                try await tx.append(EntryDraft(kind: "app.note", model: [.user(UserMessage(content: [.text(note)]))]), to: root.id)
            }
        }
        let answer = try await withTimeout(180) { try await ask(root, "Reply with just the word: done") }
        #expect(answer.text.lowercased().contains("done"))
        #expect(try await root.view().entries.contains { $0.kind == .compaction })
        try await harness.close()
    }

    @Test func abortStopsTheAnswer() async throws {
        guard #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) else { return }
        let (harness, root) = try await setup()
        let submission = try await root.submit("Write a 600 word story about a lighthouse keeper.")
        try await eventually(20) { try await root.view().streamingMessage != nil }
        let started = Date()
        try await withTimeout(10) { try await root.abort() }
        #expect(Date().timeIntervalSince(started) < 5)
        let settled = try await submission.wait()
        guard case .unanswered(_, let reason, _) = settled.status else {
            Issue.record("Expected an unanswered input, got \(settled.status)")
            return
        }
        #expect(reason == "aborted")
        try await harness.close()
    }

    @Test func parallelAndFailingToolCalls() async throws {
        guard #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) else { return }
        let calls = Mutex<[String]>([])
        let weather = Tool(
            "get_weather", description: "Get the current weather for one city", parameters: .object(["city": .string("The city")])
        ) { (args: City, _) -> String in
            calls.update { $0.append(args.city) }
            if args.city.localizedCaseInsensitiveContains("tokyo") { throw PiDurableError.runtime("Weather service down for Tokyo") }
            return "It is 31 degrees in \(args.city)."
        }
        let (harness, root) = try await setup(extensions: [Extension("weather", tools: [weather])])
        _ = try await withTimeout(120) {
            try await ask(root, "Get the weather in Paris and in Tokyo using get_weather, calling it once per city, then summarize.")
        }
        #expect(calls.get().count >= 2)
        let results = try await root.view().entries.compactMap(\.toolResult)
        #expect(results.contains { $0.isError })
        #expect(results.contains { !$0.isError && $0.text.contains("31") })
        #expect(try await root.usage().models["apple/on-device"]?.output ?? 0 > 0)
        try await harness.close()
    }

    @Test func steersJoinARunningToolRound() async throws {
        guard #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) else { return }
        let gate = Gate()
        let slow = Tool("lookup", description: "Look up a fact", parameters: .object(["topic": .string("The topic")])) {
            (_: [String: String], _) -> String in
            await gate.wait()
            return "The fact is: 42."
        }
        let (harness, root) = try await setup(extensions: [Extension("lookup", tools: [slow])])
        let submission = try await root.submit("Use the lookup tool to look up the answer, then tell me the number.")
        try await eventually(30) { try await !root.liveState().tools.isEmpty }
        _ = try await root.submit("Also, end your answer with the word: banana", whenBusy: .steer)
        gate.release()
        let answer = try await withTimeout(120) { try await PiDurableKitTests.answer(of: submission) }
        let messages = try await root.view().messages.map(\.text)
        #expect(messages.contains { $0.contains("banana") })
        _ = answer
        try await harness.close()
    }

    @Test func completeWithTools() async throws {
        guard #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) else { return }
        let models = Models(builtinProviders: false)
        try await models.register(FoundationModelsProvider())
        let message = try await withTimeout(60) {
            try await models.complete(.appleOnDevice, context: ModelContext(
                systemPrompt: "Use tools when asked.",
                messages: [.user(UserMessage(content: [.text("What's the weather in Oslo? Use get_weather.")]))],
                tools: [ModelTool(name: "get_weather", description: "Get the weather", parameters: .object(["city": .string()]))]))
        }
        #expect(message.stopReason == .toolUse)
        #expect(message.toolCalls.first?.name == "get_weather")
        let streamed = models.stream(.appleOnDevice, context: ModelContext(messages: [.user(UserMessage(content: [.text("Say hello.")]))]))
        var events = 0
        for try await _ in streamed { events += 1 }
        #expect(events > 1)
    }

    @Test func errorsReadAsPiAIExpects() throws {
        guard #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) else { return }
        let limited = FoundationModelsResponder.message(for: LanguageModelError.rateLimited(.init(resetDate: nil, debugDescription: "slow down")))
        #expect(limited.lowercased().contains("rate limit"))
        let timeout = FoundationModelsResponder.message(for: LanguageModelError.timeout(.init(debugDescription: "late")))
        #expect(timeout.lowercased().contains("timed out"))
        let overflow = FoundationModelsResponder.overflow(tokens: 9000, contextSize: 8192)
        #expect(overflow.contains("exceeds the context window"))
        // A request the system cancelled, as Private Cloud Compute reports it: an `NSError` over a `GenerativeError`.
        let generative = NSError(domain: FoundationModelsResponder.generativeErrorDomain, code: 2_010_000)
        let cancelled = NSError(domain: "FoundationModels.LanguageModelError", code: -1, userInfo: [
            NSMultipleUnderlyingErrorsKey: [NSError(domain: "FoundationModels.LanguageModelError", code: -1, userInfo: [NSMultipleUnderlyingErrorsKey: [generative]])],
        ])
        #expect(FoundationModelsResponder.message(for: cancelled) == "The system cancelled the request (service unavailable): LanguageModelError -1, GenerativeError 2010000")
        let unknown = NSError(domain: "FoundationModels.LanguageModelError", code: -1)
        #expect(FoundationModelsResponder.message(for: unknown) == "The model could not answer: LanguageModelError -1")
        let quota = FoundationModelsResponder.message(for: PrivateCloudComputeLanguageModel.Error.quotaLimitReached(.init(
            resetDate: Date(timeIntervalSince1970: 1_800_000_000), debugDescription: "limit")))
        #expect(quota.hasPrefix("Private Cloud Compute quota limit reached until 2027-01-15T08:00:00Z: "))
        // A model without vision gets placeholders instead of images.
        let segments = FoundationModelsResponder.segments([.image(ImageContent(data: Data([1, 2]), mimeType: "image/png"))], vision: false)
        guard case .text(let text)? = segments.first else {
            Issue.record("Expected a placeholder")
            return
        }
        #expect(text.content.contains("image omitted"))
    }

    @Test func availability() throws {
        guard #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) else { return }
        #expect(FoundationModelsProvider.Model.onDevice().isAvailable == SystemLanguageModel.default.isAvailable)
    }

    /// The iOS Simulator's Foundation Models reports no cached tokens, even within one session.
    var reportsCaching: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        true
        #endif
    }

    @Test func laterTurnsReadTheCache() async throws {
        guard #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) else { return }
        let mood = Document("test.mood", initial: FileNote(text: "Be brief."))
        let section = PromptSection("style") { input in try await input.document(mood).text }
        let weather = Tool(
            "get_weather", description: "Get the current weather for one city", parameters: .object(["city": .string("The city")])
        ) { (args: City, _) in "It is 31 degrees in \(args.city)." }
        let (harness, root) = try await setup(extensions: [
            Extension("assistant", tools: [weather], sections: [
                PromptSection("preamble", tag: false, text: String(repeating: "You are a careful, friendly assistant. ", count: 20)),
                section,
            ]),
        ])
        let first = try await withTimeout(60) { try await ask(root, "Name a fruit in one word.") }
        let second = try await withTimeout(60) { try await ask(root, "Name a vegetable in one word.") }
        // The second turn extends the first turn's session: everything before its prompt is cached. (The first turn
        // may read cached instructions already: Foundation Models caches those across sessions.)
        if reportsCaching {
            #expect(second.usage.cacheRead >= first.usage.input + first.usage.cacheRead)
            #expect(second.usage.input < 20)
        }

        // A tool round: the continuation after the tool results reads the cache too. (Foundation Models reports no
        // cached tokens for the request that ends at the tool call, though it reuses the session's cache.)
        let third = try await withTimeout(90) { try await ask(root, "What is the weather in Paris? Use get_weather.") }
        let toolRound = try await root.view().entries.compactMap(\.assistantMessage).suffix(2)
        #expect(toolRound.first?.stopReason == .toolUse)
        if reportsCaching {
            #expect(third.usage.cacheRead >= (toolRound.first?.usage.input ?? 1) + (toolRound.first?.usage.cacheRead ?? 0))
        }

        // A section change is appended in place: the conversation before it stays cached.
        try await root.update(mood) { $0.text = "Answer in lowercase." }
        let fourth = try await withTimeout(60) { try await ask(root, "Name a color in one word.") }
        if reportsCaching {
            #expect(fourth.usage.cacheRead >= third.usage.cacheRead)
        }
        try await harness.close()
    }

    @Test func answersMatchTheMessagesSentBack() throws {
        guard #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) else { return }
        let answer: JSONValue = [
            "text": "Let me check.", "thinking": "The user wants weather.",
            "toolCalls": [["id": "c1", "name": "get_weather", "argumentsJSON": #"{"unit": "c", "city": "Paris"}"#]],
        ]
        // As pi-durable stores and sends it back: metadata added, blocks in another order, arguments re-encoded.
        let sentBack: JSONValue = [
            "role": "assistant", "api": "foundation-models:apple", "provider": "apple", "model": "on-device",
            "stopReason": "toolUse", "timestamp": 1_700_000_000_000, "durationMs": 812,
            "usage": ["input": 300, "output": 12, "cacheRead": 0, "cacheWrite": 0, "totalTokens": 312],
            "content": [
                ["type": "text", "text": "Let me check."],
                ["type": "thinking", "thinking": "The user wants weather."],
                ["type": "toolCall", "id": "c1", "name": "get_weather", "arguments": ["city": "Paris", "unit": "c"]],
            ],
        ]
        #expect(FoundationModelsResponder.key(FoundationModelsResponder.assistant(from: answer)) == FoundationModelsResponder.key(sentBack))
        let user: JSONValue = ["role": "user", "content": "Hi", "timestamp": 1]
        let userBlocks: JSONValue = ["role": "user", "content": [["type": "text", "text": "Hi"]], "timestamp": 2]
        #expect(FoundationModelsResponder.key(user) == FoundationModelsResponder.key(userBlocks))
    }

    @Test func cacheRetentionNoneStartsFresh() async throws {
        guard #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) else { return }
        let models = Models(builtinProviders: false)
        try await models.register(FoundationModelsProvider())
        let harness = try await Harness.open(
            models: models, settings: Settings(stream: .init(cacheRetention: "none"), compaction: .forContextWindow(8192)))
        let root = try await harness.root(agent: AgentChange(model: .appleOnDevice))
        _ = try await withTimeout(60) { try await ask(root, "Name a fruit in one word.") }
        let second = try await withTimeout(60) { try await ask(root, "Name a vegetable in one word.") }
        #expect(second.usage.cacheRead == 0)
        try await harness.close()
    }

    @Test func builtinToolSchemasDecode() async throws {
        guard #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) else { return }
        let models = Models(builtinProviders: false)
        let harness = try await Harness.open(
            models: models, extensions: [.codingTools(shell: true), .toolSearch(), .codemode()])
        // Every tool the model can be offered; code mode's internal tools are only for scripts.
        for tool in try await harness.registry().tools.map(\.tool) where tool.callers.contains(.model) {
            _ = try FoundationModelsResponder.tool(["name": .string(tool.name), "description": .string(tool.description), "parameters": tool.parameters])
        }
        try await harness.close()
    }

    @Test func restatedPromptLeads() async throws {
        guard #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) else { return }
        // After a compaction, pi-durable restates the prompt after the run's first messages.
        let lookup: JSONValue = ["name": "lookup", "description": "Look up a fact", "parameters": ["type": "object", "properties": [:]]]
        let history: [JSONValue] = [
            ["role": "user", "content": "Summary of the conversation so far", "timestamp": 0],
            ["role": "system", "text": "Be brief.", "tools": [lookup], "first": true],
            ["role": "user", "content": "Hi", "timestamp": 0],
            ["role": "system", "text": "Updated system prompt section \"style\": Be warm.", "tools": []],
        ]
        let entries = try FoundationModelsResponder.transcript(for: history, vision: false)
        guard case .instructions(let instructions) = entries.first else { Issue.record("No leading instructions"); return }
        #expect(instructions.toolDefinitions.map(\.name) == ["lookup"])
        #expect(entries.count == 4)

        // A session with leading instructions declares its tools there, once.
        let session = LanguageModelSession(
            model: SystemLanguageModel.default, tools: [try FoundationModelsResponder.tool(lookup)], transcript: Transcript(entries: entries))
        let declared = session.transcript.compactMap { entry -> Int? in
            if case .instructions(let instructions) = entry { return instructions.toolDefinitions.count } else { return nil }
        }
        #expect(declared == [1, 0])
    }

    @Test func schemasDecode() throws {
        guard #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) else { return }
        let tool = try FoundationModelsResponder.tool([
            "name": "pick", "description": "Pick one",
            "parameters": [
                "type": "object", "x-order": ["value", "mode"],
                "properties": [
                    "value": ["title": "Value", "anyOf": [["type": "string"], ["type": "number"]]],
                    "mode": ["type": "string", "enum": ["a", "b"]],
                    "labels": ["type": "object", "additionalProperties": ["type": "string"]],
                ],
                "required": ["value"],
            ],
        ])
        #expect(tool.name == "pick")
    }
}
#endif
