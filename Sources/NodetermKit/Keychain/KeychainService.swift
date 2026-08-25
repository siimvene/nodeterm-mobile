import Foundation
import Security

/// Errors from the Keychain surface (SPEC §10 rule 1). Wraps an OSStatus for diagnosis; the value
/// stored is NEVER included (SPEC §10 rule 2 — no secrets in logs).
public enum KeychainError: Error, Sendable, Equatable {
    case unexpectedStatus(OSStatus)
    case dataEncoding
}

/// Secret storage over the iOS/macOS Keychain (SPEC §10 rule 1). Keys are scoped by SERVER-PROFILE
/// id (never by hostname, §10 rule 1a) using the Keychain `account` attribute, with a distinct
/// `service` per secret kind (cookie vs password). Accessibility is
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` — never synced to iCloud, never file/plist.
///
/// This type is stateless (only constant service names), so it is trivially `Sendable`; the
/// Keychain itself is the shared store and is safe for concurrent access.
public final class KeychainService: KeychainStoring {

    /// Keychain `service` values. Distinct per secret kind so the same profile id can key both a
    /// cookie and a password without collision.
    private let cookieService: String
    private let passwordService: String

    /// `serviceNamespace` defaults to the app's bundle-style prefix. Injectable so parallel test
    /// runs / multiple app targets don't collide in the shared login keychain.
    public init(serviceNamespace: String = "com.nodeterm.mobile") {
        self.cookieService = "\(serviceNamespace).cookie"
        self.passwordService = "\(serviceNamespace).password"
    }

    // MARK: - Cookie (SPEC §10 rule 1 — always stored)

    public func saveCookie(_ value: String, forServer profileId: String) throws {
        try set(value, service: cookieService, account: profileId)
    }
    public func cookie(forServer profileId: String) throws -> String? {
        try get(service: cookieService, account: profileId)
    }
    public func deleteCookie(forServer profileId: String) throws {
        try delete(service: cookieService, account: profileId)
    }

    // MARK: - Password (SPEC §3.5/§3.6 — only on opt-in auto-relogin)

    public func savePassword(_ value: String, forServer profileId: String) throws {
        try set(value, service: passwordService, account: profileId)
    }
    public func password(forServer profileId: String) throws -> String? {
        try get(service: passwordService, account: profileId)
    }
    public func deletePassword(forServer profileId: String) throws {
        try delete(service: passwordService, account: profileId)
    }

    // MARK: - Bulk delete (SPEC §3.4 — logout / server removal)

    public func deleteAll(forServer profileId: String) throws {
        try delete(service: cookieService, account: profileId)
        try delete(service: passwordService, account: profileId)
    }

    // MARK: - SecItem plumbing

    private func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// Upsert: add, or update the existing item's value in place. SPEC §10 rule 1 accessibility.
    private func set(_ value: String, service: String, account: String) throws {
        guard let data = value.data(using: .utf8) else { throw KeychainError.dataEncoding }
        var query = baseQuery(service: service, account: account)

        let update: [String: Any] = [
            kSecValueData as String: data,
            // ThisDeviceOnly ⇒ excluded from iCloud Keychain backup (SPEC §10 rule 1).
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        // Try update first (item may already exist for this profile).
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus == errSecItemNotFound {
            for (k, v) in update { query[k] = v }
            let addStatus = SecItemAdd(query as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
            return
        }
        throw KeychainError.unexpectedStatus(updateStatus)
    }

    private func get(service: String, account: String) throws -> String? {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
            throw KeychainError.dataEncoding
        }
        return value
    }

    private func delete(service: String, account: String) throws {
        let query = baseQuery(service: service, account: account)
        let status = SecItemDelete(query as CFDictionary)
        // Deleting a non-existent item is success from the caller's point of view.
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
