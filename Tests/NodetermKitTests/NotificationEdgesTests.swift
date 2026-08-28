import Testing
@testable import NodetermKit

private func nn(_ srv: String, _ node: String, _ state: ReducedAgentState, unread: Bool) -> NotifyNode {
    NotifyNode(key: "\(srv)/\(node)", serverId: srv, nodeId: node, state: state, unread: unread)
}
private func map(_ xs: [NotifyNode]) -> [String: NotifyNode] { Dictionary(uniqueKeysWithValues: xs.map { ($0.key, $0) }) }
private let allOn = NotifyPrefs(onFinished: true, onNeedsYou: true)

@Test func fires_on_finished_and_needsyou_transitions() {
    let prev = map([nn("s1", "a", .working, unread: false), nn("s1", "b", .working, unread: false)])
    let cur = map([nn("s1", "a", .done, unread: true), nn("s1", "b", .blocked, unread: true)])
    let out = pendingNotifications(previous: prev, current: cur, prefs: allOn)
    #expect(out.map { $0.kind } == [.finished, .needsYou])
    #expect(out.map { $0.key } == ["s1/a", "s1/b"])
}

@Test func does_not_refire_the_same_kind() {
    let prev = map([nn("s1", "a", .done, unread: true)])
    let cur = map([nn("s1", "a", .done, unread: true)])
    #expect(pendingNotifications(previous: prev, current: cur, prefs: allOn).isEmpty)
}

@Test func needsYou_then_done_STILL_fires_done_even_though_unread_never_cleared() {
    // The consort finding: sticky unread must not swallow the completion notification.
    let prev = map([nn("s1", "a", .waiting, unread: true)])   // already notified needsYou
    let cur = map([nn("s1", "a", .done, unread: true)])       // unread never cleared
    let out = pendingNotifications(previous: prev, current: cur, prefs: allOn)
    #expect(out.map { $0.kind } == [.finished])
}

@Test func a_node_arriving_already_notifiable_fires_once() {
    let out = pendingNotifications(previous: [:], current: map([nn("s1", "a", .waiting, unread: true)]), prefs: allOn)
    #expect(out.map { $0.kind } == [.needsYou])
}

@Test func prefs_gate_each_kind() {
    let cur = map([nn("s1", "a", .done, unread: true), nn("s1", "b", .waiting, unread: true)])
    #expect(pendingNotifications(previous: [:], current: cur, prefs: NotifyPrefs(onFinished: false, onNeedsYou: true)).map { $0.key } == ["s1/b"])
    #expect(pendingNotifications(previous: [:], current: cur, prefs: NotifyPrefs(onFinished: true, onNeedsYou: false)).map { $0.key } == ["s1/a"])
}

@Test func on_screen_node_never_notifies_unread_is_false() {
    // unread is the reducer's off-screen gate; a viewed session has unread=false.
    #expect(pendingNotifications(previous: [:], current: map([nn("s1", "a", .done, unread: false)]), prefs: allOn).isEmpty)
}

@Test func two_servers_sharing_a_node_id_do_not_collide() {
    let cur = map([nn("s1", "abc", .done, unread: true), nn("s2", "abc", .waiting, unread: true)])
    let out = pendingNotifications(previous: [:], current: cur, prefs: allOn)
    #expect(out.count == 2)
    #expect(Set(out.map { $0.key }) == ["s1/abc", "s2/abc"])
}

@Test func badge_counts_unread_across_servers() {
    let s = map([nn("s1", "a", .done, unread: true), nn("s1", "b", .done, unread: false), nn("s2", "c", .waiting, unread: true)])
    #expect(unreadBadgeCount(s) == 2)
}
