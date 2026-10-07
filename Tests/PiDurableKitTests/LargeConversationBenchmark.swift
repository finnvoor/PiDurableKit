import Foundation
import Testing
@testable import PiDurableKit

/// Benchmarks for long conversations. Run with `BENCHMARK=1 swift test --filter LargeConversation`.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["BENCHMARK"] != nil)) struct LargeConversationBenchmark {
    static let sentence = "The quick brown fox jumps over the lazy dog while the agent explains durable state. "

    func seed(_ conversation: Conversation, pairs: Int) async throws {
        var remaining = pairs
        while remaining > 0 {
            let batch = min(remaining, 250)
            try await conversation.commit { tx in
                for index in 0..<batch {
                    let user = UserMessage(content: [.text("Question \(index): \(Self.sentence)")], timestamp: .now)
                    try await tx.append(EntryDraft(kind: .user, model: [.user(user)]), to: conversation.id)
                    let answer = AssistantMessage(content: [.text(String(repeating: Self.sentence, count: 4))])
                    try await tx.append(EntryDraft(kind: .assistant, model: [.assistant(answer)]), to: conversation.id)
                }
            }
            remaining -= batch
        }
    }

    /// A faux model with a context window large enough that the seeded transcript never triggers compaction.
    static func setup() async throws -> (Conversation, FauxProvider, Harness) {
        let models = Models(builtinProviders: false)
        let faux = FauxProvider(models: [.init(id: "faux-1", contextWindow: 100_000_000)], tokensPerSecond: 400)
        try await models.register(faux)
        let harness = try await Harness.open(models: models)
        return (try await harness.root(agent: AgentChange(model: faux.model)), faux, harness)
    }

    @Test(arguments: [0, 500, 2000, 5000])
    func viewUpdates(pairs: Int) async throws {
        let (root, faux, _) = try await Self.setup()
        try await seed(root, pairs: pairs)
        let clock = ContinuousClock()

        // A full view, as `views()` delivers one.
        let first = try await clock.measure { _ = try await root.view() }

        // Time from a commit to the view that includes it.
        var views = root.views().makeAsyncIterator()
        let initial = try #require(try await views.next())
        var latencies: [Duration] = []
        for index in 0..<10 {
            let start = clock.now
            _ = try await root.commit { tx in try await tx.append(EntryDraft(kind: "app.note", data: .number(Double(index))), to: root.id) }
            while let view = try await views.next(), view.entries.count <= initial.entries.count + index {}
            latencies.append(clock.now - start)
        }

        // Streaming: how often views arrive while a long reply streams, and how far behind they fall.
        try await faux.append(.text(String(repeating: Self.sentence, count: 40)))
        let streamStart = clock.now
        _ = try await root.submit("Go")
        var updates = 0
        var gaps: [Duration] = []
        var last = clock.now
        while let view = try await views.next() {
            updates += 1
            gaps.append(clock.now - last)
            last = clock.now
            if !view.isBusy && view.streamingMessage == nil && clock.now - streamStart > .milliseconds(200) { break }
        }
        let streamTime = clock.now - streamStart
        let sortedLatency = latencies.sorted()
        let maxGap = gaps.dropFirst().max() ?? .zero
        print(String(
            format: "BENCH pairs=%5d entries=%5d view() %7.1fms  commit→view median %6.1fms max %6.1fms  stream %5.2fs updates %3d (%.1f/s) max gap %6.1fms",
            pairs, initial.entries.count, first.ms, sortedLatency[sortedLatency.count / 2].ms, sortedLatency.last!.ms,
            streamTime.seconds, updates, Double(updates) / streamTime.seconds, maxGap.ms))
    }
}

extension Duration {
    var ms: Double { Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15 }
    var seconds: Double { ms / 1000 }
}

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["BENCHMARK"] != nil)) struct ViewCostBreakdown {
    @Test func breakdown() async throws {
        let setup = try await FauxSetup.make()
        let root = try await setup.root()
        try await LargeConversationBenchmark().seed(root, pairs: 2000)
        let clock = ContinuousClock()
        var data = Data()
        let raw = try await clock.measure {
            data = try await setup.harness.engine.callRaw("conversation.view", ["harness": setup.harness.id, "conversation": root.id])
        }
        let decode = try clock.measure { _ = try decodeJSON(ConversationView.self, from: data) }
        let parse = try clock.measure { _ = try JSONSerialization.jsonObject(with: data) }
        print(String(format: "BENCH 4000 entries: JS+bridge %.1fms, %d KB JSON, Swift decode %.1fms (JSONSerialization alone %.1fms)",
            raw.ms, data.count / 1024, decode.ms, parse.ms))
    }
}

