import Foundation
import NodetermKit

// Framework-free (see StoresAgentStatusReducerTests.swift). WorkspaceStore coverage (SPEC §6.4):
// render-only filtering, node.title preserved as the v0 session name, canvas:mut apply.

private func check(_ cond: Bool, _ label: String) { precondition(cond, "FAIL: \(label)") }
private func checkEq<T: Equatable>(_ a: T, _ b: T, _ label: String) {
    precondition(a == b, "FAIL: \(label) — got \(a), want \(b)")
}

private func term(_ id: String, title: String = "t") -> CanvasNodeState {
    CanvasNodeState(id: id, kind: .terminal, title: title, color: "#fff")
}
private func ws(_ nodes: [CanvasNodeState], projectId: String = "p1") -> Workspace {
    Workspace(version: 2, activeProjectId: projectId,
              projects: [Project(id: projectId, name: "P", color: "#000", nodes: nodes)])
}

public func runStoresWorkspaceTests() async {
    await testSnapshotNilBeforeLoad()
    await testReplaceKeepsNodeTitle()
    await testReplaceDropsRenderOnly()
    await testApplyUpsertAppendThenReplace()
    await testApplyRemove()
    await testApplyUpsertRenderOnlyIgnored()
    await testApplyUnknownOpNoOp()
    await testApplyBeforeLoadOrUnknownProject()
}

private func testSnapshotNilBeforeLoad() async {
    let store = WorkspaceStore()
    check(await store.snapshot() == nil, "snapshot nil before load")
}

private func testReplaceKeepsNodeTitle() async {
    // v0 rows show the persisted node `title` (SPEC §5.1/§6.2 — sessionTitle never arrives).
    let store = WorkspaceStore()
    await store.replace(with: ws([term("nt-1", title: "my session")]))
    let p = await store.project(id: "p1")
    checkEq(p?.nodes.first?.title, "my session", "node.title preserved as session name")
}

private func testReplaceDropsRenderOnly() async {
    let sub = CanvasNodeState(id: "s1", kind: NodeKind(wire: "subagent"), title: "x", color: "#0")
    let loop = CanvasNodeState(id: "l1", kind: NodeKind(wire: "loop"), title: "x", color: "#0")
    let store = WorkspaceStore()
    await store.replace(with: ws([term("nt-1"), sub, loop]))
    let p = await store.project(id: "p1")
    checkEq(p?.nodes.map(\.id) ?? [], ["nt-1"], "render-only nodes filtered on load")
}

private func testApplyUpsertAppendThenReplace() async {
    let store = WorkspaceStore()
    await store.replace(with: ws([term("nt-1")]))
    await store.apply(.upsert(node: term("nt-2", title: "second"), seq: 5), projectId: "p1")
    var p = await store.project(id: "p1")
    checkEq(p?.nodes.map(\.id) ?? [], ["nt-1", "nt-2"], "upsert appends new node")
    await store.apply(.upsert(node: term("nt-1", title: "renamed"), seq: 6), projectId: "p1")
    p = await store.project(id: "p1")
    checkEq(p?.nodes.count, 2, "upsert existing id replaces in place")
    checkEq(p?.nodes.first(where: { $0.id == "nt-1" })?.title, "renamed", "replaced title")
}

private func testApplyRemove() async {
    let store = WorkspaceStore()
    await store.replace(with: ws([term("nt-1"), term("nt-2")]))
    await store.apply(.remove(id: "nt-1", seq: 1), projectId: "p1")
    let p = await store.project(id: "p1")
    checkEq(p?.nodes.map(\.id) ?? [], ["nt-2"], "remove drops node by id")
}

private func testApplyUpsertRenderOnlyIgnored() async {
    let store = WorkspaceStore()
    await store.replace(with: ws([term("nt-1")]))
    let sub = CanvasNodeState(id: "s1", kind: NodeKind(wire: "subagent"), title: "x", color: "#0")
    await store.apply(.upsert(node: sub, seq: 2), projectId: "p1")
    let p = await store.project(id: "p1")
    checkEq(p?.nodes.map(\.id) ?? [], ["nt-1"], "render-only upsert ignored")
}

private func testApplyUnknownOpNoOp() async {
    let store = WorkspaceStore()
    await store.replace(with: ws([term("nt-1")]))
    await store.apply(.unknown(op: "reorder"), projectId: "p1")
    let p = await store.project(id: "p1")
    checkEq(p?.nodes.map(\.id) ?? [], ["nt-1"], "unknown op tolerated")
}

private func testApplyBeforeLoadOrUnknownProject() async {
    let store = WorkspaceStore()
    await store.apply(.upsert(node: term("nt-9"), seq: 1), projectId: "p1")
    check(await store.snapshot() == nil, "apply before load ⇒ no-op")
    await store.replace(with: ws([term("nt-1")]))
    await store.apply(.remove(id: "nt-1", seq: 1), projectId: "other")
    let p = await store.project(id: "p1")
    checkEq(p?.nodes.map(\.id) ?? [], ["nt-1"], "unknown project id ⇒ no-op")
}
