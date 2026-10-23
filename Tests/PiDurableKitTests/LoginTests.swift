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

    /// Without an `agentName`, a sign-in introduces the app by its client name.
    @Test func signInWithChatGPTUsesTheClientName() async throws {
        MockServer.handle(host: "auth.openai.com") { _ in
            .init(
                headers: ["content-type": "application/json"],
                chunks: [#"{"access_token":"chatgpt-access","refresh_token":"chatgpt-refresh","id_token":"id","expires_in":3600,"scope":"openid profile email offline_access resource.invoke chatgpt.tokens.use.direct","token_type":"Bearer"}"#])
        }
        let authorizeURL = Mutex<URL?>(nil)
        let runtime = Runtime(configuration: .init(
            urlSessionConfiguration: MockServer.configuration, client: .init(name: "Example", version: "2.1")))
        let models = Models(runtime: runtime)
        let interaction = Self.browser(
            code: "chatgpt-code", extra: [URLQueryItem(name: "client_id", value: "issued-client")],
            onAuthorize: { authorizeURL.set($0) })
        try await withTimeout {
            try await models.login(to: .openAI, interaction: interaction, installationID: UUID())
        }
        let authorize = try #require(authorizeURL.get().flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) })
        #expect(authorize.queryItems?.first { $0.name == "agent_name_hint" }?.value == "Example")
    }

    /// A custom provider's browser sign-in: the authorization page with PKCE and the client's settings, its redirect
    /// caught on the loopback port, and the code exchanged at the token URL.
    @Test func customProviderBrowserSignIn() async throws {
        MockServer.handle(host: "auth.custom.test") { _ in
            .init(
                headers: ["content-type": "application/json"],
                chunks: [#"{"access_token":"custom-access","refresh_token":"custom-refresh","expires_in":3600}"#])
        }
        let authorizeURL = Mutex<URL?>(nil)
        let models = Models(builtinProviders: false, runtime: Self.runtime)
        try await models.register(CustomProvider(
            id: "custom", name: "Custom", baseURL: URL(string: "https://api.custom.test/v1")!,
            oauth: .init(
                signIn: .browser(
                    authorizationURL: URL(string: "https://auth.custom.test/authorize")!,
                    redirectURI: URL(string: "http://localhost:51234/callback")!),
                tokenURL: URL(string: "https://auth.custom.test/token")!, clientID: "custom-client", scope: "chat offline",
                parameters: ["prompt": "consent"], format: .json),
            models: [.init(id: "m")]))
        #expect(try await models.providers().first?.oauth != nil)

        let interaction = Self.browser(code: "custom-code", onAuthorize: { authorizeURL.set($0) })
        try await withTimeout { try await models.login(to: "custom", interaction: interaction) }

        let authorize = try #require(authorizeURL.get().flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) })
        let query = Dictionary(uniqueKeysWithValues: (authorize.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(authorize.host == "auth.custom.test" && authorize.path == "/authorize")
        #expect(query["client_id"] == "custom-client")
        #expect(query["scope"]?.replacingOccurrences(of: "+", with: " ") == "chat offline")
        #expect(query["redirect_uri"] == "http://localhost:51234/callback")
        #expect(query["code_challenge_method"] == "S256")
        #expect(query["prompt"] == "consent")

        let exchange = try #require(MockServer.requests(to: "auth.custom.test").last)
        #expect(exchange.json?["grant_type"] == "authorization_code")
        #expect(exchange.json?["code"] == "custom-code")
        #expect(exchange.json?["client_id"] == "custom-client")
        #expect(exchange.json?["state"] == JSONValue.string(query["state"] ?? ""))
        let credential = try #require(try await models.credential(for: "custom"))
        #expect(credential.kind == .oauth)
        #expect(credential.json["access"] == "custom-access")
        #expect(credential.json["refresh"] == "custom-refresh")
    }

    /// A custom provider's device-code sign-in: the code reported to the app, then the token URL polled until it
    /// stops saying `authorization_pending`.
    @Test func customProviderDeviceCodeSignIn() async throws {
        let polls = Mutex(0)
        MockServer.handle(host: "device.custom.test") { request in
            if request.url.path() == "/device" {
                return .init(
                    headers: ["content-type": "application/json"],
                    chunks: [#"{"device_code":"dev-1","user_code":"ABCD-EFGH","verification_uri":"https://device.custom.test/activate","interval":1,"expires_in":60}"#])
            }
            polls.update { $0 += 1 }
            let attempt = polls.get()
            if attempt == 1 {
                return .init(status: 400, headers: ["content-type": "application/json"], chunks: [#"{"error":"authorization_pending"}"#])
            }
            return .init(
                headers: ["content-type": "application/json"],
                chunks: [#"{"access_token":"device-access","refresh_token":"device-refresh","expires_in":3600}"#])
        }
        let reported = Mutex<String?>(nil)
        let models = Models(builtinProviders: false, runtime: Self.runtime)
        try await models.register(CustomProvider(
            id: "device", baseURL: URL(string: "https://api.custom.test/v1")!,
            oauth: .init(
                signIn: .deviceCode(deviceAuthorizationURL: URL(string: "https://device.custom.test/device")!),
                tokenURL: URL(string: "https://device.custom.test/token")!, clientID: "device-client", scope: "chat"),
            models: [.init(id: "m")]))
        let interaction = LoginInteraction(
            presentSignInPage: { _ in while !Task.isCancelled { try await Task.sleep(for: .milliseconds(20)) } },
            notify: { event in if case .deviceCode(let code, _) = event { reported.set(code) } })
        try await withTimeout(20) { try await models.login(to: "device", interaction: interaction) }

        #expect(reported.get() == "ABCD-EFGH")
        let requests = MockServer.requests(to: "device.custom.test")
        let device = try #require(requests.first { $0.url.path() == "/device" })
        let deviceForm = URLComponents(string: "?" + String(decoding: device.body, as: UTF8.self))?.queryItems ?? []
        #expect(deviceForm.first { $0.name == "client_id" }?.value == "device-client")
        let poll = try #require(requests.last { $0.url.path() == "/token" })
        let pollForm = URLComponents(string: "?" + String(decoding: poll.body, as: UTF8.self))?.queryItems ?? []
        #expect(pollForm.first { $0.name == "grant_type" }?.value == "urn:ietf:params:oauth:grant-type:device_code")
        #expect(pollForm.first { $0.name == "device_code" }?.value == "dev-1")
        #expect(polls.get() == 2)
        #expect(try await models.credential(for: "device")?.json["access"] == "device-access")
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

    /// Two requests that both find the token expiring: the first refreshes it, and the second, waiting its turn,
    /// finds it fresh and leaves it as it is (it used to be deleted, signing the person out).
    @Test func concurrentRequestsKeepTheRefreshedToken() async throws {
        // A slow token endpoint, so the second request asks while the first is refreshing.
        MockServer.handle(host: "platform.claude.com") { _ in
            Thread.sleep(forTimeInterval: 0.5)
            return .init(
                headers: ["content-type": "application/json"],
                chunks: [#"{"access_token":"sk-ant-oat01-access-4","refresh_token":"refresh-4","expires_in":3600,"token_type":"Bearer"}"#])
        }
        let refreshesBefore = MockServer.requests(to: "platform.claude.com").count
        let store = InMemoryCredentialStore([
            .anthropic: .oauth(accessToken: "stale", refreshToken: "refresh-1", expiresAt: .now.addingTimeInterval(-60))
        ])
        let models = Models(credentials: store, runtime: Self.runtime)
        async let one = models.isConfigured(.anthropic)
        async let two = models.isConfigured(.anthropic)
        #expect(try await [one, two] == [true, true])
        #expect(MockServer.requests(to: "platform.claude.com").count - refreshesBefore == 1)
        #expect(await store.credential(for: .anthropic)?.json["refresh"] == "refresh-4")
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
