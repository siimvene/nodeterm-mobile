import Testing
@testable import NodetermKit

private func event(_ node: String = "node", state: AgentState = .working) -> AgentStatusEvent {
    AgentStatusEvent(nodeId: node, agentId: "codex", kind: .state, state: state)
}

@Test func snapshotHydratesWithoutOpeningTerminal() async {
    let store = AgentStatusStore(clock: { 1_000 })
    let revision = await store.beginSnapshot()
    await store.replaceSnapshot([event()], since: revision)
    let status = await store.status(for: "node")
    #expect(status?.state == .working)
    #expect(status?.agentId == "codex")
    #expect(status?.unread == false)
}

@Test func reconnectSnapshotRemovesVanishedNodesAndOldHoldoff() async {
    let store = AgentStatusStore(clock: { 1_000 })
    await store.ingest(event(state: .done), onScreen: false)
    await store.ingest(event("vanished"), onScreen: false)
    let revision = await store.beginSnapshot()
    await store.replaceSnapshot([event()], since: revision)
    #expect(await store.status(for: "node")?.state == .working)
    #expect(await store.status(for: "vanished") == nil)
}

@Test func snapshotCannotOverwriteOrPruneNewerLiveEvents() async {
    let store = AgentStatusStore(clock: { 1_000 })
    let revision = await store.beginSnapshot()
    await store.ingest(event(state: .blocked), onScreen: false)
    await store.ingest(event("new-node"), onScreen: false)
    await store.replaceSnapshot([event()], since: revision)
    #expect(await store.status(for: "node")?.state == .blocked)
    #expect(await store.status(for: "new-node")?.state == .working)
}

@Test func obsoleteSnapshotCannotReplaceNewConnectionState() async {
    let store = AgentStatusStore(clock: { 1_000 })
    let older = await store.beginSnapshot()
    let newer = await store.beginSnapshot()
    await store.replaceSnapshot([event(state: .blocked)], since: newer)
    await store.replaceSnapshot([event()], since: older)
    #expect(await store.status(for: "node")?.state == .blocked)
}

@Test func ignoredEventsCannotBlockCurrentSnapshot() async {
    let store = AgentStatusStore(clock: { 1_000 })
    await store.ingest(event(state: .done), onScreen: false)
    let revision = await store.beginSnapshot()
    await store.ingest(AgentStatusEvent(nodeId: "node", agentId: "claude", kind: .state,
                                       state: .blocked), onScreen: false)
    await store.ingest(event(), onScreen: false) // rejected by the old DONE holdoff
    await store.ingest(AgentStatusEvent(nodeId: "fresh", agentId: "codex", kind: .state,
                                       state: .unknown("future-state")), onScreen: false)
    await store.replaceSnapshot([event(), event("fresh")], since: revision)
    #expect(await store.status(for: "node")?.state == .working)
    #expect(await store.status(for: "fresh")?.state == .working)
}

@Test func snapshotPreservesApprovalsWithoutInventingUnread() async {
    let store = AgentStatusStore(clock: { 1_000 })
    await store.ingest(event(), onScreen: false)
    let revision = await store.beginSnapshot()
    var approval = event(state: .blocked)
    approval.pendingId = "pending-1"
    approval.askKind = .approval
    await store.replaceSnapshot([approval], since: revision)
    let status = await store.status(for: "node")
    #expect(status?.pendingId == "pending-1")
    #expect(status?.askKind == .approval)
    #expect(status?.badge == .needsYou)
    #expect(status?.unread == false)
}

@Test func emptySnapshotReallyClearsReducerNotOnlyVisibleRows() async {
    let store = AgentStatusStore(clock: { 1_000 })
    await store.ingest(event(state: .blocked), onScreen: false)
    let revision = await store.beginSnapshot()
    await store.replaceSnapshot([], since: revision)
    #expect(await store.all().isEmpty)
    await store.ingest(AgentStatusEvent(nodeId: "node", agentId: "codex", kind: .session,
                                       sessionPhase: .start), onScreen: false)
    #expect(await store.status(for: "node")?.state == .unknown)
}

@Test func viewingDuringSnapshotDoesNotPreserveStaleStatus() async {
    let store = AgentStatusStore(clock: { 1_000 })
    await store.ingest(event(state: .done), onScreen: false)
    await store.ingest(event("vanished", state: .done), onScreen: false)
    let revision = await store.beginSnapshot()
    _ = await store.markViewed(nodeId: "node")
    _ = await store.markViewed(nodeId: "vanished")
    await store.replaceSnapshot([event()], since: revision)
    #expect(await store.status(for: "node")?.state == .working)
    #expect(await store.status(for: "node")?.unread == false)
    #expect(await store.status(for: "vanished") == nil)
}

@Test func unreadClearDuringSnapshotDoesNotPreserveStaleIdentity() async {
    let store = AgentStatusStore(clock: { 1_000 })
    await store.ingest(event(state: .blocked), onScreen: false)
    await store.ingest(event("vanished"), onScreen: false)
    let revision = await store.beginSnapshot()
    await store.clearUnread(nodeId: "node")
    await store.clearUnread(nodeId: "vanished")
    let current = AgentStatusEvent(nodeId: "node", agentId: "claude", kind: .state, state: .working)
    await store.replaceSnapshot([current], since: revision)
    #expect(await store.status(for: "node")?.agentId == "claude")
    #expect(await store.status(for: "node")?.state == .working)
    #expect(await store.status(for: "node")?.unread == false)
    #expect(await store.status(for: "vanished") == nil)
}

@Test func staleSweepDuringSnapshotCannotOverrideFreshServerEvidence() async {
    let store = AgentStatusStore(clock: { 1_000 }, staleThresholdMs: 100)
    await store.ingest(event(), onScreen: false)
    await store.ingest(event("vanished"), onScreen: false)
    let revision = await store.beginSnapshot()
    await store.sweepStaleWorking(now: 2_000)
    #expect(await store.status(for: "node")?.state == .unknown)
    await store.replaceSnapshot([event()], since: revision)
    #expect(await store.status(for: "node")?.state == .working)
    #expect(await store.status(for: "vanished") == nil)
}

@Test func snapshotDoneDoesNotArmTheHoldoffAgainstALiveWorking() async {
    let store = AgentStatusStore(clock: { 1_000 })
    let revision = await store.beginSnapshot()
    await store.replaceSnapshot([event(state: .done)], since: revision)
    #expect(await store.status(for: "node")?.state == .done)
    // A live `working` without newTurn, inside the 3 s window of hydration: genuine, not a straggler.
    await store.ingest(event(state: .working), onScreen: false)
    #expect(await store.status(for: "node")?.state == .working)
}

@Test func snapshotDropsUnreadAcrossASessionBoundary() async {
    let store = AgentStatusStore(clock: { 1_000 })
    var working = event(); working.sessionId = "old"
    var done = event(state: .done); done.sessionId = "old"
    await store.ingest(working, onScreen: false)
    await store.ingest(done, onScreen: false)
    #expect(await store.status(for: "node")?.unread == true)

    var same = event(state: .done); same.sessionId = "old"
    var revision = await store.beginSnapshot()
    await store.replaceSnapshot([same], since: revision)
    #expect(await store.status(for: "node")?.unread == true)

    var relaunched = event(); relaunched.sessionId = "new"
    revision = await store.beginSnapshot()
    await store.replaceSnapshot([relaunched], since: revision)
    #expect(await store.status(for: "node")?.unread == false)
}

@Test func stateLessAwaitingInputAdoptsProviderIdentity() async {
    let store = AgentStatusStore(clock: { 1_000 })
    var ask = AgentStatusEvent(nodeId: "node", agentId: "claude", kind: .state, state: nil)
    ask.awaitingInput = true
    await store.ingest(ask, onScreen: false)
    let status = await store.status(for: "node")
    #expect(status?.state == .waiting)
    #expect(status?.agentId == "claude")
}
