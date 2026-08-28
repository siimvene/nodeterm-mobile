import Foundation

/// Which local notifications to fire from a batch of agent-status changes — pure so it is unit
/// tested without UNUserNotificationCenter.
///
/// The trigger is a STATE TRANSITION into a notifiable state, gated by `unread` (the reducer sets
/// `unread` only on an OFF-SCREEN busy→idle edge, SPEC §6.3 #8, so an actively-viewed session
/// never notifies). Keying on the state transition — not on a sticky `unread` false→true flip —
/// means a needsYou→working→done sequence still fires the completion notification even though
/// `unread` never cleared in between (consort finding).
public enum NotifyKind: String, Sendable, Equatable {
    case finished    // → done
    case needsYou    // → waiting/blocked
}

public struct PendingNotification: Sendable, Equatable {
    /// Composite (serverId, nodeId): node ids are only per-launch unique, so two servers can share
    /// one (consort finding). This is the notification identifier and the badge/title key.
    public let key: String
    public let serverId: String
    public let nodeId: String
    public let kind: NotifyKind
}

public struct NotifyPrefs: Sendable, Equatable {
    public var onFinished: Bool
    public var onNeedsYou: Bool
    public init(onFinished: Bool, onNeedsYou: Bool) {
        self.onFinished = onFinished
        self.onNeedsYou = onNeedsYou
    }
}

/// One node's identity + reduced state for the detector. `key` is the composite the caller owns.
public struct NotifyNode: Sendable, Equatable {
    public let key: String
    public let serverId: String
    public let nodeId: String
    public let state: ReducedAgentState
    public let unread: Bool
    public init(key: String, serverId: String, nodeId: String, state: ReducedAgentState, unread: Bool) {
        self.key = key; self.serverId = serverId; self.nodeId = nodeId; self.state = state; self.unread = unread
    }
}

private func kind(for state: ReducedAgentState) -> NotifyKind? {
    switch state {
    case .done: return .finished
    case .waiting, .blocked: return .needsYou
    default: return nil
    }
}

/// Emit one notification per node that TRANSITIONED into a notifiable state this pass (its
/// notifiable classification differs from its previous one), while `unread` is set and the pref
/// for that kind is on. Keyed by the composite `key`.
public func pendingNotifications(
    previous: [String: NotifyNode],
    current: [String: NotifyNode],
    prefs: NotifyPrefs
) -> [PendingNotification] {
    var out: [PendingNotification] = []
    for (key, cur) in current {
        guard cur.unread, let k = kind(for: cur.state) else { continue }
        // Fire only on a genuine transition INTO this notifiable kind — same kind as last pass
        // (still done, still needsYou) is not a new event.
        if let prev = previous[key], kind(for: prev.state) == k { continue }
        if k == .finished, !prefs.onFinished { continue }
        if k == .needsYou, !prefs.onNeedsYou { continue }
        out.append(PendingNotification(key: key, serverId: cur.serverId, nodeId: cur.nodeId, kind: k))
    }
    return out.sorted { $0.key < $1.key }   // deterministic for tests
}

/// App-icon badge = count of currently-unread nodes across all servers.
public func unreadBadgeCount(_ nodes: [String: NotifyNode]) -> Int {
    nodes.values.reduce(0) { $0 + ($1.unread ? 1 : 0) }
}
