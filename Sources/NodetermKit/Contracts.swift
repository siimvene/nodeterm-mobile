import Foundation

// The FIXED protocols the five parallel builders implement against. Method signatures here are
// FINAL — builders MUST NOT change them. Every signature is derived from what SPEC §3/§4/§5/§7/§8
// actually requires. All are `Sendable` and use `async` where an implementation is expected to be
// an actor (SPEC §8.1), so an actor-isolated witness is legal in Swift 6 strict concurrency.

// MARK: - Errors (SPEC §4.6)

/// The typed RPC error surface. `E_DISCONNECTED` is client-synthesized on socket close (§4.8);
/// `E_NO_HANDLER` / `E_HANDLER` arrive on the wire; `E_UNAUTHORIZED` / `E_UNSUPPORTED` are noted
/// for completeness (self-host auth failure is the raw 401 at WS upgrade, §4.1).
public enum RpcError: Error, Sendable, Equatable {
    case disconnected                 // E_DISCONNECTED (§4.6/§4.8): fail every in-flight request on close
    case unauthorized                 // E_UNAUTHORIZED (relay path only on the wire; §4.6)
    case noHandler(method: String?)   // E_NO_HANDLER (§4.6): method not served on this edition
    case handler(message: String)     // E_HANDLER (§4.6): server-side failure of a served method
    case unsupported                  // E_UNSUPPORTED (browser-local stub; not expected on self-host)
    case malformedFrame               // a frame that had to be dropped (§4.3)
    case timeout                      // no matching `res` within the client's deadline

    /// Map a wire `res.error` (§4.3) into a typed case. Unknown codes become `.handler`.
    public init(code: String, message: String) {
        switch code {
        case "E_NO_HANDLER": self = .noHandler(method: message.isEmpty ? nil : message)
        case "E_HANDLER": self = .handler(message: message)
        case "E_DISCONNECTED": self = .disconnected
        case "E_UNAUTHORIZED": self = .unauthorized
        case "E_UNSUPPORTED": self = .unsupported
        default: self = .handler(message: message)
        }
    }
}

/// Errors from the HTTP auth surface (SPEC §3).
public enum AuthError: Error, Sendable, Equatable {
    case wrongPassword          // §3.2: 303 → /login?error=1 (no Set-Cookie)
    case rateLimited            // §3.3: 429; lockout is a global 60 s window — MUST NOT auto-retry
    case badRequest             // §3.1/§3.2: 400
    case alreadyConfigured      // §3.1: 403 already_configured
    case invalidSetup           // §3.1: 403 invalid_setup (bad token / password < 8)
    case missingSetCookie       // success-shaped response carried no nt_session cookie
    case network                // transport failure reaching the server
}

/// Reconnect/liveness state a client publishes for the UI (SPEC §8.2).
public enum ConnectionState: String, Sendable, Equatable {
    case connected
    case reconnecting
    case authRequired
    case offline
}

// MARK: - Raw WebSocket frame transport (SPEC §4)

/// A single inbound WS message. TEXT = JSON RPC (§4.3); BINARY = pty output (§4.5, server→client).
public enum WSMessage: Sendable, Equatable {
    case text(String)
    case binary(Data)
}

/// The raw framed WebSocket seam (SPEC §4.1/§4.2). One socket per server. The upgrade MUST carry
/// `Cookie: nt_session=<token>` and MUST NOT send an `Origin` header (§4.1). `receive()` throws
/// when the socket closes — the RPC layer turns that into `E_DISCONNECTED` for pending requests.
public protocol FrameTransporting: Sendable {
    /// Open the socket (cookie attached by the implementation, per-profile; §10 rule 1a).
    func connect() async throws
    /// Send one text frame. The client MUST NOT send binary frames (§4.2).
    func send(_ text: String) async throws
    /// Await the next inbound message; throws on close/error.
    func receive() async throws -> WSMessage
    /// Close the socket (normal closure).
    func close() async
}

// MARK: - RPC client (SPEC §4 / §8.2) — expected to be an actor

/// The isomorphic WS-RPC layer (SPEC §4). One per server: id counter, pending map, `undef` codec,
/// binary decode, channel fan-out + early-event buffer (4096, drop-oldest, §4.9), reconnect (§4.8).
/// Implementations SHOULD be actors (§8.2).
public protocol RpcClienting: Sendable {
    /// Begin the connect + reconnect loop (§4.8).
    func start() async
    /// Tear down permanently (no reconnect); fail all pending with `.disconnected`.
    func stop() async

    /// Assign an `id`, encode `undef` (§4.4), await the matching `res`. Throws `RpcError`
    /// (`.noHandler` / `.handler` from the wire; `.disconnected` when the socket closes mid-flight).
    func request(_ method: String, _ args: [RpcArg]) async throws -> JSONValue
    /// Fire-and-forget cast (§4.3). Never awaits a reply.
    func cast(_ method: String, _ args: [RpcArg]) async

    /// Subscribe an event channel; replays the early-event buffer to the first subscriber (§4.9).
    /// Each element is the event's decoded `args` (with the `undef` decode already applied, §4.4).
    func subscribe(_ channel: String) async -> AsyncStream<[JSONValue]>
    /// The pty output stream for a session (decoded binary frames, §4.5). Bytes are a live VT
    /// stream — feed them to the emulator verbatim (§8.3).
    func ptyData(for sessionId: String) async -> AsyncStream<Data>

    /// Live connection state for the UI (§8.2).
    func connectionStates() async -> AsyncStream<ConnectionState>
    /// A snapshot of the current connection state.
    func connectionState() async -> ConnectionState
}

// MARK: - HTTP auth (SPEC §3)

/// The login/logout/setup HTTP surface (SPEC §3). Implementations MUST use a redirect-DISABLED,
/// EPHEMERAL `URLSession` with the system cookie jar OFF (§10 rule 1a) and capture `Set-Cookie`
/// manually — a wrong password is a 303, NOT a 401 (§3.2), so success is judged solely by the
/// presence of an `nt_session` Set-Cookie.
public protocol AuthClienting: Sendable {
    /// POST `/auth/login` (form field `password`). Returns the captured `nt_session` value on
    /// success; throws `AuthError` (`.wrongPassword` on the error redirect, `.rateLimited` on 429).
    func login(baseURL: URL, password: String) async throws -> String
    /// POST `/auth/logout` — best-effort; the server token stays valid until TTL (§3.4). The caller
    /// still deletes local secrets afterwards.
    func logout(baseURL: URL, cookie: String) async
    /// POST `/auth/setup` (fields `token`, `password`). Returns the `nt_session` value on the 303
    /// success (§3.1). Rarely used from the phone.
    func setup(baseURL: URL, token: String, password: String) async throws -> String
    /// Detect an unconfigured server: `GET /login` answers 302 → /setup when not yet set up (§3.1).
    func detectUnconfigured(baseURL: URL) async throws -> Bool
}

// MARK: - Keychain (SPEC §10)

/// Secret storage keyed by SERVER-PROFILE id (never by hostname, §10 rule 1a). Cookies always;
/// passwords only when the user opted into auto-relogin (§3.5/§3.6). Implementations MUST use
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` or stricter — never UserDefaults/iCloud/files.
public protocol KeychainStoring: Sendable {
    func saveCookie(_ value: String, forServer profileId: String) throws
    func cookie(forServer profileId: String) throws -> String?
    func deleteCookie(forServer profileId: String) throws

    func savePassword(_ value: String, forServer profileId: String) throws
    func password(forServer profileId: String) throws -> String?
    func deletePassword(forServer profileId: String) throws

    /// Delete every secret for a server (logout / server removal, §3.4).
    func deleteAll(forServer profileId: String) throws
}

// MARK: - Server profiles (SPEC §8.1)

/// Non-secret server config in app storage (`[{id, name, baseURL}]`, §8.1). Secrets live in
/// `KeychainStoring`.
public protocol ServerProfileStoring: Sendable {
    func all() throws -> [ServerProfile]
    func profile(id: String) throws -> ServerProfile?
    func add(_ profile: ServerProfile) throws
    func update(_ profile: ServerProfile) throws
    func remove(id: String) throws
}

// MARK: - Workspace store (SPEC §6.4)

/// Per-server `Workspace` snapshot kept live by applying `canvas:mut` deltas (SPEC §6.4).
/// Implementations SHOULD be actors.
public protocol WorkspaceStoring: Sendable {
    /// Adopt a fresh `workspace:load` result.
    func replace(with workspace: Workspace) async
    /// Apply a `canvas:mut` delta to the named project's node list (upsert/remove, §6.4). On any
    /// doubt the caller re-runs `workspace:load` and `replace`s.
    func apply(_ mutation: CanvasMutation, projectId: String) async
    /// The current snapshot, or `nil` before the first load.
    func snapshot() async -> Workspace?
    /// A single project by id from the current snapshot.
    func project(id: String) async -> Project?
}

// MARK: - Agent status reducer (SPEC §6.3)

/// Reduces the `agent:status` stream into per-node `(state, unread, …)` per the normative badge
/// machine (SPEC §6.3), and folds in `context:update`. Implementations SHOULD be actors.
public protocol AgentStatusReducing: Sendable {
    /// Fold one `agent:status` event. `onScreen` decides whether a working→(done|waiting|blocked)
    /// edge sets `unread` (§6.3 rule 8).
    func ingest(_ event: AgentStatusEvent, onScreen: Bool) async
    /// Fold a `context:update` payload into the node's meter (§6.3 / §11.6).
    func ingestContext(_ usage: ContextWindowUsage) async
    /// Clear unread WITHOUT re-acking — for an `agent:unread-clear` event (§6.3 rule 8).
    func clearUnread(nodeId: String) async
    /// The user viewed the session: clear unread. Returns `true` iff the node is `done` and the
    /// caller should now send `agent:ack-done` (§5.3/§6.3 rule 8).
    func markViewed(nodeId: String) async -> Bool

    /// Reduced status for one node (`nil` = never seen ⇒ unknown).
    func status(for nodeId: String) async -> AgentNodeStatus?
    /// All reduced statuses (for the sessions list grouping/sort, §6.3).
    func all() async -> [AgentNodeStatus]
}

// MARK: - Terminal session control — the co-attach VIEWER contract (SPEC §7)

/// The viewer-only terminal lifecycle (SPEC §7). Deliberately OMITS `pty:destroy`, `pty:recycle`
/// and `pty:flow` — those are owner actions the phone MUST NOT perform in v0 (§7.4/§7.9).
/// Implementations map onto `RpcClienting`.
public protocol TerminalSessionControlling: Sendable {
    /// `pty:create` join/spawn (§7.1). Refusals come back in-band on the result
    /// (`closed`/`unavailable`), NOT as thrown errors (§5.1).
    func create(_ options: PtyCreateOptions) async throws -> PtyCreateResult
    /// `pty:write` CAST — raw keystrokes (§7.6). Shift+Enter is sent here as `\u{1b}\r` (§7.6).
    func write(sessionId: String, data: String) async
    /// `pty:resize` CAST — a REPORT, not a command (§7.3). Pass `cols`/`rows` present for a real
    /// size; pass BOTH `nil` for the PARK signal (literal JSON nulls, NOT listed in `undef`, §7.3).
    /// `viewerId` MUST match the one used at `create` and is omitted via `undef` when nil.
    func resize(sessionId: String, cols: Int?, rows: Int?, viewerId: String?) async
    /// Convenience PARK: `resize(sessionId, nil, nil, viewerId)` (§7.3). Use on background/off-screen.
    func park(sessionId: String, viewerId: String?) async
    /// `pty:kill` CAST — detaches ONLY this viewer's `(clientId, viewerId)` slot (§7.4). `viewerId`
    /// MUST match `create`'s. The phone MUST NOT call destroy/recycle.
    func kill(sessionId: String, viewerId: String?) async
    /// `pty:read-scrollback` REQ — persisted snapshot (≤256 KB) for a `fresh:true` cold replay;
    /// `""` if none (§5.1/§7.2).
    func readScrollback(persistKey: String) async throws -> String
    /// `pty:send-text` REQ — framed, multi-line-safe delivery (§7.6). `enter` defaults **true**;
    /// pass `nil` to omit it via `undef`. Returns `false` when unavailable.
    func sendText(persistKey: String, text: String, enter: Bool?) async throws -> Bool
    /// `pty:capture` REQ — visible buffer (`full == true` → whole scrollback) (§5.1).
    func capture(persistKey: String, full: Bool?) async throws -> String
    /// `pty:pane-command` REQ — pane foreground command; `nil` = unknown (§5.1).
    func paneCommand(persistKey: String) async throws -> String?
    /// `pty:tmux-status` REQ — "tmux not found" banner data (§5.1/§11.5).
    func tmuxStatus() async throws -> TmuxStatus
}

// MARK: - Speech / dictation (SPEC §5.5 / §9.5)

/// Voice-to-text. Two implementations: Apple `SFSpeechRecognizer` (default, on-device) and the
/// server-side whisper engine via `speech:transcribe` (§5.5). Both take a FINISHED mono 16 kHz
/// Int16-LE PCM buffer and return text; the server path base64-encodes it and bounds it to ~2 min
/// so the frame stays under the 8 MiB inbound cap (§5.5/§4.10). Nothing auto-submits (§9.5).
public protocol SpeechTranscribing: Sendable {
    /// Transcribe finished PCM (Int16 LE, 16 kHz, mono) to text.
    func transcribe(pcm: Data, language: String?) async throws -> String
    /// Server whisper models (`speech:models`, §5.5). The Apple engine returns `[]`.
    func availableModels() async throws -> [SpeechModelInfo]
}
