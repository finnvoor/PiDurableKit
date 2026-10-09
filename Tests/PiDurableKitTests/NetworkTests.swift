import Foundation
import Testing
@testable import PiDurableKit

/// End-to-end requests through the real pi-ai provider implementations and their SDKs, served by `MockServer`.
/// These exercise `fetch()`, streaming bodies, `TextDecoder`, `ReadableStream`, and `AbortController` in JavaScriptCore.
extension MockServerTests {
@Suite struct NetworkTests {
    static let runtime = Runtime(configuration: .init(urlSessionConfiguration: MockServer.configuration))

    @Test func openAICompatibleProvider() async throws {
        MockServer.handle(host: "local.test") { _ in
            func chunk(_ delta: String, finish: String? = nil) -> String {
                let finishJSON = finish.map { "\"\($0)\"" } ?? "null"
                return .sse(
                    #"{"id":"c1","object":"chat.completion.chunk","created":1,"model":"local-model","choices":[{"index":0,"delta":{"content":"\#(delta)"},"finish_reason":\#(finishJSON)}]}"#
                )
            }
            return .init(chunks: [
                chunk("Hello"), chunk(" from"), chunk(" the server", finish: "stop"),
                .sse(#"{"id":"c1","object":"chat.completion.chunk","created":1,"model":"local-model","choices":[],"usage":{"prompt_tokens":12,"completion_tokens":4,"total_tokens":16}}"#),
                "data: [DONE]\n\n",
            ])
        }

        let models = Models(builtinProviders: false, runtime: Self.runtime)
        try await models.register(CustomProvider(
            id: "local", baseURL: URL(string: "https://local.test/v1")!, apiKey: "secret",
            models: [.init(id: "local-model")]))
        let harness = try await Harness.open(models: models)
        let root = try await harness.root(agent: AgentChange(model: ModelRef(provider: "local", modelId: "local-model")))
        let answer = try await ask(root, "Hi")
        #expect(answer.text == "Hello from the server")
        #expect(answer.usage.input == 12)

        let request = try #require(MockServer.requests(to: "local.test").last)
        #expect(request.url.path() == "/v1/chat/completions")
        #expect(request.header("Authorization") == "Bearer secret")
        #expect(request.json?["model"] == "local-model")
        #expect(request.json?["stream"] == true)
        try await harness.close()
    }

    @Test func requestsUseTheConfiguredIdleTimeout() async throws {
        let completion = #"{"id":"c1","object":"chat.completion.chunk","created":1,"model":"m","choices":[{"index":0,"delta":{"content":"Hi"},"finish_reason":"stop"}]}"#
        MockServer.handle(host: "idle.test") { _ in .init(chunks: [.sse(completion), "data: [DONE]\n\n"]) }
        for (configured, expected) in [(nil, 300.0), (42.0, 42.0)] as [(Double?, Double)] {
            var configuration = Runtime.Configuration(urlSessionConfiguration: MockServer.configuration)
            if let configured { configuration.requestIdleTimeout = configured }
            let models = Models(builtinProviders: false, runtime: Runtime(configuration: configuration))
            try await models.register(CustomProvider(
                id: "idle", baseURL: URL(string: "https://idle.test/v1")!, apiKey: "key", models: [.init(id: "m")]))
            let harness = try await Harness.open(models: models)
            let root = try await harness.root(agent: AgentChange(model: ModelRef(provider: "idle", modelId: "m")))
            _ = try await ask(root, "Hi")
            #expect(MockServer.requests(to: "idle.test").last?.timeout == expected)
            try await harness.close()
        }
    }

    @Test func providerAndModelHeaders() async throws {
        let completion = #"{"id":"c1","object":"chat.completion.chunk","created":1,"model":"m","choices":[{"index":0,"delta":{"content":"Hi"},"finish_reason":"stop"}]}"#
        MockServer.handle(host: "headers.test") { _ in .init(chunks: [.sse(completion), "data: [DONE]\n\n"]) }
        MockServer.handle(host: "anthropic.headers.test") { _ in
            .init(chunks: [
                .sse(#"{"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","content":[],"model":"claude","stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":1,"output_tokens":1}}}"#, event: "message_start"),
                .sse(#"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#, event: "content_block_start"),
                .sse(#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}"#, event: "content_block_delta"),
                .sse(#"{"type":"content_block_stop","index":0}"#, event: "content_block_stop"),
                .sse(#"{"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":1}}"#, event: "message_delta"),
                .sse(#"{"type":"message_stop"}"#, event: "message_stop"),
            ])
        }
        let models = Models(builtinProviders: false, runtime: Self.runtime)
        try await models.register(CustomProvider(
            id: "gateway", baseURL: URL(string: "https://headers.test/v1")!, apiKey: "key",
            headers: ["X-Tenant": "acme", "X-Shared": "provider"],
            models: [
                .init(id: "chat", headers: ["X-Shared": "model"], compat: ["supportsDeveloperRole": false]),
                .init(id: "claude", api: .anthropicMessages, baseURL: URL(string: "https://anthropic.headers.test")!),
            ]))
        let listed = try await models.models(for: "gateway")
        #expect(Set(listed.map(\.api)) == ["openai-completions", "anthropic-messages"])

        let harness = try await Harness.open(models: models)
        let root = try await harness.root(agent: AgentChange(model: ModelRef(provider: "gateway", modelId: "chat")))
        #expect(try await ask(root, "Hi").text == "Hi")
        let request = try #require(MockServer.requests(to: "headers.test").last)
        #expect(request.header("X-Tenant") == "acme")
        #expect(request.header("X-Shared") == "model")

        try await root.configure(AgentChange(model: ModelRef(provider: "gateway", modelId: "claude")))
        #expect(try await ask(root, "Hi again").text == "Hello")
        let anthropic = try #require(MockServer.requests(to: "anthropic.headers.test").last)
        #expect(anthropic.url.path() == "/v1/messages")
        #expect(anthropic.header("X-Tenant") == "acme")
        #expect(anthropic.header("X-Shared") == "provider")
        try await harness.close()
    }

    @Test func anthropicBuiltinProvider() async throws {
        MockServer.handle(host: "api.anthropic.com") { _ in
            .init(chunks: [
                .sse(#"{"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","content":[],"model":"claude-haiku-4-5","stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":10,"output_tokens":1}}}"#, event: "message_start"),
                .sse(#"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#, event: "content_block_start"),
                .sse(#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Bonjour"}}"#, event: "content_block_delta"),
                .sse(#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" à tous"}}"#, event: "content_block_delta"),
                .sse(#"{"type":"content_block_stop","index":0}"#, event: "content_block_stop"),
                .sse(#"{"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":5}}"#, event: "message_delta"),
                .sse(#"{"type":"message_stop"}"#, event: "message_stop"),
            ])
        }

        let models = Models(credentials: InMemoryCredentialStore([.anthropic: .apiKey("sk-ant-test")]), runtime: Self.runtime)
        #expect(try await models.credential(for: .anthropic)?.apiKey == "sk-ant-test")
        #expect(try await models.models(for: .anthropic).contains { $0.modelId == "claude-haiku-4-5" })
        let harness = try await Harness.open(models: models)
        let root = try await harness.root(agent: AgentChange(model: .anthropic("claude-haiku-4-5")))
        let answer = try await ask(root, "Say hello in French")
        #expect(answer.text == "Bonjour à tous")
        #expect(answer.provider == .anthropic)

        // Login tests also talk to this host in parallel; find this test's request by its key.
        let request = try #require(MockServer.requests(to: "api.anthropic.com").first { $0.header("x-api-key") == "sk-ant-test" })
        #expect(request.url.path() == "/v1/messages")
        try await harness.close()
    }

    static func serveOpenAIResponses(text: String) {
        MockServer.handle(host: "api.openai.com") { _ in
            let item = #"{"id":"msg_1","type":"message","status":"in_progress","role":"assistant","content":[]}"#
            let done = #"{"id":"msg_1","type":"message","status":"completed","role":"assistant","content":[{"type":"output_text","text":"\#(text)","annotations":[]}]}"#
            let response = { (status: String, output: String) in
                #"{"id":"resp_1","object":"response","created_at":1,"status":"\#(status)","model":"gpt-4.1","output":\#(output),"usage":{"input_tokens":7,"output_tokens":2,"total_tokens":9,"input_tokens_details":{"cached_tokens":0},"output_tokens_details":{"reasoning_tokens":0}}}"#
            }
            return .init(chunks: [
                .sse(#"{"type":"response.created","sequence_number":0,"response":\#(response("in_progress", "[]"))}"#, event: "response.created"),
                .sse(#"{"type":"response.output_item.added","sequence_number":1,"output_index":0,"item":\#(item)}"#, event: "response.output_item.added"),
                .sse(#"{"type":"response.content_part.added","sequence_number":2,"item_id":"msg_1","output_index":0,"content_index":0,"part":{"type":"output_text","text":"","annotations":[]}}"#, event: "response.content_part.added"),
                .sse(#"{"type":"response.output_text.delta","sequence_number":3,"item_id":"msg_1","output_index":0,"content_index":0,"delta":"\#(text)"}"#, event: "response.output_text.delta"),
                .sse(#"{"type":"response.output_item.done","sequence_number":5,"output_index":0,"item":\#(done)}"#, event: "response.output_item.done"),
                .sse(#"{"type":"response.completed","sequence_number":6,"response":\#(response("completed", "[" + done + "]"))}"#, event: "response.completed"),
            ])
        }
    }

    @Test func openAIResponsesBuiltinProvider() async throws {
        Self.serveOpenAIResponses(text: "Hi there")
        let models = Models(credentials: InMemoryCredentialStore([.openAI: .apiKey("sk-test")]), runtime: Self.runtime)
        let harness = try await Harness.open(models: models)
        let root = try await harness.root(agent: AgentChange(model: .openAI("gpt-4.1")))
        let answer = try await ask(root, "Hello")
        #expect(answer.text == "Hi there")
        let request = try #require(MockServer.requests(to: "api.openai.com").last)
        #expect(request.url.path() == "/v1/responses")
        #expect(request.header("Authorization") == "Bearer sk-test")
        try await harness.close()
    }

    @Test func abortingCancelsTheStreamingRequest() async throws {
        MockServer.handle(host: "slow.test") { _ in
            var chunks: [String] = []
            for index in 0..<2000 {
                chunks.append(.sse(#"{"id":"c1","object":"chat.completion.chunk","created":1,"model":"m","choices":[{"index":0,"delta":{"content":"\#(index) "},"finish_reason":null}]}"#))
            }
            return .init(chunks: chunks)
        }
        let models = Models(builtinProviders: false, runtime: Self.runtime)
        try await models.register(CustomProvider(
            id: "slow", baseURL: URL(string: "https://slow.test/v1")!, models: [.init(id: "m")]))
        let harness = try await Harness.open(models: models)
        let root = try await harness.root(agent: AgentChange(model: ModelRef(provider: "slow", modelId: "m")))
        let submission = try await root.submit("Count forever")
        try await withTimeout(5) {
            for try await view in root.views() {
                if !(view.streamingMessage?.text.isEmpty ?? true) { break }
                if !view.isBusy, view.entries.count > 1 { Issue.record("Run ended early: \(view.entries.last!.text) \(String(describing: view.entries.last?.assistantMessage?.errorMessage))"); break }
            }
        }
        try await withTimeout { try await root.abort() }
        let record = try await submission.wait()
        guard case .unanswered(_, let reason, _) = record.status else {
            Issue.record("Expected unanswered, got \(record.status)")
            return
        }
        #expect(reason == "aborted")
        let aborted = try #require(try await root.view().entries.last?.assistantMessage)
        #expect(aborted.stopReason == .aborted)
        #expect(!aborted.text.isEmpty)
        try await harness.close()
    }

    @Test func httpErrorsBecomeUnansweredInputs() async throws {
        MockServer.handle(host: "broken.test") { _ in
            .init(status: 401, headers: ["content-type": "application/json"], chunks: [#"{"error":{"message":"bad key","type":"invalid_request_error"}}"#])
        }
        let models = Models(builtinProviders: false, runtime: Self.runtime)
        try await models.register(CustomProvider(
            id: "broken", baseURL: URL(string: "https://broken.test/v1")!, apiKey: "nope", models: [.init(id: "m")]))
        let harness = try await Harness.open(models: models, settings: Settings(retry: .init(enabled: false)))
        let root = try await harness.root(agent: AgentChange(model: ModelRef(provider: "broken", modelId: "m")))
        let error = await #expect(throws: Unanswered.self) {
            _ = try await ask(root, "Hi")
        }
        let status = String(describing: error?.record.status)
        #expect(status.contains("401") || status.contains("bad key"))
        try await harness.close()
    }
}
}
