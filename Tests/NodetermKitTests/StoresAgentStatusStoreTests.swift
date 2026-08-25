import Foundation
import NodetermKit

// Framework-free (see StoresAgentStatusReducerTests.swift). Actor-level coverage of
// AgentStatusStore (SPEC §6.3/§8.1): injected clock, context merge, ack/unread, sweep, tolerant decode.

private func check(_ cond: Bool, _ label: String) { precondition(cond, "FAIL: \(label)") }
private func checkEq<T: Equatable>(_ a: T, _ b: T, _ label: String) {
    precondition(a == b, "FAIL: \(label) — got \(a), want \(b)")
}

/// Mutable millisecond clock injected into the store. `@unchecked Sendable` is safe: `_now` is only
/// mutated from the single test task between `await` points, and every access is lock-guarded — no
/// concurrent writer exists (SPEC §6.3 rule 5 requires an injected clock, never `Date()` inline).
private final class ClockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Int
    init(_ now: Int = 0) { _now = now }
    var now: Int {
        get { lock.lock(); defer { lock.unlock() }; return _now }
        set { lock.lock(); _now = newValue; lock.unlock() }
    }
}

private func event(_ node: String = "n1", state: AgentState? = nil, kind: AgentEventKind = .state,
                   sessionId: String? = nil, idle: Bool? = nil, interrupted: Bool? = nil,
                   newTurn: Bool? = nil, pendingId: String? = nil) -> AgentStatusEvent {
    AgentStatusEvent(nodeId: node, agentId: "claude", kind: kind, state: state,
                     interrupted: interrupted, idle: idle, newTurn: newTurn,
                     sessionId: sessionId, pendingId: pendingId)
}

public func runStoresStoreTests() async {
    await testUnknownNodeStatusIsNil()
    await testIngestExposesBadgeAndPending()
    await testDoneHoldoffThroughStoreWithInjectedClock()
    await testContextMergeBothOrders()
    await testMarkViewedAcksOnlyDone()
    await testClearUnreadDoesNotAck()
    await testSweepStaleWorkingAcrossStore()
    await testRawIngestTolerantOfGarbage()
}

private func testUnknownNodeStatusIsNil() async {
    let store = AgentStatusStore()
    let s = await store.status(for: "nope")
    check(s == nil, "unknown node ⇒ nil status")
}

private func testIngestExposesBadgeAndPending() async {
    let store = AgentStatusStore()
    await store.ingest(event(state: .blocked, pendingId: "p1"), onScreen: false)
    let s = await store.status(for: "n1")
    checkEq(s?.state, .blocked, "state exposed")
    checkEq(s?.badge, .needsYou, "blocked ⇒ NEEDS YOU badge")
    checkEq(s?.pendingId, "p1", "pendingId exposed")
}

private func testDoneHoldoffThroughStoreWithInjectedClock() async {
    let clock = ClockBox(0)
    let store = AgentStatusStore(clock: { clock.now })
    clock.now = 0
    await store.ingest(event(state: .working), onScreen: false)
    await store.ingest(event(state: .done), onScreen: false)
    clock.now = 2999
    await store.ingest(event(state: .working), onScreen: false)
    var s = await store.status(for: "n1")
    checkEq(s?.state, .done, "held off within 3000 ms via injected clock")
    clock.now = 3001
    await store.ingest(event(state: .working), onScreen: false)
    s = await store.status(for: "n1")
    checkEq(s?.state, .working, "adopted after holdoff")
}

private func testContextMergeBothOrders() async {
    let store = AgentStatusStore()
    let usage = ContextWindowUsage(sessionId: "sess-1", usedTokens: 100, windowTokens: 1000,
                                   usedPercent: 10, model: "claude", updatedAt: 5)
    await store.ingestContext(usage)                                   // context BEFORE node known
    await store.ingest(event(state: .working, sessionId: "sess-1"), onScreen: false)
    var s = await store.status(for: "n1")
    checkEq(s?.context, usage, "context buffered before node merges by sessionId")

    await store.ingest(event("n2", state: .working, sessionId: "sess-2"), onScreen: false)
    let usage2 = ContextWindowUsage(sessionId: "sess-2", usedTokens: 500, windowTokens: 1000,
                                    usedPercent: 50, updatedAt: 9)
    await store.ingestContext(usage2)                                  // context AFTER node known
    s = await store.status(for: "n2")
    checkEq(s?.context, usage2, "context after node merges by sessionId")
}

private func testMarkViewedAcksOnlyDone() async {
    let store = AgentStatusStore()
    await store.ingest(event(state: .working), onScreen: false)
    await store.ingest(event(state: .done), onScreen: false)
    var s = await store.status(for: "n1")
    check(s?.unread ?? false, "working→done offscreen ⇒ unread")
    let ackDone = await store.markViewed(nodeId: "n1")
    check(ackDone, "viewing a done node ⇒ ack-done")
    s = await store.status(for: "n1")
    check(!(s?.unread ?? true), "view clears unread")

    await store.ingest(event("n2", state: .working), onScreen: false)
    await store.ingest(event("n2", state: .waiting), onScreen: false)
    let ackWaiting = await store.markViewed(nodeId: "n2")
    check(!ackWaiting, "waiting node ⇒ no ack")

    let ackUnknown = await store.markViewed(nodeId: "ghost")
    check(!ackUnknown, "unknown node ⇒ no ack")
}

private func testClearUnreadDoesNotAck() async {
    let store = AgentStatusStore()
    await store.ingest(event(state: .working), onScreen: false)
    await store.ingest(event(state: .done), onScreen: false)
    await store.clearUnread(nodeId: "n1")
    let s = await store.status(for: "n1")
    check(!(s?.unread ?? true), "unread-clear drops unread without acking")
    checkEq(s?.state, .done, "clearUnread leaves state alone")
}

private func testSweepStaleWorkingAcrossStore() async {
    let clock = ClockBox(0)
    let store = AgentStatusStore(clock: { clock.now }, staleThresholdMs: 1000)
    clock.now = 0
    await store.ingest(event(state: .working), onScreen: false)
    clock.now = 2000
    await store.sweepStaleWorking()
    let s = await store.status(for: "n1")
    checkEq(s?.state, .unknown, "stale working decays to unknown")
}

private func testRawIngestTolerantOfGarbage() async {
    let store = AgentStatusStore()
    await store.ingestRawStatus([.string("garbage")], onScreen: false)
    await store.ingestRawStatus([], onScreen: false)
    var all = await store.all()
    check(all.isEmpty, "garbage frames create no state")

    let obj: JSONValue = .object([
        "nodeId": "n1", "agentId": "claude", "kind": "state", "state": "working"
    ])
    await store.ingestRawStatus([obj], onScreen: false)
    all = await store.all()
    checkEq(all.count, 1, "well-formed event ingested")
    checkEq(all.first?.state, .working, "decoded state")

    await store.ingestRawContext([.string("nope")])   // must not crash
}
