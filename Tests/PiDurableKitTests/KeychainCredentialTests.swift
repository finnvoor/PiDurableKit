import Foundation
import Security
import Testing
@testable import PiDurableKit

/// Whether this process can write to the data protection keychain at all.
func keychainAvailable() -> Bool {
    let probe = KeychainCredentialStore(service: "PiDurableKitTests.keychain.probe")
    do {
        try probe.setCredential(.apiKey("probe"), for: ProviderID("probe"))
        try probe.setCredential(nil, for: ProviderID("probe"))
        return true
    } catch let error as KeychainError where error.status == errSecMissingEntitlement {
        return false
    } catch {
        return false
    }
}

/// The Keychain store's accessibility: what new items get, and moving existing items to it. Skipped where the test
/// process can't use the data protection keychain (an unsigned `swift test` on macOS has no entitlement for it).
@Suite(.serialized, .enabled(if: keychainAvailable(), "No data protection keychain in this process"))
struct KeychainCredentialTests {
    let service = "PiDurableKitTests.keychain.\(UUID().uuidString)"

    func accessibility(of provider: ProviderID, in store: KeychainCredentialStore) throws -> String? {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword, kSecAttrService: store.service, kSecAttrAccount: provider.rawValue,
            kSecUseDataProtectionKeychain: true, kSecReturnAttributes: true, kSecMatchLimit: kSecMatchLimitOne,
        ]
        if let group = store.accessGroup { query[kSecAttrAccessGroup] = group }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        return (result as? [CFString: Any])?[kSecAttrAccessible] as? String
    }

    @Test func newItemsGetTheStoresAccessibility() throws {
        let local = KeychainCredentialStore(service: service)
        let backedUp = KeychainCredentialStore(service: service, accessibility: .afterFirstUnlock)
        defer { for provider in (try? local.providers()) ?? [] { try? local.setCredential(nil, for: provider) } }

        try local.setCredential(.apiKey("one"), for: ProviderID("a"))
        #expect(try accessibility(of: ProviderID("a"), in: local) == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)

        try backedUp.setCredential(.apiKey("two"), for: ProviderID("b"))
        #expect(try accessibility(of: ProviderID("b"), in: backedUp) == kSecAttrAccessibleAfterFirstUnlock as String)
        // Writing an existing item again gives it the writer's accessibility.
        try backedUp.setCredential(.apiKey("one again"), for: ProviderID("a"))
        #expect(try accessibility(of: ProviderID("a"), in: backedUp) == kSecAttrAccessibleAfterFirstUnlock as String)
        #expect(try backedUp.credential(for: ProviderID("a")) == .apiKey("one again"))
    }

    @Test func migrationMovesEveryItemOnceAndKeepsTheirValues() throws {
        let local = KeychainCredentialStore(service: service)
        let backedUp = KeychainCredentialStore(service: service, accessibility: .afterFirstUnlock)
        defer { for provider in (try? local.providers()) ?? [] { try? local.setCredential(nil, for: provider) } }

        for name in ["openai", "anthropic", "custom-1"] { try local.setCredential(.apiKey("key-\(name)"), for: ProviderID(name)) }
        #expect(try backedUp.migrateAccessibility() == 3)
        for name in ["openai", "anthropic", "custom-1"] {
            #expect(try accessibility(of: ProviderID(name), in: backedUp) == kSecAttrAccessibleAfterFirstUnlock as String)
            #expect(try backedUp.credential(for: ProviderID(name)) == .apiKey("key-\(name)"))
        }
        // Idempotent: nothing left to change.
        #expect(try backedUp.migrateAccessibility() == 0)
        // And back.
        #expect(try local.migrateAccessibility() == 3)
        #expect(try accessibility(of: ProviderID("openai"), in: local) == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
    }

    @Test func migratingAnEmptyStoreChangesNothing() throws {
        #expect(try KeychainCredentialStore(service: service + ".empty", accessibility: .afterFirstUnlock).migrateAccessibility() == 0)
    }

    @Test func synchronizableAndLocalItemsAreSeparate() throws {
        let local = KeychainCredentialStore(service: service, accessibility: .afterFirstUnlock)
        let synced = KeychainCredentialStore(service: service, synchronizable: true)
        defer {
            for store in [local, synced] { for provider in (try? store.providers()) ?? [] { try? store.setCredential(nil, for: provider) } }
        }
        #expect(synced.accessibility == .afterFirstUnlock)
        try synced.setCredential(.apiKey("synced"), for: ProviderID("openai"))
        try local.setCredential(.oauth(accessToken: "a", refreshToken: "r", expiresAt: .now), for: ProviderID("anthropic"))
        #expect(try synced.providers() == [ProviderID("openai")])
        #expect(try local.providers() == [ProviderID("anthropic")])
        #expect(try local.credential(for: ProviderID("openai")) == nil)
        #expect(try synced.credential(for: ProviderID("openai")) == .apiKey("synced"))
        // The same provider in both: each keeps its own.
        try local.setCredential(.apiKey("local"), for: ProviderID("openai"))
        #expect(try synced.credential(for: ProviderID("openai")) == .apiKey("synced"))
        #expect(try local.credential(for: ProviderID("openai")) == .apiKey("local"))
        try synced.setCredential(nil, for: ProviderID("openai"))
        #expect(try local.credential(for: ProviderID("openai")) == .apiKey("local"))
    }
}
