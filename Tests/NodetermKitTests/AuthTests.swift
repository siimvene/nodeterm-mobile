import Foundation
import NodetermKit

// FRAMEWORK-FREE TESTS (see WireCodecTests.swift): this machine has only CommandLineTools, so
// neither XCTest nor swift-testing is available to `swift test`. These files compile in the test
// target (proving the Auth/Keychain/Profiles surfaces type-check) and expose their assertions as
// callable `run…()` functions using `precondition`. On a full toolchain a builder promotes each
// `expect(...)` to a `@Test`/XCTest case. `swift test` here runs and reports zero discovered tests.

@inline(__always)
private func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
    precondition(condition(), "auth-test failed: \(label)")
}

// MARK: - Set-Cookie parsing (SPEC §3.2)

public func runSetCookieParsingTests() {
    let name = "nt_session"

    // Value captured, all attributes ignored (SPEC §3.2).
    expect(SetCookieParser.value(named: name,
        in: "nt_session=deadbeef01; HttpOnly; SameSite=Strict; Path=/") == "deadbeef01",
        "value with attributes")

    // 64-hex realistic value.
    let hex = String(repeating: "a1", count: 32)
    expect(SetCookieParser.value(named: name,
        in: "nt_session=\(hex); HttpOnly; Secure; Path=/") == hex, "64-hex value")

    // No attributes at all.
    expect(SetCookieParser.value(named: name, in: "nt_session=xyz") == "xyz", "bare pair")

    // Leading/trailing whitespace around the pair is trimmed.
    expect(SetCookieParser.value(named: name, in: "  nt_session=trim  ; Path=/") == "trim",
        "whitespace trimmed")

    // Wrong cookie name → nil (never adopt someone else's cookie).
    expect(SetCookieParser.value(named: name, in: "other=zzz; Path=/") == nil, "wrong name")

    // Malformed: no '=' → nil.
    expect(SetCookieParser.value(named: name, in: "nt_session") == nil, "no equals")

    // Malformed: empty name → nil.
    expect(SetCookieParser.value(named: name, in: "=novalue; Path=/") == nil, "empty name")

    // Empty value → "" (single-line parse). It is NOT treated as a valid session by the
    // headers-array scanner below (the logout clear is `nt_session=; Max-Age=0`, §3.4).
    expect(SetCookieParser.value(named: name, in: "nt_session=; Max-Age=0") == "", "empty value")

    // Headers array: pick the real value, skip an empty clear.
    expect(SetCookieParser.value(named: name, inHeaders: [
        "other=1; Path=/",
        "nt_session=; Max-Age=0",
        "nt_session=real; HttpOnly",
    ]) == "real", "array skips empty, finds real")

    // Headers array: only a clear present → nil.
    expect(SetCookieParser.value(named: name, inHeaders: ["nt_session=; Max-Age=0"]) == nil,
        "array only clear → nil")

    // Folded (comma-combined) header splits into two cookies; no Expires attribute here.
    let folded = "other=1; Path=/, nt_session=folded; HttpOnly; SameSite=Strict; Path=/"
    let parts = SetCookieParser.splitFolded(folded)
    expect(parts.count == 2, "folded splits into two")
    expect(SetCookieParser.value(named: name, inHeaders: parts) == "folded", "folded value found")

    // A comma NOT introducing a new token= pair is not a split point.
    let notASplit = "nt_session=abc; Path=/,notacookie"
    expect(SetCookieParser.splitFolded(notASplit).count == 1, "comma inside attribute not split")
}

// MARK: - Login result classification (SPEC §3.2/§3.3) — pure, no network

public func runLoginClassificationTests() {
    typealias C = AuthResponseClassifier
    let hex = String(repeating: "b2", count: 32)

    // Correct password: 303 with nt_session Set-Cookie → success (SPEC §3.2).
    if case let .success(cookie) = C.classifyLogin(statusCode: 303,
        setCookieHeaders: ["nt_session=\(hex); HttpOnly; SameSite=Strict; Path=/"]) {
        expect(cookie == hex, "login success cookie")
    } else { expect(false, "expected login success") }

    // Wrong password: 303 with NO Set-Cookie → wrongPassword (must NOT follow redirect, §3.2).
    expect(C.classifyLogin(statusCode: 303, setCookieHeaders: []) == .wrongPassword,
        "303 no cookie → wrong password")

    // Rate-limited: 429 → rateLimited even if a stray cookie were present (§3.3).
    expect(C.classifyLogin(statusCode: 429, setCookieHeaders: []) == .rateLimited, "429 → rate limited")

    // Bad request: 400 → badRequest (client bug, §3.2).
    expect(C.classifyLogin(statusCode: 400, setCookieHeaders: []) == .badRequest, "400 → bad request")

    // A 200 with a valid cookie also reads as success (success is judged by the cookie, §3.2).
    if case .success = C.classifyLogin(statusCode: 200,
        setCookieHeaders: ["nt_session=\(hex)"]) {} else { expect(false, "200+cookie → success") }

    // Error mapping to AuthError.
    expect(C.loginError(for: .wrongPassword) == .wrongPassword, "map wrongPassword")
    expect(C.loginError(for: .rateLimited) == .rateLimited, "map rateLimited")
    expect(C.loginError(for: .badRequest) == .badRequest, "map badRequest")
    expect(C.loginError(for: .success(cookie: "x")) == nil, "success maps to no error")
}

// MARK: - Setup + unconfigured + expiry classification (SPEC §3.1/§3.5)

public func runSetupAndProbeClassificationTests() {
    typealias C = AuthResponseClassifier
    let hex = String(repeating: "c3", count: 32)

    // Setup success: 303 + Set-Cookie (SPEC §3.1).
    if case let .success(cookie) = C.classifySetup(statusCode: 303,
        setCookieHeaders: ["nt_session=\(hex); Path=/"], jsonErrorField: nil) {
        expect(cookie == hex, "setup success cookie")
    } else { expect(false, "expected setup success") }

    // 403 already_configured vs invalid_setup are distinguished by the JSON error field (§3.1).
    expect(C.classifySetup(statusCode: 403, setCookieHeaders: [],
        jsonErrorField: "already_configured") == .alreadyConfigured, "already_configured")
    expect(C.classifySetup(statusCode: 403, setCookieHeaders: [],
        jsonErrorField: "invalid_setup") == .invalidSetup, "invalid_setup")
    // A 403 without a known reason fails closed to invalidSetup.
    expect(C.classifySetup(statusCode: 403, setCookieHeaders: [],
        jsonErrorField: nil) == .invalidSetup, "403 unknown → invalidSetup")
    // 400 → badRequest.
    expect(C.classifySetup(statusCode: 400, setCookieHeaders: [],
        jsonErrorField: "bad_request") == .badRequest, "setup 400")

    expect(C.setupError(for: .alreadyConfigured) == .alreadyConfigured, "map alreadyConfigured")
    expect(C.setupError(for: .invalidSetup) == .invalidSetup, "map invalidSetup")
    expect(C.setupError(for: .success(cookie: "x")) == nil, "setup success no error")

    // Unconfigured probe: 302 → /setup means unconfigured (SPEC §3.1).
    expect(C.isUnconfigured(statusCode: 302, location: "/setup?token=abc") == true,
        "302 /setup → unconfigured")
    expect(C.isUnconfigured(statusCode: 302, location: "/login") == false,
        "302 /login → configured")
    expect(C.isUnconfigured(statusCode: 200, location: nil) == false, "200 → configured")

    // Session expiry: authenticated JSON GET returns 401 (SPEC §3.5).
    expect(C.isSessionExpired(statusCode: 401) == true, "401 → expired")
    expect(C.isSessionExpired(statusCode: 200) == false, "200 → not expired")
}

// MARK: - Form encoding (SPEC §3.2 / §10 rule 2 — secrets in the body, encoded)

public func runFormEncodingTests() {
    // A password with reserved chars round-trips through percent-encoding.
    let body = AuthClient.formEncode(["password": "p@ss w&rd=+/"])
    let str = String(decoding: body, as: UTF8.self)
    expect(str.hasPrefix("password="), "form field name present")
    expect(!str.contains(" "), "space is encoded, not literal")
    expect(str.contains("%40"), "@ encoded")   // @ → %40
    expect(str.contains("%26"), "& encoded")   // & → %26
    expect(str.contains("%3D"), "= encoded")   // = → %3D
    expect(str.contains("%2B"), "+ encoded")   // + → %2B
    expect(str.contains("%20"), "space → %20")

    // Two fields join with '&', sorted for determinism.
    let two = String(decoding: AuthClient.formEncode(["token": "t1", "password": "p1"]), as: UTF8.self)
    expect(two == "password=p1&token=t1", "two fields sorted and joined")

    // JSON error field extraction (SPEC §3.1).
    let data = Data(#"{"error":"already_configured"}"#.utf8)
    expect(AuthClient.jsonErrorField(in: data) == "already_configured", "json error field")
    expect(AuthClient.jsonErrorField(in: Data()) == nil, "empty body → nil error field")
    expect(AuthClient.jsonErrorField(in: Data("not json".utf8)) == nil, "non-json → nil")
}

// MARK: - Redaction helper (SPEC §10 rule 2)

public func runRedactionTests() {
    let r = NetworkRedaction.self

    expect(r.isSensitive(headerName: "Cookie"), "Cookie is sensitive")
    expect(r.isSensitive(headerName: "set-cookie"), "set-cookie is sensitive (case-insensitive)")
    expect(r.isSensitive(headerName: "Authorization"), "Authorization is sensitive")
    expect(!r.isSensitive(headerName: "Accept"), "Accept is not sensitive")

    expect(r.redactedValue(headerName: "Set-Cookie", value: "nt_session=secret") == "<redacted>",
        "Set-Cookie value masked")
    expect(r.redactedValue(headerName: "Accept", value: "application/json") == "application/json",
        "benign value passes through")

    let desc = r.redactedDescription(headers: [
        "Cookie": "nt_session=topsecret64hex",
        "Accept": "application/json",
        "Content-Type": "application/x-www-form-urlencoded",
    ])
    expect(!desc.contains("topsecret64hex"), "secret never appears in description")
    expect(desc.contains("<redacted>"), "placeholder present")
    expect(desc.contains("application/json"), "benign header retained")

    // Free-form cookie-line masking.
    let masked = r.maskCookieValues(in: "Cookie: nt_session=abc123; extra=1")
    expect(!masked.contains("abc123"), "cookie value masked in free-form string")
    expect(masked.contains("nt_session=<redacted>"), "cookie name kept, value masked")
    expect(masked.contains("extra=1"), "non-secret token retained")
}

public func runAllAuthTests() {
    runSetCookieParsingTests()
    runLoginClassificationTests()
    runSetupAndProbeClassificationTests()
    runFormEncodingTests()
    runRedactionTests()
}
