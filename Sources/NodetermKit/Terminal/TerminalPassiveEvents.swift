import Foundation

/// What the App should do on a passive close event (SPEC §7.5).
public enum PassiveCloseDecision: Sendable, Equatable {
    /// `pty:closed:<sid>` — node permanently destroyed elsewhere. Show "closed", do NOT respawn.
    case showClosed(by: Int?)
    /// `pty:recycled:<sid>` `{ready:true}` — re-`pty:create` to co-attach the replacement.
    case recreate
    /// `pty:recycled:<sid>` `{ready:false}` — do NOT respawn.
    case doNotRespawn
}

/// Pure classification of the passive close channels (SPEC §7.5). The App subscribes
/// `pty:closed:<sid>` and `pty:recycled:<sid>` and feeds the decoded payloads here.
public enum TerminalPassiveEvents {

    /// `pty:closed:<sid>` → always show "closed", never respawn (SPEC §7.5).
    public static func classifyClosed(_ info: PtyClosedInfo) -> PassiveCloseDecision {
        .showClosed(by: info.by)
    }

    /// `pty:recycled:<sid>` → recreate iff `ready` (SPEC §7.5).
    public static func classifyRecycled(_ info: RecycledInfo) -> PassiveCloseDecision {
        info.ready ? .recreate : .doNotRespawn
    }

    /// True iff this decision means the App should re-issue `pty:create` (SPEC §7.5). The single
    /// gate the App reads so "recreate" can never be confused with "closed"/"not ready".
    public static func shouldRecreate(_ decision: PassiveCloseDecision) -> Bool {
        decision == .recreate
    }
}
