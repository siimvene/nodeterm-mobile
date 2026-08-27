import Foundation

/// Pure response classifiers for the auth HTTP surface (SPEC §3). Kept side-effect-free and
/// network-free so they can be unit-tested from `(statusCode, headers, body)` alone — a wrong
/// password is a **303, not a 401** (§3.2), so success can only be judged by the presence of an
/// `nt_session` `Set-Cookie`, never by the status code or by following the redirect.
public enum AuthResponseClassifier {

    /// The outcome of a `POST /auth/login` (SPEC §3.2). `.success` carries the captured cookie value.
    public enum LoginOutcome: Sendable, Equatable {
        case success(cookie: String)
        case wrongPassword
        case rateLimited
        case badRequest
    }

    /// Classify a login response. `setCookieHeaders` is the list of raw `Set-Cookie` header lines
    /// (already un-folded if the HTTP stack combined them). SPEC §3.2 table:
    ///  - 429 → rate-limited (§3.3), regardless of any cookie
    ///  - 400 → bad_request
    ///  - a real `nt_session` Set-Cookie present → success (the 303 → /)
    ///  - otherwise → wrong password (303 → /login?error=1, no Set-Cookie)
    public static func classifyLogin(statusCode: Int,
                                     setCookieHeaders: [String]) -> LoginOutcome {
        // Rate-limit and bad-request are judged by status first: a lockout 429 never carries a
        // session cookie, and treating a 400 as "wrong password" would hide a client bug (§3.2).
        if statusCode == 429 { return .rateLimited }
        if statusCode == 400 { return .badRequest }
        // Success is the SPEC's exact shape — 303 + Set-Cookie. A cookie on any other status
        // (a proxy error page, say) must not be adopted as a session (consort finding).
        if statusCode == 303,
           let cookie = SetCookieParser.value(named: NodetermWire.sessionCookieName,
                                              inHeaders: setCookieHeaders) {
            return .success(cookie: cookie)
        }
        if statusCode == 303 { return .wrongPassword }   // the error redirect (§3.2)
        return .badRequest                                // anything else fails closed

    }

    /// The outcome of a `POST /auth/setup` (SPEC §3.1).
    public enum SetupOutcome: Sendable, Equatable {
        case success(cookie: String)
        case alreadyConfigured
        case invalidSetup
        case badRequest
    }

    /// Classify a setup response (SPEC §3.1 table). Both `already_configured` and `invalid_setup`
    /// are 403, distinguished by the JSON `error` field in the body, so the body is required to
    /// tell them apart. Success is the 303 with an `nt_session` Set-Cookie.
    public static func classifySetup(statusCode: Int,
                                     setCookieHeaders: [String],
                                     jsonErrorField: String?) -> SetupOutcome {
        if let cookie = SetCookieParser.value(named: NodetermWire.sessionCookieName,
                                              inHeaders: setCookieHeaders) {
            return .success(cookie: cookie)
        }
        if statusCode == 400 { return .badRequest }
        if statusCode == 403 {
            switch jsonErrorField {
            case "already_configured": return .alreadyConfigured
            case "invalid_setup": return .invalidSetup
            default: return .invalidSetup   // fail closed: a 403 without a known reason is not usable
            }
        }
        // Anything else with no cookie is a bad request from the client's point of view.
        return .badRequest
    }

    /// Classify `GET /login` for the unconfigured probe (SPEC §3.1): an unconfigured server answers
    /// **302 → /setup**. `location` is the raw `Location` header. `true` = unconfigured.
    public static func isUnconfigured(statusCode: Int, location: String?) -> Bool {
        guard statusCode == 302, let location else { return false }
        // The redirect target begins with `/setup` (may carry `?token=` — never logged, §10 rule 2).
        return location.hasPrefix("/setup") || location.contains("/setup?")
    }

    /// Classify an authenticated HTTP GET for session-expiry detection (SPEC §3.5). With
    /// `Accept: application/json`, an expired/absent session returns **401 JSON**
    /// `{"error":"unauthorized"}`; an HTML `Accept` would instead redirect. `true` = re-auth needed.
    public static func isSessionExpired(statusCode: Int) -> Bool {
        statusCode == 401
    }

    /// Map a login outcome to the typed `AuthError` for the throwing `AuthClienting.login` API.
    public static func loginError(for outcome: LoginOutcome) -> AuthError? {
        switch outcome {
        case .success: return nil
        case .wrongPassword: return .wrongPassword
        case .rateLimited: return .rateLimited
        case .badRequest: return .badRequest
        }
    }

    /// Map a setup outcome to the typed `AuthError`.
    public static func setupError(for outcome: SetupOutcome) -> AuthError? {
        switch outcome {
        case .success: return nil
        case .alreadyConfigured: return .alreadyConfigured
        case .invalidSetup: return .invalidSetup
        case .badRequest: return .badRequest
        }
    }
}
