import Foundation

/// How model requests identify the app to providers (pi-ai `ClientIdentity`): the `User-Agent`, and attribution
/// headers such as OpenRouter's app title and referrer. Unset fields fall through to the identity below: a request's
/// over its harness's (``Harness/open(_:models:extensions:settings:environment:resume:onConversationCreated:clock:timer:onWake:onReport:identity:telemetry:)``),
/// over its runtime's (``Runtime/Client``).
public struct ClientIdentity: Sendable, Hashable, Encodable {
    /// The `User-Agent` sent to providers.
    public enum UserAgent: Sendable, Hashable {
        /// `pi`.
        case short
        /// `pi/<version> (browser)`, pi-ai's default.
        case detailed
        /// The given value.
        case custom(String)
    }

    /// Who requests are attributed to.
    public enum Attribution: Sendable, Hashable {
        /// Whatever the identity below says.
        case inherited
        /// No attribution headers, also turning off attribution set below.
        case none
        /// The given app.
        case app(ClientAttribution)
    }

    public var userAgent: UserAgent?
    public var attribution: Attribution
    /// The version in a detailed `User-Agent`; default pi-ai's.
    public var version: String?

    public init(userAgent: UserAgent? = nil, attribution: Attribution = .inherited, version: String? = nil) {
        self.userAgent = userAgent
        self.attribution = attribution
        self.version = version
    }

    /// This identity with `other`'s set fields over it (pi-ai `mergeClientIdentity`).
    public func merged(with other: ClientIdentity) -> ClientIdentity {
        ClientIdentity(
            userAgent: other.userAgent ?? userAgent,
            attribution: other.attribution == .inherited ? attribution : other.attribution,
            version: other.version ?? version)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyKey.self)
        switch userAgent {
        case .short: try container.encode("short", forKey: AnyKey("userAgent"))
        case .detailed: try container.encode("detailed", forKey: AnyKey("userAgent"))
        case .custom(let value): try container.encode(["custom": value], forKey: AnyKey("userAgent"))
        case nil: break
        }
        switch attribution {
        case .inherited: break
        case .none: try container.encodeNil(forKey: AnyKey("attribution"))
        case .app(let app): try container.encode(app, forKey: AnyKey("attribution"))
        }
        try container.encodeIfPresent(version, forKey: AnyKey("version"))
    }
}

/// An app requests are attributed to (pi-ai `ClientAttribution`).
public struct ClientAttribution: Sendable, Hashable, Codable {
    /// The app's name: OpenRouter's app title, NVIDIA's invoke origin, OpenCode's client.
    public var name: String
    /// The app's URL: OpenRouter's `HTTP-Referer`, which identifies the app in its rankings.
    public var url: String
    /// The app's categories, such as `cli-agent`: OpenRouter's `X-OpenRouter-Categories`.
    public var categories: [String]?

    public init(name: String, url: String, categories: [String]? = nil) {
        self.name = name
        self.url = url
        self.categories = categories
    }
}
