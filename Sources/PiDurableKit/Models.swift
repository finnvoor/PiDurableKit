import Foundation
import os

/// Model access for harnesses: a pi-ai `Models` collection of providers and their credentials.
///
/// ```swift
/// let models = Models(credentials: .keychain)
/// try await models.setAPIKey(anthropicKey, for: .anthropic)
/// let harness = try await Harness.open(.sqlite(at: url), models: models)
/// ```
///
/// Every built-in pi-ai provider is registered by default (Anthropic, OpenAI, Google, OpenRouter, …). There are no
/// environment variables on iOS, so store each provider's credential in ``credentials`` (or with
/// ``setAPIKey(_:for:)``), or sign in to a subscription with ``login(to:interaction:installationID:agentName:)``.
public final class Models: Sendable {
    let runtime: Runtime
    let id: Int
    /// Where API keys and OAuth tokens are kept.
    public let credentials: any CredentialStore
    private let ready: Task<Void, Error>

    /// - Parameters:
    ///   - credentials: Where credentials are kept. Use ``KeychainCredentialStore`` (`.keychain`) so OAuth sign-ins
    ///     survive relaunches.
    ///   - builtinProviders: Whether to register every built-in pi-ai provider.
    ///   - runtime: The JavaScript runtime the models live in; a harness must use the same runtime.
    public init(
        credentials: any CredentialStore = InMemoryCredentialStore(),
        builtinProviders: Bool = true,
        runtime: Runtime = .shared
    ) {
        self.runtime = runtime
        self.credentials = credentials
        let engine = runtime.engine
        let id = Self.makeID()
        self.id = id
        engine.host.setCredentialStore(credentials, models: id)
        ready = Task {
            try await engine.perform("models.create", ["id": id, "builtin": builtinProviders])
        }
    }

    deinit {
        let engine = runtime.engine
        let id = id
        engine.send("models.dispose", ["id": id])
        engine.host.removeModels(id)
    }

    private static let counter = OSAllocatedUnfairLock(initialState: 0)

    private static func makeID() -> Int {
        counter.withLock { value in
            value += 1
            return value
        }
    }

    func call<Result: Decodable & Sendable>(_ method: String, _ arguments: BridgeArguments = [:]) async throws -> Result {
        try await ready.value
        var arguments = arguments
        arguments["id"] = id
        return try await runtime.engine.call(method, arguments)
    }

    func perform(_ method: String, _ arguments: BridgeArguments = [:]) async throws {
        let _: JSONValue = try await call(method, arguments)
    }

    /// Waits until the collection exists in JavaScript; rethrows a failure to create it.
    func prepare() async throws {
        try await ready.value
    }

    /// Stores (or with `nil`, removes) the API key of a provider.
    public func setAPIKey(_ key: String?, for provider: ProviderID) async throws {
        try await perform("models.setAPIKey", ["provider": provider, "key": key])
    }

    /// The registered providers.
    public func providers() async throws -> [ProviderInfo] {
        try await call("models.providers")
    }

    /// The chat models of one provider, or of every provider.
    public func models(for provider: ProviderID? = nil) async throws -> [ModelInfo] {
        try await call("models.list", ["provider": provider])
    }

    /// Signs in to a provider with OAuth, such as a Claude Pro/Max or ChatGPT subscription, GitHub Copilot, or
    /// OpenRouter, and stores the tokens in ``credentials``. Requests refresh them automatically from then on.
    ///
    /// ```swift
    /// try await models.login(to: .anthropic, interaction: .webAuthenticationSession())
    /// ```
    ///
    /// Throws `CancellationError` (or ``PiDurableError/cancelled``) when the user dismisses the sign-in page.
    /// Providers that support sign-in report it in ``ProviderInfo/oauth``.
    ///
    /// - Parameters:
    ///   - provider: The provider to sign in to.
    ///   - interaction: How the sign-in talks to the user.
    ///   - installationID: A stable ID of this app installation. Sign in with ChatGPT registers it with OpenAI as the
    ///     agent host. Defaults to ``Models/installationID``.
    ///   - agentName: How the app introduces itself to providers whose sign-in pages show it, such as OpenAI's. Defaults
    ///     to pi-ai's ("pi").
    public func login(
        to provider: ProviderID, interaction: LoginInteraction, installationID: UUID = Models.installationID,
        agentName: String? = nil
    ) async throws {
        try await ready.value
        let engine = runtime.engine
        let session = LoginSession(interaction: interaction) { [engine] in engine.loopbackRequests.withLock { $0 } }
        let login = engine.host.registerLogin(session)
        defer {
            session.finish()
            engine.host.removeLogin(login)
        }
        let id = id
        let task = Task {
            try await engine.perform(
                "models.login",
                [
                    "id": id, "provider": provider, "login": login, "deviceId": installationID.uuidString.lowercased(),
                    "agentName": agentName,
                ])
        }
        session.onAbandon { task.cancel() }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// A random ID created on first use and kept in `UserDefaults.standard`, identifying this app installation to
    /// providers that ask for one (Sign in with ChatGPT).
    public static var installationID: UUID {
        let key = "PiDurableKit.installationID"
        if let stored = UserDefaults.standard.string(forKey: key).flatMap(UUID.init(uuidString:)) { return stored }
        let id = UUID()
        UserDefaults.standard.set(id.uuidString, forKey: key)
        return id
    }

    /// Removes the stored credential of a provider.
    public func logout(from provider: ProviderID) async throws {
        try await perform("models.logout", ["provider": provider])
    }

    /// The stored credential of a provider.
    public func credential(for provider: ProviderID) async throws -> Credential? {
        try await credentials.credential(for: provider)
    }

    /// Reloads model catalogs of dynamic providers (OpenRouter, llama.cpp, …). Static built-in catalogs don't change.
    ///
    /// - Parameters:
    ///   - providers: Only these providers; all by default.
    ///   - allowNetwork: `false` restores stored catalogs without network access.
    ///   - force: Bypass the providers' freshness checks.
    @discardableResult
    public func refresh(providers: [ProviderID]? = nil, allowNetwork: Bool? = nil, force: Bool? = nil) async throws -> RefreshResult {
        try await call("models.refresh", ["providers": providers, "allowNetwork": allowNetwork, "force": force])
    }

    /// Registers a custom provider, such as a local Ollama or LM Studio server, or a proxy.
    public func register(_ provider: CustomProvider) async throws {
        try await perform("models.addProvider", ["provider": provider])
    }

    /// Registers a scripted provider for tests, previews, and demos.
    public func register(_ faux: FauxProvider) async throws {
        try await perform(
            "models.addFaux",
            [
                "provider": faux.id,
                "models": faux.models,
                "tokensPerSecond": faux.tokensPerSecond,
            ])
        faux.attach(to: self)
    }
}

/// A registered provider.
public struct ProviderInfo: Decodable, Sendable, Hashable, Identifiable {
    public let id: ProviderID
    public let name: String
    /// The provider's OAuth sign-in, if it has one; see ``Models/login(to:interaction:installationID:agentName:)``.
    public let oauth: OAuthInfo?
}

/// A chat model of a provider's catalog.
public struct ModelInfo: Decodable, Sendable, Hashable, Identifiable {
    public var id: String { "\(provider)/\(modelId)" }
    public let provider: ProviderID
    public let modelId: String
    public let name: String
    /// The wire protocol, such as `anthropic-messages` or `openai-responses`.
    public let api: String
    public let reasoning: Bool
    /// Accepted inputs: `text`, `image`.
    public let input: [String]
    public let contextWindow: Int
    public let maxTokens: Int
    /// Cost per million tokens.
    public let cost: Usage.Cost
    /// The reasoning levels the model supports, lowest first (pi-ai `getSupportedThinkingLevels`): only `off` for a
    /// model that doesn't reason, and without `off` for one that always does.
    public let thinkingLevels: [ThinkingLevel]

    /// The level a request asking for `level` uses (pi-ai `clampThinkingLevel`): `level` when supported, otherwise the
    /// nearest supported level above it, or failing that below it.
    public func clampThinkingLevel(_ level: ThinkingLevel) -> ThinkingLevel {
        if thinkingLevels.contains(level) { return level }
        let order = ThinkingLevel.allCases
        let requested = order.firstIndex(of: level) ?? 0
        if let above = order[requested...].first(where: thinkingLevels.contains) { return above }
        if let below = order[..<requested].last(where: thinkingLevels.contains) { return below }
        return thinkingLevels.first ?? .off
    }

    /// A reference to this model for ``AgentChange``.
    public var ref: ModelRef { ModelRef(provider: provider, modelId: modelId) }

    private enum CodingKeys: String, CodingKey {
        case provider, id, name, api, reasoning, input, contextWindow, maxTokens, cost, thinkingLevels
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provider = try container.decode(ProviderID.self, forKey: .provider)
        modelId = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? modelId
        api = try container.decodeIfPresent(String.self, forKey: .api) ?? ""
        reasoning = try container.decodeIfPresent(Bool.self, forKey: .reasoning) ?? false
        input = try container.decodeIfPresent([String].self, forKey: .input) ?? ["text"]
        contextWindow = Int(try container.decodeIfPresent(Double.self, forKey: .contextWindow) ?? 0)
        maxTokens = Int(try container.decodeIfPresent(Double.self, forKey: .maxTokens) ?? 0)
        cost = (try? container.decodeIfPresent(Usage.Cost.self, forKey: .cost)) ?? Usage.Cost()
        // Levels this version doesn't know are left out.
        let levels = (try? container.decodeIfPresent([String].self, forKey: .thinkingLevels)) ?? nil
        thinkingLevels = levels?.compactMap(ThinkingLevel.init(rawValue:)) ?? (reasoning ? ThinkingLevel.allCases : [.off])
    }
}

/// A provider of your own (pi-ai `createProvider`), such as Ollama, LM Studio, vLLM, a proxy, or a gateway: the same
/// shape as a custom provider in pi's `models.json`.
///
/// ```swift
/// try await models.register(CustomProvider(
///     id: "ollama", baseURL: URL(string: "http://localhost:11434/v1")!, api: .openAICompletions,
///     headers: ["X-Client": "my-app"],
///     models: [.init(id: "llama3.1:8b", contextWindow: 131_072)]))
/// ```
public struct CustomProvider: Encodable, Sendable {
    /// A pi-ai chat API implementation (`model.api`).
    public struct API: RawRepresentable, Hashable, Encodable, Sendable, ExpressibleByStringLiteral {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public init(stringLiteral value: String) { rawValue = value }
        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }

        public static let openAICompletions: API = "openai-completions"
        public static let openAIResponses: API = "openai-responses"
        public static let azureOpenAIResponses: API = "azure-openai-responses"
        public static let openAICodexResponses: API = "openai-codex-responses"
        public static let anthropicMessages: API = "anthropic-messages"
        public static let googleGenerativeAI: API = "google-generative-ai"
        public static let googleVertex: API = "google-vertex"
        public static let mistralConversations: API = "mistral-conversations"
        public static let piMessages: API = "pi-messages"
    }

    /// A pi-ai chat `Model`. Omitted fields follow the provider (`api`, `baseUrl`, `headers`) or pi-ai's
    /// custom-provider defaults.
    public struct Model: Encodable, Sendable {
        public var id: String
        public var name: String?
        /// Overrides the provider's API, for mixed-API providers.
        public var api: API?
        /// Overrides the provider's base URL.
        public var baseURL: URL?
        public var reasoning: Bool?
        /// `text` and/or `image`.
        public var input: [String]?
        /// Cost per million tokens.
        public var cost: Usage.Cost?
        public var contextWindow: Int?
        public var maxTokens: Int?
        /// HTTP headers sent with this model's requests, over the provider's.
        public var headers: [String: String]?
        /// pi-ai compatibility flags for the model's API (`OpenAICompletionsCompat`, …).
        public var compat: JSONObject?
        /// pi-ai `thinkingLevelMap`: the provider value per thinking level, or `nil` for unsupported levels.
        public var thinkingLevelMap: [ThinkingLevel: String?]?
        /// Any other pi-ai `Model` field, such as `inputLimits`, `promptCache`, or `samplingParams`.
        public var other: JSONObject

        public init(
            id: String, name: String? = nil, api: API? = nil, baseURL: URL? = nil, reasoning: Bool? = nil,
            input: [String]? = nil, cost: Usage.Cost? = nil, contextWindow: Int? = nil, maxTokens: Int? = nil,
            headers: [String: String]? = nil, compat: JSONObject? = nil, thinkingLevelMap: [ThinkingLevel: String?]? = nil,
            other: JSONObject = [:]
        ) {
            self.id = id
            self.name = name
            self.api = api
            self.baseURL = baseURL
            self.reasoning = reasoning
            self.input = input
            self.cost = cost
            self.contextWindow = contextWindow
            self.maxTokens = maxTokens
            self.headers = headers
            self.compat = compat
            self.thinkingLevelMap = thinkingLevelMap
            self.other = other
        }

        public func encode(to encoder: Encoder) throws {
            var json = other
            json["id"] = .string(id)
            if let name { json["name"] = .string(name) }
            if let api { json["api"] = .string(api.rawValue) }
            if let baseURL { json["baseUrl"] = .string(baseURL.absoluteString) }
            if let reasoning { json["reasoning"] = .bool(reasoning) }
            if let input { json["input"] = .array(input.map(JSONValue.string)) }
            if let cost { json["cost"] = try JSONValue(encoding: cost) }
            if let contextWindow { json["contextWindow"] = .number(Double(contextWindow)) }
            if let maxTokens { json["maxTokens"] = .number(Double(maxTokens)) }
            if let headers { json["headers"] = try JSONValue(encoding: headers) }
            if let compat { json["compat"] = .object(compat) }
            if let thinkingLevelMap {
                var map: JSONObject = [:]
                for (level, value) in thinkingLevelMap { map[level.rawValue] = value.map(JSONValue.string) ?? .null }
                json["thinkingLevelMap"] = .object(map)
            }
            try JSONValue.object(json).encode(to: encoder)
        }
    }

    public var id: ProviderID
    public var name: String?
    public var baseURL: URL
    /// The API of models that don't name their own.
    public var api: API
    /// Stored as the provider's API key credential; `nil` for keyless local servers.
    public var apiKey: String?
    /// HTTP headers sent with every request to this provider's models.
    public var headers: [String: String]?
    public var models: [Model]

    public init(
        id: ProviderID, name: String? = nil, baseURL: URL, api: API = .openAICompletions, apiKey: String? = nil,
        headers: [String: String]? = nil, models: [Model]
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.api = api
        self.apiKey = apiKey
        self.headers = headers
        self.models = models
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyKey.self)
        try container.encode(id, forKey: AnyKey("id"))
        try container.encodeIfPresent(name, forKey: AnyKey("name"))
        try container.encode(baseURL.absoluteString, forKey: AnyKey("baseUrl"))
        try container.encode(api, forKey: AnyKey("api"))
        try container.encodeIfPresent(apiKey, forKey: AnyKey("apiKey"))
        try container.encodeIfPresent(headers, forKey: AnyKey("headers"))
        try container.encode(models, forKey: AnyKey("models"))
    }
}

/// The outcome of ``Models/refresh(providers:allowNetwork:force:)``.
public struct RefreshResult: Decodable, Sendable {
    /// Whether the refresh was cancelled before finishing.
    public let aborted: Bool
    /// Providers whose refresh failed, with the error message.
    public let errors: [String: String]
}
