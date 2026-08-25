import Foundation

/// The login/logout/setup HTTP surface (SPEC §3). Uses a redirect-DISABLED, EPHEMERAL
/// `URLSession` with the system cookie jar OFF (§10 rule 1a), and captures `Set-Cookie` manually —
/// a wrong password is a 303, NOT a 401 (§3.2), so success is judged solely by the presence of an
/// `nt_session` `Set-Cookie`. The client NEVER follows the redirect to decide success (§3.2).
public final class AuthClient: AuthClienting {

    private let session: URLSession
    private let delegate: NoRedirectDelegate

    /// Build with an ephemeral, cookie-jar-off, redirect-disabled session (SPEC §10 rule 1a).
    public init() {
        let delegate = NoRedirectDelegate()
        // SPEC §10 rule 1a: ephemeral config, never persist or auto-attach cookies. The ONLY
        // cookie transport is a manual `Cookie:` header keyed by profile id (never by hostname).
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpCookieAcceptPolicy = .never
        cfg.httpShouldSetCookies = false
        cfg.httpCookieStorage = nil
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        self.delegate = delegate
        self.session = URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil)
    }

    /// For tests / injection: use a caller-provided session (e.g. one backed by a `URLProtocol`
    /// stub). The caller is responsible for disabling redirects/cookies on it.
    public init(session: URLSession) {
        self.delegate = NoRedirectDelegate()
        self.session = session
    }

    deinit {
        // Break the session's retain of its delegate; the client owns the session's lifetime.
        session.finishTasksAndInvalidate()
    }

    // MARK: - AuthClienting (SPEC §3)

    /// POST `/auth/login`, form field `password` (SPEC §3.2). Returns the captured `nt_session`
    /// value on success; throws `AuthError` otherwise.
    public func login(baseURL: URL, password: String) async throws -> String {
        guard let url = baseURL.appendingPathIfPresent("/auth/login") else { throw AuthError.network }
        let body = Self.formEncode(["password": password])
        let (status, setCookies, _) = try await post(url: url, body: body, cookie: nil)
        let outcome = AuthResponseClassifier.classifyLogin(statusCode: status,
                                                           setCookieHeaders: setCookies)
        if let err = AuthResponseClassifier.loginError(for: outcome) { throw err }
        guard case let .success(cookie) = outcome else { throw AuthError.missingSetCookie }
        return cookie
    }

    /// POST `/auth/logout` — best-effort (SPEC §3.4). The server token stays valid until TTL; the
    /// caller deletes local secrets afterward. Never throws — a failed logout still lets the caller
    /// forget the cookie locally.
    public func logout(baseURL: URL, cookie: String) async {
        guard let url = baseURL.appendingPathIfPresent("/auth/logout") else { return }
        _ = try? await post(url: url, body: Data(), cookie: cookie)
    }

    /// POST `/auth/setup`, form fields `token` + `password` (SPEC §3.1). Returns the `nt_session`
    /// value on the 303 success; throws `AuthError` otherwise.
    public func setup(baseURL: URL, token: String, password: String) async throws -> String {
        guard let url = baseURL.appendingPathIfPresent("/auth/setup") else { throw AuthError.network }
        let body = Self.formEncode(["token": token, "password": password])
        let (status, setCookies, data) = try await post(url: url, body: body, cookie: nil)
        let errorField = Self.jsonErrorField(in: data)
        let outcome = AuthResponseClassifier.classifySetup(statusCode: status,
                                                          setCookieHeaders: setCookies,
                                                          jsonErrorField: errorField)
        if let err = AuthResponseClassifier.setupError(for: outcome) { throw err }
        guard case let .success(cookie) = outcome else { throw AuthError.missingSetCookie }
        return cookie
    }

    /// GET `/login` — an unconfigured server answers 302 → /setup (SPEC §3.1). `true` = unconfigured.
    public func detectUnconfigured(baseURL: URL) async throws -> Bool {
        guard let url = baseURL.appendingPathIfPresent("/login") else { throw AuthError.network }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        // Ask for JSON so we get clean status codes, never an HTML body (SPEC §3.5).
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await dataThrowingNetwork(for: req)
        guard let http = response as? HTTPURLResponse else { throw AuthError.network }
        _ = data
        let location = http.value(forHTTPHeaderField: "Location")
        return AuthResponseClassifier.isUnconfigured(statusCode: http.statusCode, location: location)
    }

    // MARK: - HTTP plumbing

    /// Perform a form POST with redirects disabled and manual cookie handling. Returns the status
    /// code, the raw `Set-Cookie` header lines (un-folded), and the body data.
    private func post(url: URL, body: Data, cookie: String?)
        async throws -> (status: Int, setCookies: [String], data: Data) {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        // Clean 401/JSON errors instead of HTML redirects on the expiry path (SPEC §3.5).
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let cookie {
            // SPEC §10 rule 1a: the ONLY cookie transport is a manual header, keyed by profile id
            // upstream — never the system jar, never by hostname.
            req.setValue("\(NodetermWire.sessionCookieName)=\(cookie)", forHTTPHeaderField: "Cookie")
        }
        let (data, response) = try await dataThrowingNetwork(for: req)
        guard let http = response as? HTTPURLResponse else { throw AuthError.network }
        return (http.statusCode, Self.setCookieHeaders(from: http), data)
    }

    private func dataThrowingNetwork(for req: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: req)
        } catch {
            throw AuthError.network
        }
    }

    /// Pull every `Set-Cookie` line out of the response, un-folding a comma-combined stack the
    /// HTTP layer may have merged (SPEC §2.2 / §3.2).
    static func setCookieHeaders(from http: HTTPURLResponse) -> [String] {
        var lines: [String] = []
        for (key, value) in http.allHeaderFields {
            guard let keyStr = key as? String, keyStr.lowercased() == "set-cookie",
                  let valStr = value as? String else { continue }
            lines.append(contentsOf: SetCookieParser.splitFolded(valStr))
        }
        return lines
    }

    /// Read the JSON `{"error":"…"}` field from an auth error body (SPEC §3.1), if present.
    /// Public so the pure classifier path can be unit-tested without a network round trip.
    public static func jsonErrorField(in data: Data) -> String? {
        guard !data.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let err = obj["error"] as? String else { return nil }
        return err
    }

    /// `application/x-www-form-urlencoded` body. Values are percent-encoded with an unreserved set
    /// so a password containing `&`, `=`, `+` or spaces round-trips exactly (SPEC §3.2). Secrets
    /// travel in the POST body, never a URL query string (SPEC §10 rule 2).
    public static func formEncode(_ fields: [String: String]) -> Data {
        // Deterministic order aids testing; the server parses order-independently.
        let pairs = fields.sorted { $0.key < $1.key }.map { key, value in
            "\(formEscape(key))=\(formEscape(value))"
        }
        return Data(pairs.joined(separator: "&").utf8)
    }

    private static let formAllowed: CharacterSet = {
        // Unreserved per RFC 3986; everything else is percent-encoded (spaces become %20).
        let set = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return set
    }()

    static func formEscape(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: formAllowed) ?? ""
    }
}

/// Disables HTTP redirect following (SPEC §3.2 step 1): returning `nil` from the completion handler
/// makes `URLSession` deliver the 303 itself instead of chasing `Location`. Stateless.
final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    // @unchecked Sendable: the delegate holds NO mutable state; every method is a pure decision, so
    // concurrent callbacks on the session's delegate queue cannot race any shared storage.
    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil) // SPEC §3.2: do NOT follow — success is judged by Set-Cookie.
    }
}

private extension URL {
    /// Append a path to a base URL, preserving any base path prefix (e.g. a reverse-proxy mount).
    func appendingPathIfPresent(_ path: String) -> URL? {
        URL(string: path, relativeTo: self)?.absoluteURL
    }
}
