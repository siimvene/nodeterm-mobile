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
    /// Marks the synthetic **demo** profile (docs/DEMO-MODE.md). A demo server is driven by
    /// `DemoFrameTransport` against `DemoScript` — no socket, no cookie — so it is NEVER persisted
    /// to `ProfileStore` and NEVER writes the Keychain. Default false, and back-compatibly Codable:
    /// a stored profile written before this field existed decodes with `isDemo == false` (the key
    /// is optional on read), so the on-disk format is unchanged for real servers.
    public var isDemo: Bool

    public init(id: String = UUID().uuidString,
                name: String,
                baseURL: URL,
                autoConnect: Bool = true,
                rememberPassword: Bool = false,
                insecureHTTP: Bool = false,
                isDemo: Bool = false) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.autoConnect = autoConnect
        self.rememberPassword = rememberPassword
        self.insecureHTTP = insecureHTTP
        self.isDemo = isDemo
    }

    // Custom Codable so a PRE-`isDemo` JSON payload still decodes (the field is read via
    // `decodeIfPresent`, defaulting to false). The other flags are likewise read leniently so a
    // truncated legacy record maps onto the same defaults the memberwise `init` uses; `id`, `name`
    // and `baseURL` remain required. Encoding writes every field, so a fresh round-trip is exact.
    private enum CodingKeys: String, CodingKey {
        case id, name, baseURL, autoConnect, rememberPassword, insecureHTTP, isDemo
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        baseURL = try c.decode(URL.self, forKey: .baseURL)
        autoConnect = try c.decodeIfPresent(Bool.self, forKey: .autoConnect) ?? true
        rememberPassword = try c.decodeIfPresent(Bool.self, forKey: .rememberPassword) ?? false
        insecureHTTP = try c.decodeIfPresent(Bool.self, forKey: .insecureHTTP) ?? false
        isDemo = try c.decodeIfPresent(Bool.self, forKey: .isDemo) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(baseURL, forKey: .baseURL)
        try c.encode(autoConnect, forKey: .autoConnect)
        try c.encode(rememberPassword, forKey: .rememberPassword)
        try c.encode(insecureHTTP, forKey: .insecureHTTP)
        try c.encode(isDemo, forKey: .isDemo)
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
