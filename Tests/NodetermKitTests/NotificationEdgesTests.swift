import Testing
@testable import NodetermKit

private func st(_ id: String, _ state: ReducedAgentState, unread: Bool) -> AgentNodeStatus {
    AgentNodeStatus(nodeId: id, state: state, unread: unread)
}

private let allOn = NotifyPrefs(onFinished: true, onNeedsYou: true)

@Test func fires_on_finished_and_needsyou_edges() {
    let prev = ["a": st("a", .working, unread: false), "b": st("b", .working, unread: false)]
    let cur = ["a": st("a", .done, unread: true), "b": st("b", .blocked, unread: true)]
    let out = pendingNotifications(previous: prev, current: cur, prefs: allOn)
    #expect(out == [PendingNotification(nodeId: "a", kind: .finished),
                    PendingNotification(nodeId: "b", kind: .needsYou)])
}

@Test func does_not_refire_an_already_unread_node() {
    let prev = ["a": st("a", .done, unread: true)]
    let cur = ["a": st("a", .done, unread: true)]
    #expect(pendingNotifications(previous: prev, current: cur, prefs: allOn).isEmpty)
}

@Test func a_node_arriving_already_unread_fires_once() {
    let out = pendingNotifications(previous: [:], current: ["a": st("a", .waiting, unread: true)], prefs: allOn)
    #expect(out == [PendingNotification(nodeId: "a", kind: .needsYou)])
}

@Test func prefs_gate_each_kind() {
    let cur = ["a": st("a", .done, unread: true), "b": st("b", .waiting, unread: true)]
    let onlyNeedsYou = NotifyPrefs(onFinished: false, onNeedsYou: true)
    #expect(pendingNotifications(previous: [:], current: cur, prefs: onlyNeedsYou)
            == [PendingNotification(nodeId: "b", kind: .needsYou)])
    let onlyFinished = NotifyPrefs(onFinished: true, onNeedsYou: false)
    #expect(pendingNotifications(previous: [:], current: cur, prefs: onlyFinished)
            == [PendingNotification(nodeId: "a", kind: .finished)])
}

@Test func unread_without_a_notifiable_state_is_skipped() {
    // Defensive: unread should never be set on a non-terminal state, but never crash/misfire.
    let out = pendingNotifications(previous: [:], current: ["a": st("a", .working, unread: true)], prefs: allOn)
    #expect(out.isEmpty)
}

@Test func badge_counts_unread_nodes() {
    let s = ["a": st("a", .done, unread: true), "b": st("b", .done, unread: false),
             "c": st("c", .waiting, unread: true)]
    #expect(unreadBadgeCount(s) == 2)
}
