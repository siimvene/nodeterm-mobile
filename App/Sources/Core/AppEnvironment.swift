import SwiftUI
import Combine
import NodetermKit

/// The composition root the whole UI observes (SPEC §8). It holds ONLY Kit protocol types; every
/// concrete implementation is constructed in `Factory` (the single place an integrator fixes
/// concrete names). No entitlement/subscription state exists here (SPEC §1 hard requirement).
@MainActor
public final class AppEnvironment: ObservableObject {

    public let settings: AppSettings
    private let notifications = NotificationService()
    /// Last-seen NotifyNode across all servers, keyed by the composite "serverId/nodeId" — node
    /// ids are only per-launch unique (consort finding). The previous half of the edge detector.
    private var lastNotifyNodes: [String: NotifyNode] = [:]
    /// Notification permission resolved? Until it is, the pass does NOT advance lastNotifyNodes,
    /// so an edge that arrives during the auth round-trip is not lost (consort finding).
    private var notifyAuthResolved = false
    private let profileStore: ServerProfileStoring
    private let keychain: KeychainStoring
    private let auth: AuthClienting
    private let deviceName: String

    @Published public private(set) var runtimes: [ServerRuntime] = []
    /// Servers with no live runtime (never connected / logged out) still need a row on HOME.
    @Published public private(set) var profiles: [ServerProfile] = []
    /// A server whose session expired and needs a login sheet (SPEC §3.5).
    @Published public var reauthNeeded: ServerProfile?

    /// Per-runtime `objectWillChange` relays (SPEC §9.1: HOME's tiles/rows/server states read the
    /// runtimes' @Published state through computed properties here — without the relay a nested
    /// ObservableObject's changes never invalidate views that observe only AppEnvironment).
    private var runtimeObservers: [String: AnyCancellable] = [:]
    /// Servers with an auto-relogin currently in flight (dedupe the §3.5 edge).
    private var reauthInFlight: Set<String> = []

    public init(settings: AppSettings,
                profileStore: ServerProfileStoring,
                keychain: KeychainStoring,
                auth: AuthClienting,
                deviceName: String) {
        self.settings = settings
        self.profileStore = profileStore
        self.keychain = keychain
        self.auth = auth
        self.deviceName = deviceName
        self.profiles = (try? profileStore.all()) ?? []
    }

    public func runtime(for profileId: String) -> ServerRuntime? {
        runtimes.first { $0.id == profileId }
    }

    // MARK: Foreground / background (SPEC §8.4)

    /// Connect every auto-connect server that has a stored cookie (SPEC §8.4). Called on foreground.
    public func connectAll() {
        for profile in profiles where profile.autoConnect {
            connect(profile)
        }
    }

    public func disconnectAll() {
        runtimes.forEach { $0.stop() }
    }

    private func connect(_ profile: ServerProfile) {
        // A runtime that already exists is RESTARTED, not skipped (SPEC §8.4): backgrounding
        // stops every runtime in place, so on foreground the same object must reconnect.
        // start() is a no-op while it is already running.
        if let existing = runtime(for: profile.id) {
            existing.start()
            return
        }
        guard let cookie = try? keychain.cookie(forServer: profile.id) else {
            // No stored cookie ⇒ server needs a login before it can connect (SPEC §3.5/§3.6).
            return
        }
        let runtime = Factory.makeRuntime(profile: profile, cookie: cookie,
                                          settings: settings, deviceName: deviceName)
        runtime.onAuthRequired = { [weak self, weak runtime] in
            // Dead cookie (SPEC §3.5): pause the reconnect loop FIRST (stop hammering the dead
            // cookie at the backoff cap), then silently re-login when the user opted in.
            guard let self, let runtime else { return }
            runtime.pauseForAuth()
            self.autoReauth(profile)
        }
        // Relay the runtime's change notifications so HOME/server-detail (which observe only
        // AppEnvironment) re-render on live workspace/status/connection updates (SPEC §9.1/§6.3).
        runtimeObservers[profile.id] = runtime.objectWillChange.sink { [weak self] _ in
            guard let self else { return }
            self.objectWillChange.send()
            // objectWillChange fires in willSet — @Published statuses still holds the OLD value.
            // Defer one tick so the pass reads the settled statuses (consort finding).
            Task { @MainActor in self.runNotificationPass() }
        }
        runtimes.append(runtime)
        runtime.start()
    }

    /// Ask for notification permission once (call from the app's first appear). Marks the gate
    /// open when the request settles so a pre-auth status replay is not consumed-and-lost.
    public func enableNotifications() {
        Task { @MainActor in
            await notifications.requestAuthorizationIfNeeded()
            self.notifyAuthResolved = true
            self.runNotificationPass()   // catch up on anything that arrived during the round-trip
        }
    }

    /// Aggregate every server's live statuses, diff against the last pass, and fire local
    /// notifications for finished / needs-you edges (SPEC §6.3 #8 / §9.6). The app-icon badge is
    /// kept at the total unread count. Runs on the main actor off the runtimes' change relay.
    private func runNotificationPass() {
        // Do nothing until the permission round-trip has resolved — advancing the snapshot before
        // then would consume an edge that could never fire (consort finding).
        guard notifyAuthResolved else { return }
        var merged: [String: NotifyNode] = [:]
        for runtime in runtimes {
            for (nodeId, st) in runtime.statuses {
                let key = "\(runtime.id)/\(nodeId)"
                merged[key] = NotifyNode(key: key, serverId: runtime.id, nodeId: nodeId,
                                         state: st.state, unread: st.unread)
            }
        }
        let prefs = NotifyPrefs(onFinished: settings.notifyOnCompletion,
                                onNeedsYou: settings.notifyOnNeedsYou)
        let pending = pendingNotifications(previous: lastNotifyNodes, current: merged, prefs: prefs)
        lastNotifyNodes = merged
        notifications.deliver(pending, badgeCount: unreadBadgeCount(merged)) { [weak self] p in
            self?.sessionTitle(serverId: p.serverId, nodeId: p.nodeId)
        }
    }

    /// Persisted title of a node on a specific server (composite identity — consort finding).
    private func sessionTitle(serverId: String, nodeId: String) -> String? {
        guard let runtime = runtimes.first(where: { $0.id == serverId }),
              let p = runtime.workspace?.projects.first(where: { $0.nodes.contains { $0.id == nodeId } }),
              let node = p.nodes.first(where: { $0.id == nodeId }) else { return nil }
        return node.title
    }

    /// Drop a runtime AND its change relay (the two must live and die together).
    private func dropRuntime(id: String) {
        runtime(for: id)?.stop()
        runtimes.removeAll { $0.id == id }
        runtimeObservers[id] = nil
    }

    /// SPEC §3.5 step 1: on auth-expiry, silently re-run the login once when the user opted into
    /// auto-relogin; otherwise (or on failure) surface the login sheet.
    private func autoReauth(_ profile: ServerProfile) {
        guard !reauthInFlight.contains(profile.id) else { return }
        reauthInFlight.insert(profile.id)
        Task { [weak self] in
            await self?.reauth(profile)
            self?.reauthInFlight.remove(profile.id)
        }
    }

    // MARK: Add server (SPEC §3.6)

    /// Perform the §3.2 login, persist `{name, baseURL}` + `{cookie[, password]}`, connect the WS.
    /// Throws `AuthError` so the form can surface a plain message (SPEC §3.6 / §9.1).
    public func addServer(name: String, baseURL: URL, password: String,
                          rememberPassword: Bool, insecureHTTP: Bool) async throws {
        let cookie = try await auth.login(baseURL: baseURL, password: password)
        let profile = ServerProfile(name: name, baseURL: baseURL,
                                    rememberPassword: rememberPassword, insecureHTTP: insecureHTTP)
        try keychain.saveCookie(cookie, forServer: profile.id)
        if rememberPassword { try keychain.savePassword(password, forServer: profile.id) }
        try profileStore.add(profile)
        profiles = (try? profileStore.all()) ?? profiles
        connect(profile)
    }

    /// First-run `/setup` from the add-server flow when the server is unconfigured (SPEC §3.1).
    /// Returns `true` if the server needed setup (the caller then prompts for the console token).
    public func isUnconfigured(baseURL: URL) async -> Bool {
        (try? await auth.detectUnconfigured(baseURL: baseURL)) ?? false
    }

    public func setupServer(name: String, baseURL: URL, token: String, password: String,
                            insecureHTTP: Bool) async throws {
        let cookie = try await auth.setup(baseURL: baseURL, token: token, password: password)
        let profile = ServerProfile(name: name, baseURL: baseURL, insecureHTTP: insecureHTTP)
        try keychain.saveCookie(cookie, forServer: profile.id)
        try profileStore.add(profile)
        profiles = (try? profileStore.all()) ?? profiles
        connect(profile)
    }

    // MARK: Re-auth (SPEC §3.5)

    /// Silent re-login when the user opted into auto-relogin; on wrong-password (password changed
    /// server-side) drop the stored password and surface the login sheet (SPEC §3.5 step 1).
    public func reauth(_ profile: ServerProfile) async {
        guard profile.rememberPassword,
              let password = try? keychain.password(forServer: profile.id) else {
            reauthNeeded = profile
            return
        }
        do {
            let cookie = try await auth.login(baseURL: profile.baseURL, password: password)
            try keychain.saveCookie(cookie, forServer: profile.id)
            // The cookie is baked into the transport factory, so a re-login needs a FRESH runtime.
            dropRuntime(id: profile.id)
            connect(profile)
        } catch AuthError.wrongPassword {
            try? keychain.deletePassword(forServer: profile.id)
            reauthNeeded = profile
        } catch {
            reauthNeeded = profile
        }
    }

    /// Manual login from the re-auth sheet (SPEC §3.5 step 2).
    public func login(_ profile: ServerProfile, password: String, rememberPassword: Bool) async throws {
        let cookie = try await auth.login(baseURL: profile.baseURL, password: password)
        try keychain.saveCookie(cookie, forServer: profile.id)
        if rememberPassword {
            try keychain.savePassword(password, forServer: profile.id)
        } else {
            // Disabling retention must DELETE the stored password, or silent auto-reauth keeps
            // using it forever (consort finding).
            try? keychain.deletePassword(forServer: profile.id)
        }
        // Persist the choice onto the profile so future auto-reauth honors it.
        if profile.rememberPassword != rememberPassword {
            var updated = profile
            updated.rememberPassword = rememberPassword
            try? profileStore.update(updated)
            profiles = (try? profileStore.all()) ?? profiles
        }
        reauthNeeded = nil
        // Fresh runtime — the transport factory captured the OLD cookie (see reauth()).
        dropRuntime(id: profile.id)
        connect(profile)
    }

    // MARK: Remove / logout (SPEC §3.4)

    /// Logout is best-effort server-side (token survives to TTL) but MUST delete local secrets
    /// (SPEC §3.4 / §9 rule 9 — the UI copy says the server session lives on).
    public func removeServer(_ profile: ServerProfile) async {
        dropRuntime(id: profile.id)
        if let cookie = try? keychain.cookie(forServer: profile.id) {
            await auth.logout(baseURL: profile.baseURL, cookie: cookie)
        }
        try? keychain.deleteAll(forServer: profile.id)
        try? profileStore.remove(id: profile.id)
        profiles = (try? profileStore.all()) ?? profiles
    }

    // MARK: HOME stat tiles (SPEC §9.1)

    /// Terminal-kind nodes in non-`closed` projects across CONNECTED servers.
    public var activeSessionCount: Int {
        connectedRuntimes.reduce(0) { $0 + $1.sessionRows.count }
    }

    public var onlineServerCount: Int {
        runtimes.filter { $0.connectionState == .connected }.count
    }

    /// Non-`closed` projects across connected servers.
    public var projectCount: Int {
        connectedRuntimes.reduce(0) {
            $0 + ($1.workspace?.projects.filter { $0.closed != true }.count ?? 0)
        }
    }

    private var connectedRuntimes: [ServerRuntime] {
        runtimes.filter { $0.connectionState == .connected }
    }

    /// All HOME session rows across every connected server, grouped by project (desktop-sidebar
    /// shape; status is the per-row badge — see SessionListModel.groupedByProject).
    public var groupedSessions: [(title: String, rows: [SessionRow])] {
        SessionListModel.groupedByProject(connectedRuntimes.flatMap { $0.sessionRows },
                                          multiServer: profiles.count > 1)
    }
}
