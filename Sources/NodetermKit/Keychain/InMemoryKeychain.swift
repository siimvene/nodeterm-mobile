import Foundation

/// An in-memory `KeychainStoring` used by tests and SwiftUI previews (SPEC §8.1). It reproduces the
/// real service's contract exactly — secrets keyed by (kind, profile id), independent cookie and
/// password slots, idempotent deletes — WITHOUT touching the real Keychain, so unit tests never
/// need a signed app or an unlocked login keychain.
///
/// `@unchecked Sendable`: all storage is guarded by `lock`, so concurrent access is data-race free.
public final class InMemoryKeychain: KeychainStoring, @unchecked Sendable {

    private enum Kind { case cookie, password }
    private struct Key: Hashable { let kind: Kind; let profileId: String }

    private let lock = NSLock()
    private var store: [Key: String] = [:]

    public init() {}

    // MARK: - Cookie

    public func saveCookie(_ value: String, forServer profileId: String) throws {
        set(value, .cookie, profileId)
    }
    public func cookie(forServer profileId: String) throws -> String? {
        get(.cookie, profileId)
    }
    public func deleteCookie(forServer profileId: String) throws {
        remove(.cookie, profileId)
    }

    // MARK: - Password

    public func savePassword(_ value: String, forServer profileId: String) throws {
        set(value, .password, profileId)
    }
    public func password(forServer profileId: String) throws -> String? {
        get(.password, profileId)
    }
    public func deletePassword(forServer profileId: String) throws {
        remove(.password, profileId)
    }

    // MARK: - Bulk delete

    public func deleteAll(forServer profileId: String) throws {
        remove(.cookie, profileId)
        remove(.password, profileId)
    }

    // MARK: - Locked storage

    private func set(_ value: String, _ kind: Kind, _ profileId: String) {
        lock.lock(); defer { lock.unlock() }
        store[Key(kind: kind, profileId: profileId)] = value
    }
    private func get(_ kind: Kind, _ profileId: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return store[Key(kind: kind, profileId: profileId)]
    }
    private func remove(_ kind: Kind, _ profileId: String) {
        lock.lock(); defer { lock.unlock() }
        store[Key(kind: kind, profileId: profileId)] = nil
    }
}
