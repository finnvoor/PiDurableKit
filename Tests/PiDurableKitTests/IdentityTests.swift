import Foundation
import Testing
@testable import PiDurableKit

/// How requests identify the app (pi-ai `ClientIdentity`): the runtime's ``Runtime/Client``, a harness's `identity`,
/// and a request's own, through OpenRouter, which reads attribution headers.
extension MockServerTests {
@Suite struct IdentityTests {
    static let answer: [String] = [
        .sse(#"{"id":"c1","object":"chat.completion.chunk","created":1,"model":"m","choices":[{"index":0,"delta":{"content":"Hi"},"finish_reason":"stop"}]}"#),
        "data: [DONE]\n\n",
    ]

    /// Models of a provider at OpenRouter's address, in a runtime of `client`.
    func models(_ client: Runtime.Client) async throws -> Models {
        MockServer.handle(host: "openrouter.ai") { _ in .init(chunks: Self.answer) }
        let runtime = Runtime(configuration: .init(urlSessionConfiguration: MockServer.configuration, client: client))
        let models = Models(builtinProviders: false, runtime: runtime)
        try await models.register(CustomProvider(
            id: "router", baseURL: URL(string: "https://openrouter.ai/api/v1")!, apiKey: "key", models: [.init(id: "m")]))
        return models
    }

    var lastRequest: MockServer.Request? { MockServer.requests(to: "openrouter.ai").last }

    @Test func harnessesAttributeRequestsToTheAppNotPi() async throws {
        // Without attribution of its own, the app sends none, rather than pi-durable's default attribution to pi.
        let plain = try await models(Runtime.Client(name: "Plain App", version: "1.0"))
        var harness = try await Harness.open(models: plain)
        var root = try await harness.root(agent: AgentChange(model: ModelRef(provider: "router", modelId: "m")))
        _ = try await ask(root, "Hi")
        var request = try #require(lastRequest)
        #expect(request.header("X-OpenRouter-Title") == nil)
        #expect(request.header("HTTP-Referer") == nil)
        #expect(request.header("User-Agent")?.hasPrefix("Plain-App/1.0 (") == true)
        try await harness.close()

        let attributed = try await models(Runtime.Client(
            name: "Example", version: "2.0",
            attribution: ClientAttribution(name: "Example", url: "https://example.com", categories: ["assistant"])))
        harness = try await Harness.open(models: attributed)
        root = try await harness.root(agent: AgentChange(model: ModelRef(provider: "router", modelId: "m")))
        _ = try await ask(root, "Hi")
        request = try #require(lastRequest)
        #expect(request.header("X-OpenRouter-Title") == "Example")
        #expect(request.header("HTTP-Referer") == "https://example.com")
        #expect(request.header("X-OpenRouter-Categories") == "assistant")
        try await harness.close()
    }

    @Test func aHarnessIdentityOverridesTheRuntimesForItsRequestsAndTools() async throws {
        let models = try await models(Runtime.Client(
            name: "Example", version: "2.0", attribution: ClientAttribution(name: "Example", url: "https://example.com")))
        let identity = ClientIdentity(userAgent: .custom("Harness/3"), attribution: .none)
        // A tool calling the model sees the harness's identity too (pi-durable's `api.models`).
        let summarize = Tool("summarize", description: "Asks the model") { context -> String in
            _ = try await context.models.complete(
                ModelRef(provider: "router", modelId: "m"), context: ModelContext(messages: [.user(UserMessage(content: [.text("Hi")]))]))
            return "asked"
        }
        let faux = FauxProvider()
        try await models.register(faux)
        try await faux.append(.toolCall("summarize", [:]))
        try await faux.append(.text("done"))
        let harness = try await Harness.open(models: models, extensions: [Extension("tools", tools: [summarize])], identity: identity)
        let root = try await harness.root(agent: AgentChange(model: ModelRef(provider: "router", modelId: "m")))
        _ = try await ask(root, "Hi")
        var request = try #require(lastRequest)
        #expect(request.header("User-Agent") == "Harness/3")
        #expect(request.header("X-OpenRouter-Title") == nil)

        try await root.configure(AgentChange(model: faux.model))
        _ = try await ask(root, "Use the tool")
        request = try #require(lastRequest)
        #expect(request.header("User-Agent") == "Harness/3")
        #expect(request.header("X-OpenRouter-Title") == nil)
        try await harness.close()

        // A direct request through the runtime's models identifies as the runtime, unless it says otherwise.
        let message = ModelContext(messages: [.user(UserMessage(content: [.text("Hi")]))])
        _ = try await models.complete(ModelRef(provider: "router", modelId: "m"), context: message)
        request = try #require(lastRequest)
        #expect(request.header("User-Agent")?.hasPrefix("Example/2.0 (") == true)
        #expect(request.header("X-OpenRouter-Title") == "Example")
        _ = try await models.complete(
            ModelRef(provider: "router", modelId: "m"), context: message,
            options: ModelOptions(identity: ClientIdentity(userAgent: .short)))
        request = try #require(lastRequest)
        #expect(request.header("User-Agent") == "pi")
        #expect(request.header("X-OpenRouter-Title") == "Example")
        _ = try await models.withIdentity(identity).complete(ModelRef(provider: "router", modelId: "m"), context: message)
        request = try #require(lastRequest)
        #expect(request.header("User-Agent") == "Harness/3")
    }
}
}
