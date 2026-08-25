import Foundation

/// Wire constants shared by all builders. Every value cites its spec section so a reviewer can
/// check it against the source of truth without re-deriving it.
public enum NodetermWire {

    // MARK: Escape sequences

    /// `CO_ATTACH_MOUSE_SEQ` — enable tmux mouse tracking after a seed paint so wheel/touch drives
    /// copy-mode history (SPEC §7.2 step 5). Idempotent.
    public static let coAttachMouseSeq = "\u{1b}[?1000h\u{1b}[?1002h\u{1b}[?1006h"

    /// Shift+Enter → ESC+CR, so agent CLIs insert a newline instead of submitting (SPEC §7.6).
    public static let shiftEnterSeq = "\u{1b}\r"

    // MARK: WS endpoint

    /// The only upgraded WS path (SPEC §4.1).
    public static let webSocketPath = "/ws"

    // MARK: Size / buffer limits

    /// Early-event buffer cap, drop-oldest (SPEC §4.9).
    public static let earlyEventBufferCap = 4096
    /// Max inbound WS frame; larger closes the socket with code 1009 (SPEC §4.10).
    public static let maxPayloadBytes = 8 * 1024 * 1024
    /// Persisted scrollback snapshot cap (SPEC §5.1/§7.2).
    public static let scrollbackSnapshotCap = 256 * 1024
    /// Server heartbeat interval; a silent peer is reaped in 30–60 s (SPEC §4.7).
    public static let heartbeatMs = 30_000
    /// Auth lockout window after 5 consecutive failures (SPEC §3.3), global.
    public static let loginLockoutMs = 60_000
    /// Absolute session TTL (SPEC §2.2/§3.5).
    public static let sessionTTLDays = 30

    /// Reconnect backoff (SPEC §4.8): `min(1000 · 2^attempt, 10_000)` ms.
    public static func reconnectDelayMs(attempt: Int) -> Int {
        let capped = min(attempt, 30) // guard against overflow on a long-lived offline server
        return min(1000 * (1 << capped), 10_000)
    }

    // MARK: Cookie

    /// The session cookie name (SPEC §2.2).
    public static let sessionCookieName = "nt_session"
}

/// The exact RPC method strings (SPEC §5). Centralized so a typo can't diverge across builders.
public enum RpcMethod {
    // pty (§5.1)
    public static let ptyCreate = "pty:create"
    public static let ptyWrite = "pty:write"
    public static let ptyResize = "pty:resize"
    public static let ptyKill = "pty:kill"
    public static let ptyReadScrollback = "pty:read-scrollback"
    public static let ptySendText = "pty:send-text"
    public static let ptyCapture = "pty:capture"
    public static let ptyPaneCommand = "pty:pane-command"
    public static let ptyTmuxStatus = "pty:tmux-status"

    // workspace / settings (§5.2) — read-only for the phone
    public static let workspaceLoad = "workspace:load"
    public static let settingsLoad = "settings:load"

    // agent status & approvals (§5.3)
    public static let agentAnswerPermission = "agent:answer-permission"
    public static let agentAckDone = "agent:ack-done"

    // transcript (§5.4)
    public static let chatReadTranscript = "chat:read-transcript"
    public static let claudeReadTranscript = "claude:read-transcript"

    // speech (§5.5)
    public static let speechTranscribe = "speech:transcribe"
    public static let speechModels = "speech:models"
    public static let speechModelDownload = "speech:model-download"
    public static let speechModelDelete = "speech:model-delete"
    public static let speechMicConsent = "speech:mic-consent"
}
