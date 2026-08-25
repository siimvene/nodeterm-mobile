import Foundation
import NodetermKit

// Contract tests for the KeychainStoring surface, exercised against the in-memory fake (SPEC §8.1 /
// §10). The real `KeychainService` shares this contract but is not run here — a headless
// CommandLineTools process has no unlocked login keychain, so the fake is the test double the whole
// app injects (SPEC §8.1). Framework-free per WireCodecTests.swift.

@inline(__always)
private func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
    precondition(condition(), "keychain-test failed: \(label)")
}

/// Runs the KeychainStoring contract against any implementation, so the same suite validates the
/// fake here and (on device) the real service. `throws` because the reads throw; assertions read
/// into locals first so `try` never sits inside the non-throwing `expect` autoclosure.
public func runKeychainContract(_ kc: KeychainStoring) throws {
    let a = "profile-A"
    let b = "profile-B"

    // Absent by default.
    let c0 = try kc.cookie(forServer: a)
    let pw0 = try kc.password(forServer: a)
    expect(c0 == nil, "cookie absent initially")
    expect(pw0 == nil, "password absent initially")

    // Cookie round-trip.
    try kc.saveCookie("cookieA", forServer: a)
    let c1 = try kc.cookie(forServer: a)
    expect(c1 == "cookieA", "cookie round-trip")

    // Overwrite (upsert) replaces the value.
    try kc.saveCookie("cookieA2", forServer: a)
    let c2 = try kc.cookie(forServer: a)
    expect(c2 == "cookieA2", "cookie overwrite")

    // Cookie and password are independent slots for the SAME profile id.
    try kc.savePassword("pwA", forServer: a)
    let pw = try kc.password(forServer: a)
    let cAfterPw = try kc.cookie(forServer: a)
    expect(pw == "pwA", "password round-trip")
    expect(cAfterPw == "cookieA2", "cookie unaffected by password write")

    // Secrets are scoped by PROFILE id, not shared (SPEC §10 rule 1a).
    try kc.saveCookie("cookieB", forServer: b)
    let cB = try kc.cookie(forServer: b)
    let cA = try kc.cookie(forServer: a)
    expect(cB == "cookieB", "profile B cookie")
    expect(cA == "cookieA2", "profile A cookie isolated from B")

    // Delete cookie leaves password intact.
    try kc.deleteCookie(forServer: a)
    let cGone = try kc.cookie(forServer: a)
    let pwStill = try kc.password(forServer: a)
    expect(cGone == nil, "cookie deleted")
    expect(pwStill == "pwA", "password survives cookie delete")

    // Deleting an absent item is a no-op success (idempotent).
    try kc.deleteCookie(forServer: a)
    try kc.deletePassword(forServer: "nonexistent")

    // deleteAll clears both slots for the profile, and only that profile.
    try kc.saveCookie("cookieA3", forServer: a)
    try kc.deleteAll(forServer: a)
    let cAllGone = try kc.cookie(forServer: a)
    let pwAllGone = try kc.password(forServer: a)
    let cBStill = try kc.cookie(forServer: b)
    expect(cAllGone == nil, "deleteAll clears cookie")
    expect(pwAllGone == nil, "deleteAll clears password")
    expect(cBStill == "cookieB", "deleteAll scoped to one profile")
}

public func runKeychainFakeTests() {
    do {
        try runKeychainContract(InMemoryKeychain())
    } catch {
        expect(false, "keychain contract threw: \(error)")
    }
}
