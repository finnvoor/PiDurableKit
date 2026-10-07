import Foundation
import Testing
@testable import PiDurableKit

/// OAuth sign-in through pi-ai's real Anthropic flow: PKCE, the loopback redirect server, the token exchange, and
/// automatic refresh. A scripted "browser" follows the redirect; the token endpoint and API are `MockServer`s.
extension MockServerTests {
@Suite struct LoginTests {
    static let runtime = Runtime(configuration: .init(urlSessionConfiguration: MockServer.configuration))

    /// A browser that signs in at once: it follows the authorization URL's redirect with a code, then stays on
    /// screen until the sign-in dismisses it.
    static func browser(
        code: String, extra: [URLQueryItem] = [], onAuthorize: @escaping @Sendable (URL) -> Void = { _ in },
        onRedirect: @escaping @Sendable (Int) -> Void = { _ in }
    ) -> LoginInteraction {
        LoginInteraction(presentSignInPage: { url in
            onAuthorize(url)
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let redirect = try #require(items.first { $0.name == "redirect_uri" }?.value)
            let state = try #require(items.first { $0.name == "state" }?.value)
            var callback = try #require(URLComponents(string: redirect))
            callback.queryItems = [URLQueryItem(name: "code", value: code), URLQueryItem(name: "state", value: state)] + extra
            let (_, response) = try await URLSession.shared.data(from: callback.url!)
            onRedirect((response as? HTTPURLResponse)?.statusCode ?? 0)
            while !Task.isCancelled { try await Task.sleep(for: .milliseconds(20)) }
        })
    }

    static func serveAnthropicMessages() {
        MockServer.handle(host: "api.anthropic.com") { _ in
            .init(chunks: [
                .sse(#"{"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","content":[],"model":"claude-haiku-4-5","stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":10,"output_tokens":1}}}"#, event: "message_start"),
                .sse(#"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#, event: "content_block_start"),
                .sse(#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Signed in"}}"#, event: "content_block_delta"),
                .sse(#"{"type":"content_block_stop","index":0}"#, event: "content_block_stop"),
                .sse(#"{"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":2}}"#, event: "message_delta"),
                .sse(#"{"type":"message_stop"}"#, event: "message_stop"),
            ])
        }
    }

    static func serveTokens(access: String, refresh: String) {
        MockServer.handle(host: "platform.claude.com") { _ in
            .init(
                headers: ["content-type": "application/json"],
                chunks: [#"{"access_token":"\#(access)","refresh_token":"\#(refresh)","expires_in":3600,"token_type":"Bearer"}"#])
        }
    }

    @Test func providersAdvertiseOAuth() async throws {
        let models = Models(runtime: Self.runtime)
        let providers = try await models.providers()
        let anthropic = try #require(providers.first { $0.id == .anthropic })
        #expect(anthropic.oauth?.isSubscription == true)
        #expect(providers.first { $0.id == .groq }?.oauth == nil)
    }

    @Test func anthropicBrowserSignIn() async throws {
        Self.serveTokens(access: "sk-ant-oat01-access-1", refresh: "refresh-1")
        Self.serveAnthropicMessages()
        let redirectStatus = Mutex(0)
        let events = Mutex<[LoginEvent]>([])

        let models = Models(runtime: Self.runtime)
        var browser = Self.browser(code: "the-code", onRedirect: { status in redirectStatus.set(status) })
        browser.notify = { event in events.update { $0.append(event) } }
        let interaction = browser
        try await withTimeout { try await models.login(to: .anthropic, interaction: interaction) }

        #expect(redirectStatus.get() == 200)
        #expect(events.get().contains { if case .authorizationURL = $0 { true } else { false } })
        let credential = try #require(try await models.credential(for: .anthropic))
        #expect(credential.kind == .oauth)
        #expect(credential.json["access"] == "sk-ant-oat01-access-1")
        #expect(credential.expiresAt.map { $0 > .now } == true)

        let tokenRequest = try #require(MockServer.requests(to: "platform.claude.com").last?.json)
        #expect(tokenRequest["grant_type"] == "authorization_code")
        #expect(tokenRequest["code"] == "the-code")
        #expect(tokenRequest["code_verifier"]?.stringValue?.isEmpty == false)

        let harness = try await Harness.open(models: models)
        let root = try await harness.root(agent: AgentChange(model: .anthropic("claude-haiku-4-5")))
        #expect(try await ask(root, "Hi").text == "Signed in")
        let apiRequest = try #require(MockServer.requests(to: "api.anthropic.com").last)
        #expect(apiRequest.header("Authorization") == "Bearer sk-ant-oat01-access-1")
        try await harness.close()

        try await models.logout(from: .anthropic)
        #expect(try await models.credential(for: .anthropic) == nil)
    }

    @Test func signInWithChatGPT() async throws {
        MockServer.handle(host: "auth.openai.com") { _ in
            .init(
                headers: ["content-type": "application/json"],
                chunks: [#"{"access_token":"chatgpt-access","refresh_token":"chatgpt-refresh","id_token":"id","expires_in":3600,"scope":"openid profile email offline_access resource.invoke chatgpt.tokens.use.direct","token_type":"Bearer"}"#])
        }
        NetworkTests.serveOpenAIResponses(text: "Hello from ChatGPT")
        let authorizeURL = Mutex<URL?>(nil)
        let installation = UUID()

        let models = Models(runtime: Self.runtime)
        let interaction = Self.browser(
            code: "chatgpt-code", extra: [URLQueryItem(name: "client_id", value: "issued-client")],
            onAuthorize: { authorizeURL.set($0) })
        try await withTimeout {
            try await models.login(to: .openAI, interaction: interaction, installationID: installation, agentName: "Example")
        }

        let authorize = try #require(authorizeURL.get().flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) })
        #expect(authorize.host == "auth.openai.com")
        #expect(authorize.queryItems?.first { $0.name == "ext_agent_host_id" }?.value == "urn:uuid:\(installation.uuidString.lowercased())")
        #expect(authorize.queryItems?.first { $0.name == "redirect_uri" }?.value == "http://127.0.0.1:1455/auth/callback")
        // The name OpenAI's sign-in page suggests for the app.
        #expect(authorize.queryItems?.first { $0.name == "agent_name_hint" }?.value == "Example")

        let tokenRequest = try #require(MockServer.requests(to: "auth.openai.com").last)
        let form = URLComponents(string: "?" + String(decoding: tokenRequest.body, as: UTF8.self))?.queryItems ?? []
        #expect(form.first { $0.name == "client_id" }?.value == "issued-client")
        #expect(form.first { $0.name == "code" }?.value == "chatgpt-code")

        let credential = try #require(try await models.credential(for: .openAI))
        #expect(credential.kind == .oauth)
        #expect(credential.json["clientId"] == "issued-client")

        let harness = try await Harness.open(models: models)
        let root = try await harness.root(agent: AgentChange(model: .openAI("gpt-5")))
        #expect(try await ask(root, "Hi").text == "Hello from ChatGPT")
        #expect(MockServer.requests(to: "api.openai.com").contains { $0.header("Authorization") == "Bearer chatgpt-access" })
        try await harness.close()
    }

    @Test func expiredTokensRefreshBeforeRequests() async throws {
        Self.serveTokens(access: "sk-ant-oat01-access-2", refresh: "refresh-2")
        Self.serveAnthropicMessages()
        let store = InMemoryCredentialStore([
            .anthropic: .oauth(accessToken: "stale", refreshToken: "refresh-1", expiresAt: .now.addingTimeInterval(-60))
        ])
        let models = Models(credentials: store, runtime: Self.runtime)
        let harness = try await Harness.open(models: models)
        let root = try await harness.root(agent: AgentChange(model: .anthropic("claude-haiku-4-5")))
        #expect(try await ask(root, "Hi").text == "Signed in")

        let refresh = try #require(MockServer.requests(to: "platform.claude.com").last?.json)
        #expect(refresh["grant_type"] == "refresh_token")
        #expect(refresh["refresh_token"] == "refresh-1")
        #expect(MockServer.requests(to: "api.anthropic.com").last?.header("Authorization") == "Bearer sk-ant-oat01-access-2")
        #expect(await store.credential(for: .anthropic)?.json["refresh"] == "refresh-2")
        try await harness.close()
    }

    @Test func dismissingTheSignInPageCancels() async throws {
        let models = Models(runtime: Self.runtime)
        struct Dismissed: Error {}
        let interaction = LoginInteraction(presentSignInPage: { _ in throw Dismissed() })
        await #expect(throws: (any Error).self) {
            try await withTimeout { try await models.login(to: .anthropic, interaction: interaction) }
        }
        #expect(try await models.credential(for: .anthropic) == nil)
        // The redirect port is free again for the next sign-in.
        Self.serveTokens(access: "access-3", refresh: "refresh-3")
        try await withTimeout { try await models.login(to: .anthropic, interaction: Self.browser(code: "again")) }
        #expect(try await models.credential(for: .anthropic)?.json["access"] == "access-3")
    }

    @Test func cancellingTheTaskCancels() async throws {
        let models = Models(runtime: Self.runtime)
        let presented = Mutex(false)
        let interaction = LoginInteraction(presentSignInPage: { _ in
            presented.set(true)
            while !Task.isCancelled { try await Task.sleep(for: .milliseconds(20)) }
        })
        let login = Task { try await models.login(to: .anthropic, interaction: interaction) }
        try await withTimeout {
            while !presented.get() { try await Task.sleep(for: .milliseconds(20)) }
        }
        login.cancel()
        await #expect(throws: (any Error).self) { try await withTimeout { try await login.value } }
    }

    @Test func keychainStoreRoundTrips() async throws {
        let store = KeychainCredentialStore(service: "PiDurableKitTests.\(UUID().uuidString)")
        do {
            try store.setCredential(.apiKey("sk-1"), for: .openAI)
        } catch let error as KeychainError where error.status == errSecMissingEntitlement {
            // Test runners are unsigned and have no keychain access group; signed apps do.
            return
        }
        #expect(try store.credential(for: .openAI)?.apiKey == "sk-1")
        try store.setCredential(.oauth(accessToken: "a", refreshToken: "r", expiresAt: .now), for: .anthropic)
        #expect(try store.providers() == [.anthropic, .openAI])
        try store.setCredential(nil, for: .openAI)
        try store.setCredential(nil, for: .anthropic)
        #expect(try store.providers().isEmpty)
    }
}
}

/// A tiny lock for test bookkeeping.
final class Mutex<Value: Sendable>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.withLock { value } }
    func set(_ newValue: Value) { lock.withLock { value = newValue } }
    func update(_ body: (inout Value) -> Void) { lock.withLock { body(&value) } }
}
