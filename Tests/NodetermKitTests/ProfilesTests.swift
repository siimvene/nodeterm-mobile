import Foundation
import NodetermKit

// ServerProfileStore round-trip + atomic-overwrite tests (SPEC §8.1). Framework-free per
// WireCodecTests.swift; each store is created against a fresh temp directory so no real Application
// Support state is touched. Verifies the store holds NO secrets (SPEC §10 rule 1).

// Plain `Bool` (not an autoclosure) so a `try store.…()` in the argument evaluates in the
// enclosing throwing scope, not inside a non-throwing autoclosure.
@inline(__always)
private func expect(_ condition: Bool, _ label: String) {
    precondition(condition, "profiles-test failed: \(label)")
}

private func freshTempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("nodeterm-profiles-\(UUID().uuidString)", isDirectory: true)
    return dir
}

public func runProfileStoreTests() {
    do {
        let dir = freshTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try ServerProfileStore(directory: dir)

        // Empty on first use.
        expect(try store.all().isEmpty, "empty initially")
        expect(try store.profile(id: "none") == nil, "missing profile → nil")

        // Add + round-trip.
        let p1 = ServerProfile(id: "id-1", name: "Home",
                               baseURL: URL(string: "https://home.example:8443")!)
        try store.add(p1)
        expect(try store.all().count == 1, "one after add")
        expect(try store.profile(id: "id-1") == p1, "round-trip equals")

        // Persisted file is JSON on disk and carries NO secret fields (SPEC §10 rule 1).
        let fileURL = dir.appendingPathComponent("servers.json")
        expect(FileManager.default.fileExists(atPath: fileURL.path), "file written")
        let raw = String(decoding: try Data(contentsOf: fileURL), as: UTF8.self)
        expect(raw.contains("id-1"), "id persisted")
        expect(raw.contains("home.example"), "baseURL persisted")
        // No SECRET field keys. `rememberPassword` is a non-secret Bool flag whose key contains the
        // word "password" but is not the `"password"` key, so match exact quoted keys (SPEC §10 r1).
        expect(!raw.contains("\"cookie\""), "no cookie field in profile file")
        expect(!raw.contains("\"password\""), "no password field in profile file")

        // Duplicate id is refused.
        var threwDup = false
        do { try store.add(p1) } catch ServerProfileStoreError.duplicateId { threwDup = true }
        catch { expect(false, "wrong error for duplicate: \(error)") }
        expect(threwDup, "duplicate id refused")

        // Second profile, distinct id.
        let p2 = ServerProfile(id: "id-2", name: "Work",
                               baseURL: URL(string: "https://work.example")!,
                               autoConnect: false, rememberPassword: true)
        try store.add(p2)
        expect(try store.all().count == 2, "two after second add")

        // Update overwrites in place (atomic write — no torn file).
        var updated = p1
        updated.name = "Home Renamed"
        try store.update(updated)
        expect(try store.profile(id: "id-1")?.name == "Home Renamed", "update applied")
        expect(try store.all().count == 2, "count stable after update")

        // Updating an absent id is refused.
        var threwNF = false
        do {
            try store.update(ServerProfile(id: "ghost", name: "x",
                                           baseURL: URL(string: "https://x")!))
        } catch ServerProfileStoreError.notFound { threwNF = true }
        catch { expect(false, "wrong error for notFound: \(error)") }
        expect(threwNF, "update absent id refused")

        // Atomic overwrite persists across a NEW store instance reading the same file.
        let reopened = try ServerProfileStore(directory: dir)
        let all = try reopened.all()
        expect(all.count == 2, "reopened sees both")
        expect(all.contains { $0.id == "id-1" && $0.name == "Home Renamed" }, "reopened sees update")
        expect(all.contains { $0.id == "id-2" && $0.rememberPassword }, "reopened preserves flags")

        // Remove is idempotent.
        try store.remove(id: "id-1")
        expect(try store.profile(id: "id-1") == nil, "removed")
        expect(try store.all().count == 1, "one after remove")
        try store.remove(id: "id-1")  // no-op, no throw
        expect(try store.all().count == 1, "remove absent is no-op")
    } catch {
        expect(false, "profile store threw: \(error)")
    }
}

/// A corrupt profiles file must not crash the app — it reads as empty and is rebuildable
/// (the profile file holds no secrets; Keychain entries simply orphan). SPEC §8.1.
public func runProfileStoreCorruptFileTest() {
    do {
        let dir = freshTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent("servers.json")
        try Data("this is not json{{{".utf8).write(to: fileURL)

        let store = try ServerProfileStore(directory: dir)
        expect(try store.all().isEmpty, "corrupt file reads as empty")

        // A subsequent add overwrites the corrupt file atomically and is readable again.
        try store.add(ServerProfile(id: "recover", name: "R", baseURL: URL(string: "https://r")!))
        expect(try store.all().count == 1, "recovered after corrupt file")
    } catch {
        expect(false, "corrupt-file test threw: \(error)")
    }
}

public func runAllProfileTests() {
    runProfileStoreTests()
    runProfileStoreCorruptFileTest()
}
