import Foundation

/// Which local notifications to fire from a batch of agent-status changes — pure so it is unit
/// tested without UNUserNotificationCenter. Mirrors the desktop's "busy→idle edge while
/// unfocused" rule: the reducer already sets `unread` on exactly the notifiable edge
/// (working→done|waiting|blocked while OFF screen, SPEC §6.3 #8), so a false→true `unread`
/// transition is the trigger, and the node's reduced state classifies it.
public enum NotifyKind: String, Sendable, Equatable {
    case finished    // working → done
    case needsYou    // working → waiting/blocked
}

public struct PendingNotification: Sendable, Equatable {
    public let nodeId: String
    public let kind: NotifyKind
}

/// Toggle gate — the two existing Settings switches.
public struct NotifyPrefs: Sendable, Equatable {
    public var onFinished: Bool
    public var onNeedsYou: Bool
    public init(onFinished: Bool, onNeedsYou: Bool) {
        self.onFinished = onFinished
        self.onNeedsYou = onNeedsYou
    }
}

/// Compare a previous and current status snapshot; emit one notification per node whose `unread`
/// just went false→true (or that arrived already unread), classified by its current state and
/// filtered by prefs. A node the client is actively viewing never has `unread` set (the reducer's
/// on-screen gate), so no extra on-screen check is needed here.
public func pendingNotifications(
    previous: [String: AgentNodeStatus],
    current: [String: AgentNodeStatus],
    prefs: NotifyPrefs
) -> [PendingNotification] {
    var out: [PendingNotification] = []
    for (nodeId, cur) in current {
        guard cur.unread else { continue }
        if previous[nodeId]?.unread == true { continue }   // already-notified edge
        let kind: NotifyKind
        switch cur.state {
        case .done: kind = .finished
        case .waiting, .blocked: kind = .needsYou
        default: continue   // an unread flag without a notifiable state — skip
        }
        if kind == .finished, !prefs.onFinished { continue }
        if kind == .needsYou, !prefs.onNeedsYou { continue }
        out.append(PendingNotification(nodeId: nodeId, kind: kind))
    }
    return out.sorted { $0.nodeId < $1.nodeId }   // deterministic for tests
}

/// The app-icon badge number: the count of currently-unread nodes.
public func unreadBadgeCount(_ statuses: [String: AgentNodeStatus]) -> Int {
    statuses.values.reduce(0) { $0 + ($1.unread ? 1 : 0) }
}
