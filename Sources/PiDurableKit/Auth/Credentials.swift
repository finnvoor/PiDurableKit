import Foundation
import Security

/// A stored provider credential: an API key, or OAuth tokens from ``Models/login(to:interaction:installationID:)``.
///
/// The JSON shape is pi-ai's (and pi's `auth.json`): `{ "type": "api_key", "key": … }` or
/// `{ "type": "oauth", "access": …, "refresh": …, "expires": … }`, plus provider-specific fields.
public struct Credential: Codable, Sendable, Hashable {
    public var json: JSONObject

    public init(json: JSONObject) {
        self.json = json
    }

    public init(from decoder: Decoder) throws {
        json = try JSONObject(from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        try json.encode(to: encoder)
    }

    /// An API key credential.
    public static func apiKey(_ key: String) -> Credential {
        Credential(json: ["type": "api_key", "key": .string(key)])
    }

    /// OAuth tokens, for importing a session signed in elsewhere.
    public static func oauth(accessToken: String, refreshToken: String, expiresAt: Date) -> Credential {
        Credential(json: [
            "type": "oauth",
            "access": .string(accessToken),
            "refresh": .string(refreshToken),
            "expires": .number(expiresAt.timeIntervalSince1970 * 1000),
        ])
    }

    public enum Kind: String, Sendable {
        case apiKey = "api_key"
        case oauth
    }

    public var kind: Kind? { json["type"]?.stringValue.flatMap(Kind.init(rawValue:)) }

    /// The API key of an API key credential.
    public var apiKey: String? { kind == .apiKey ? json["key"]?.stringValue : nil }

    /// When the OAuth access token expires; pi-ai refreshes it automatically before requests.
    public var expiresAt: Date? {
        guard kind == .oauth, let milliseconds = json["expires"]?.doubleValue else { return nil }
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }
}

/// Where ``Models`` keeps provider credentials (pi-ai `CredentialStore`).
///
/// pi-ai serializes read-modify-write per provider on top of these operations, so OAuth refreshes never race
/// within one process.
public protocol CredentialStore: Sendable {
    func credential(for provider: ProviderID) async throws -> Credential?
    /// Stores a credential, or with `nil` removes it.
    func setCredential(_ credential: Credential?, for provider: ProviderID) async throws
    /// The providers that have a stored credential.
    func providers() async throws -> [ProviderID]
}

extension CredentialStore where Self == InMemoryCredentialStore {
    /// Credentials that last as long as the process.
    public static var inMemory: InMemoryCredentialStore { InMemoryCredentialStore() }
}

extension CredentialStore where Self == KeychainCredentialStore {
    /// Credentials kept in the Keychain, available after the first unlock so background work can refresh tokens.
    public static var keychain: KeychainCredentialStore { KeychainCredentialStore() }

    /// Credentials kept in the Keychain under `service`, optionally shared through an access group.
    public static func keychain(service: String, accessGroup: String? = nil) -> KeychainCredentialStore {
        KeychainCredentialStore(service: service, accessGroup: accessGroup)
    }
}

/// Credentials that last as long as the process.
public actor InMemoryCredentialStore: CredentialStore {
    private var credentials: [ProviderID: Credential] = [:]

    public init(_ credentials: [ProviderID: Credential] = [:]) {
        self.credentials = credentials
    }

    public func credential(for provider: ProviderID) -> Credential? { credentials[provider] }

    public func setCredential(_ credential: Credential?, for provider: ProviderID) {
        credentials[provider] = credential
    }

    public func providers() -> [ProviderID] { credentials.keys.sorted { $0.rawValue < $1.rawValue } }
}

/// Credentials kept as generic passwords in the Keychain, one item per provider.
public struct KeychainCredentialStore: CredentialStore {
    public let service: String
    public let accessGroup: String?

    public init(service: String = "PiDurableKit.credentials", accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    private func query(_ provider: ProviderID? = nil) -> [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecUseDataProtectionKeychain: true,
        ]
        if let provider { query[kSecAttrAccount] = provider.rawValue }
        if let accessGroup { query[kSecAttrAccessGroup] = accessGroup }
        return query
    }

    public func credential(for provider: ProviderID) throws -> Credential? {
        var query = query(provider)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status: status) }
        return try JSONDecoder().decode(Credential.self, from: data)
    }

    public func setCredential(_ credential: Credential?, for provider: ProviderID) throws {
        guard let credential else {
            let status = SecItemDelete(query(provider) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
            return
        }
        let data = try JSONEncoder().encode(credential)
        let attributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(query(provider) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let item = query(provider).merging(attributes) { _, new in new }
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public func providers() throws -> [ProviderID] {
        var query = query()
        query[kSecReturnAttributes] = true
        query[kSecMatchLimit] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let items = result as? [[CFString: Any]] else { throw KeychainError(status: status) }
        return items.compactMap { ($0[kSecAttrAccount] as? String).map(ProviderID.init(rawValue:)) }.sorted { $0.rawValue < $1.rawValue }
    }
}

public struct KeychainError: Error, LocalizedError, Sendable {
    public let status: OSStatus
    public var errorDescription: String? {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
        return "Keychain error: \(message)"
    }
}
