import Foundation

/// Errors from the profile store (SPEC §8.1).
public enum ServerProfileStoreError: Error, Sendable, Equatable {
    case duplicateId(String)
    case notFound(String)
    case storageUnavailable
}

/// Non-secret server config in app storage: `[{id, name, baseURL, …}]` as JSON in Application
/// Support, written atomically (SPEC §8.1 / §10). This file holds NO secrets — the cookie and the
/// optional password live only in the Keychain (SPEC §10 rule 1). `ServerProfile` is already
/// secret-free by construction, but persisting it here is where that boundary is enforced.
///
/// Stateless in memory (the file is the source of truth); a lock serializes read-modify-write so
/// two concurrent `add`/`update`/`remove` calls cannot lose an entry. `Sendable` because every
/// stored property is an immutable, sendable value.
public final class ServerProfileStore: ServerProfileStoring, Sendable {

    private let fileURL: URL
    private let lock = NSLock()

    /// Persist under `directory` (defaults to the app's Application Support directory). The
    /// directory is created on first write. Injectable so tests write to a temp dir (SPEC §8.1).
    public init(directory: URL? = nil, fileName: String = "servers.json") throws {
        let dir: URL
        if let directory {
            dir = directory
        } else {
            dir = try FileManager.default.url(for: .applicationSupportDirectory,
                                              in: .userDomainMask,
                                              appropriateFor: nil,
                                              create: true)
        }
        self.fileURL = dir.appendingPathComponent(fileName, isDirectory: false)
    }

    // MARK: - ServerProfileStoring (SPEC §8.1)

    public func all() throws -> [ServerProfile] {
        lock.lock(); defer { lock.unlock() }
        return try readAll()
    }

    public func profile(id: String) throws -> ServerProfile? {
        lock.lock(); defer { lock.unlock() }
        return try readAll().first { $0.id == id }
    }

    public func add(_ profile: ServerProfile) throws {
        lock.lock(); defer { lock.unlock() }
        var profiles = try readAll()
        guard !profiles.contains(where: { $0.id == profile.id }) else {
            throw ServerProfileStoreError.duplicateId(profile.id)
        }
        profiles.append(profile)
        try writeAll(profiles)
    }

    public func update(_ profile: ServerProfile) throws {
        lock.lock(); defer { lock.unlock() }
        var profiles = try readAll()
        guard let idx = profiles.firstIndex(where: { $0.id == profile.id }) else {
            throw ServerProfileStoreError.notFound(profile.id)
        }
        profiles[idx] = profile
        try writeAll(profiles)
    }

    public func remove(id: String) throws {
        lock.lock(); defer { lock.unlock() }
        var profiles = try readAll()
        let before = profiles.count
        profiles.removeAll { $0.id == id }
        // Removing an absent id is a no-op success (idempotent), matching Keychain deletes.
        guard profiles.count != before else { return }
        try writeAll(profiles)
    }

    // MARK: - Persistence

    /// Read the profiles file. A missing file is an empty list (first run). A corrupt file is
    /// treated as empty rather than crashing the app — the store is non-secret and re-derivable by
    /// the user re-adding servers (secrets in the Keychain are keyed by id and simply orphan).
    private func readAll() throws -> [ServerProfile] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw ServerProfileStoreError.storageUnavailable
        }
        if data.isEmpty { return [] }
        return (try? JSONDecoder().decode([ServerProfile].self, from: data)) ?? []
    }

    /// Atomic write (SPEC §8.1/§10): encode, then `Data.write(options: .atomic)` — a temp file is
    /// written and renamed into place, so a crash mid-write never truncates the existing file.
    private func writeAll(_ profiles: [ServerProfile]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(profiles)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        do {
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            throw ServerProfileStoreError.storageUnavailable
        }
    }
}
