import Foundation

/// Options for `pty:create` (SPEC §5.1 / §7.1 / §11.5).
///
/// The phone normally sends only `{cols, rows, persistKey, viewerId}` for a warm co-attach join,
/// but SHOULD also pass the node's `cwd`, `agentId`, `accountId` and `ownerProjectId` so that a
/// cold `fresh:true` spawn (host reboot, phone-first open) lands in the right directory/shell
/// rather than the server's `$HOME` (§7.1 — the wrong session becomes permanent via `tmux -A`).
public struct PtyCreateOptions: Codable, Sendable, Equatable {
    public var shell: String?
    public var shellArgs: [String]?
    public var cwd: String?
    public var cols: Int          // required (§11.5)
    public var rows: Int          // required (§11.5)
    public var persistKey: String?
    public var ownerProjectId: String?
    public var agentId: String?
    public var agentModel: String?
    public var accountId: String?
    /// Unique within THIS connection (e.g. a UUID per attach). Omitting it claims the connection's
    /// PRIMARY view slot (§7.1). Never collides with the desktop (a different clientId).
    public var viewerId: String?
    /// Opaque ssh-master descriptor. The phone MUST NEVER set this (§7.1); modeled for fidelity.
    public var sshRemote: JSONValue?
    /// For a node with `sshRemoteTmux:true` (or an `ssh` project) pass `true` so the server REFUSES
    /// instead of spawning a phantom local shell under the remote node's id (§7.1).
    public var requireRemote: Bool?

    public init(
        cols: Int,
        rows: Int,
        persistKey: String? = nil,
        viewerId: String? = nil,
        cwd: String? = nil,
        shell: String? = nil,
        shellArgs: [String]? = nil,
        ownerProjectId: String? = nil,
        agentId: String? = nil,
        agentModel: String? = nil,
        accountId: String? = nil,
        sshRemote: JSONValue? = nil,
        requireRemote: Bool? = nil
    ) {
        self.cols = cols
        self.rows = rows
        self.persistKey = persistKey
        self.viewerId = viewerId
        self.cwd = cwd
        self.shell = shell
        self.shellArgs = shellArgs
        self.ownerProjectId = ownerProjectId
        self.agentId = agentId
        self.agentModel = agentModel
        self.accountId = accountId
        self.sshRemote = sshRemote
        self.requireRemote = requireRemote
    }
}

/// Cursor position returned in `PtyCreateResult` / used when seed-painting (SPEC §7.2, 0-based).
public struct PtyCursor: Codable, Sendable, Equatable, Hashable {
    public var x: Int
    public var y: Int
    public var visible: Bool
    public init(x: Int, y: Int, visible: Bool) {
        self.x = x; self.y = y; self.visible = visible
    }
}

/// The `closed` sub-object of `PtyCreateResult` / the `pty:closed:<sid>` payload (SPEC §6.1/§11.5).
public struct PtyClosedInfo: Codable, Sendable, Equatable, Hashable {
    /// Client id that destroyed the node, or `null`. Distinct from absent, but both mean "unknown".
    public var by: Int?
    public init(by: Int? = nil) { self.by = by }
}

/// Result of `pty:create` (SPEC §7.2 / §11.5). `sessionId == ""` ⇔ REFUSED (`closed`/`unavailable`
/// set); handle refusals in-band, they are NOT RPC errors (§5.1).
public struct PtyCreateResult: Codable, Sendable, Equatable {
    public var sessionId: String
    public var fresh: Bool
    /// Present when the requested managed account was unavailable and a fallback was used. Shape is
    /// unpinned in the spec; kept generic so an unknown wire shape never fails decoding.
    public var accountFallback: JSONValue?
    /// `capture-pane` seed screen (LF-separated, no CR). Paint FIRST when present, before the live
    /// stream (§7.2). Absent ⇒ the pty resized down to you and tmux is redrawing — paint nothing.
    public var screen: String?
    public var cursor: PtyCursor?
    /// When true, write `CO_ATTACH_MOUSE_SEQ` after the seed paint so wheel/touch drives tmux
    /// copy-mode history (§7.2 step 5).
    public var coAttachMouse: Bool?
    /// `false` ⇒ no tmux underneath (plain shell); treat as non-droppable (§7.10). Absent ⇒ unknown
    /// ⇒ assume persistent, never protect on a guess.
    public var persistent: Bool?
    /// Set ⇒ node was permanently destroyed elsewhere; show "closed", do not respawn (§7.2 step 1).
    public var closed: PtyClosedInfo?
    /// Set ⇒ session cannot run here; value is `'ssh'` or `'codex-account'` (§11.5). Show "not
    /// available" and wait.
    public var unavailable: String?

    public init(
        sessionId: String,
        fresh: Bool,
        accountFallback: JSONValue? = nil,
        screen: String? = nil,
        cursor: PtyCursor? = nil,
        coAttachMouse: Bool? = nil,
        persistent: Bool? = nil,
        closed: PtyClosedInfo? = nil,
        unavailable: String? = nil
    ) {
        self.sessionId = sessionId
        self.fresh = fresh
        self.accountFallback = accountFallback
        self.screen = screen
        self.cursor = cursor
        self.coAttachMouse = coAttachMouse
        self.persistent = persistent
        self.closed = closed
        self.unavailable = unavailable
    }

    /// True when `pty:create` refused (empty sessionId with `closed`/`unavailable` set, §11.5).
    public var isRefusal: Bool { sessionId.isEmpty && (closed != nil || unavailable != nil) }
}

/// `TmuxStatus` from `pty:tmux-status` (SPEC §11.5). `platform == nil` means the read FAILED — do
/// NOT substitute the phone's platform. (`installCommand`/`installLabel`/`platform` null ≡ absent
/// for a consumer: both surface as `nil`.)
public struct TmuxStatus: Codable, Sendable, Equatable, Hashable {
    public var available: Bool
    public var installCommand: String?
    public var installLabel: String?
    public var platform: String?
    public init(available: Bool, installCommand: String? = nil,
                installLabel: String? = nil, platform: String? = nil) {
        self.available = available
        self.installCommand = installCommand
        self.installLabel = installLabel
        self.platform = platform
    }
}

/// `RecycledInfo` — payload of `pty:recycled:<sid>` (SPEC §6.1/§11.5). `ready:true` → re-create to
/// co-attach the replacement; `false` → do NOT respawn.
public struct RecycledInfo: Codable, Sendable, Equatable, Hashable {
    public var ready: Bool
    public init(ready: Bool) { self.ready = ready }
}

/// Authoritative co-attach grid — payload of `pty:size:<sid>` (SPEC §6.1/§7.3). On receipt, resize
/// the emulator to exactly this grid and letterbox the slack; never drive your own local fit.
public struct PtyGrid: Codable, Sendable, Equatable, Hashable {
    public var cols: Int
    public var rows: Int
    public init(cols: Int, rows: Int) { self.cols = cols; self.rows = rows }
}

/// Payload of `pty:exit:<sid>` (SPEC §6.1). NOTE: the exact shape is flagged UNVERIFIED in the spec
/// (§12 item 7) — modeled here as `{exitCode}`; verify against a live server before rendering codes.
public struct PtyExitInfo: Codable, Sendable, Equatable, Hashable {
    public var exitCode: Int
    public init(exitCode: Int) { self.exitCode = exitCode }
}
