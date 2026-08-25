import Foundation

/// A configured self-host server (SPEC §8.1 / §3.6). Stored in app storage; its SECRETS (cookie,
/// optional password) live in the Keychain keyed by this profile's `id`, NEVER by hostname
/// (SPEC §10 rule 1/1a — two servers on one Tailscale host at different ports would otherwise
/// share a cookie). This struct itself holds NO secrets.
public struct ServerProfile: Codable, Sendable, Equatable, Identifiable, Hashable {
    public var id: String
    public var name: String
    /// Normally `https://<magicdns-or-domain>[:port]` (§2.1). Plain `http` only for explicit
    /// localhost dev behind `insecureHTTP`.
    public var baseURL: URL
    /// Connect this server on app foreground (§8.4). Default true.
    public var autoConnect: Bool
    /// The user opted into auto-relogin: the password is stored in the Keychain (§3.5/§3.6).
    /// Default false.
    public var rememberPassword: Bool
    /// Allow a plain-`http` localhost base (§2.1). Default false; MUST NOT be a "skip TLS" switch.
    public var insecureHTTP: Bool

    public init(id: String = UUID().uuidString,
                name: String,
                baseURL: URL,
                autoConnect: Bool = true,
                rememberPassword: Bool = false,
                insecureHTTP: Bool = false) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.autoConnect = autoConnect
        self.rememberPassword = rememberPassword
        self.insecureHTTP = insecureHTTP
    }
}

extension ServerProfile {
    /// The WebSocket endpoint derived per SPEC §2.1/§4.1: `wss` for an `https` base, `ws` for
    /// `http`, path `/ws`. Returns `nil` only if the base URL lacks a host.
    public var webSocketURL: URL? {
        guard var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              comps.host != nil else { return nil }
        let secure = (baseURL.scheme?.lowercased() == "https")
        comps.scheme = secure ? "wss" : "ws"
        comps.path = "/ws"
        comps.query = nil
        comps.fragment = nil
        return comps.url
    }

    /// Absolute URL for a path under this server's base (e.g. `/auth/login`, `/download`).
    public func url(path: String) -> URL? {
        URL(string: path, relativeTo: baseURL)?.absoluteURL
    }
}
