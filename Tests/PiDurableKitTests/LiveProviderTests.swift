import Foundation
import Testing
@testable import PiDurableKit

/// Real requests to real providers, so changes in their APIs or SDKs show up even though every other test uses mocks.
/// They run only when the provider's key is in the environment (CI passes them from repository secrets).
@Suite struct LiveProviderTests {
    static let environment = ProcessInfo.processInfo.environment

    /// A key from the environment; CI sets unset secrets to an empty string.
    static func key(_ name: String) -> String? {
        environment[name].flatMap { $0.isEmpty ? nil : $0 }
    }

    static func run(provider: ProviderID, model: String, key: String) async throws {
        let models = Models(credentials: InMemoryCredentialStore([provider: .apiKey(key)]))
        let echo = Tool("echo", description: "Echo the given word back", parameters: .object(["word": .string])) {
            (arguments: [String: String], _) in arguments["word"] ?? ""
        }
        let harness = try await Harness.open(models: models, extensions: [Extension("live", tools: [echo])])
        let root = try await harness.root(agent: AgentChange(
            model: ModelRef(provider: provider, modelId: model),
            instructions: "Call the echo tool with the word 'pong', then answer with exactly the word it returned."))
        let answer = try await withTimeout(120) { try await ask(root, "Go") }
        #expect(answer.text.lowercased().contains("pong"), "\(answer.text) \(answer.errorMessage ?? "")")
        #expect(try await root.view().entries.contains { $0.toolResult?.text == "pong" })
        #expect(answer.usage.totalTokens > 0)
        try await harness.close()
    }

    @Test(.enabled(if: key("ANTHROPIC_API_KEY") != nil)) func anthropic() async throws {
        try await Self.run(provider: .anthropic, model: "claude-haiku-4-5", key: Self.key("ANTHROPIC_API_KEY")!)
    }

    @Test(.enabled(if: key("OPENAI_API_KEY") != nil)) func openAI() async throws {
        try await Self.run(provider: .openAI, model: "gpt-5-mini", key: Self.key("OPENAI_API_KEY")!)
    }
}
