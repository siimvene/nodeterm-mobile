import Foundation

// The per-server workspace store (SPEC §8.1 `WorkspaceStore` / §6.4). An actor holding the last
// `workspace:load` snapshot and keeping the node list live by applying `canvas:mut` deltas
// (SPEC §6.4). There is NO server-side workspace watcher — `workspace:external-change` is never
// broadcast (SPEC §5.2) — so `canvas:mut` (plus a re-`workspace:load` on doubt) is the only live
// path.
//
// v0 rows show the persisted node `title` as the session name: live session names are unavailable
// on this branch and `sessionTitle` on `agent:status` is a documented TRAP that never arrives
// (SPEC §5.1/§6.2). This store therefore preserves each node's `title` verbatim.

/// Actor implementing `WorkspaceStoring` (SPEC §6.4). Read-only from the phone's side —
/// `workspace:save` MUST NOT be called in v0 (SPEC §5.2); this store never mutates the server.
public actor WorkspaceStore: WorkspaceStoring {
    private var workspace: Workspace?

    public init() {}

    /// Adopt a fresh `workspace:load` result, dropping render-only nodes defensively (SPEC §6.4).
    public func replace(with workspace: Workspace) async {
        self.workspace = Self.sanitize(workspace)
    }

    /// Apply a `canvas:mut` delta to the named project (SPEC §6.4). `upsert` replaces-or-appends
    /// by node id; `remove` drops by id; an unrecognized `op` is ignored (tolerant, SPEC §6.4).
    /// `seq` is server-authoritative and not used for ordering here (SPEC §6.4/§11.9). No snapshot
    /// yet, or an unknown project id ⇒ no-op (the caller re-runs `workspace:load` on doubt).
    public func apply(_ mutation: CanvasMutation, projectId: String) async {
        guard var ws = workspace,
              let pIdx = ws.projects.firstIndex(where: { $0.id == projectId }) else { return }
        var project = ws.projects[pIdx]
        switch mutation {
        case let .upsert(node, _):
            // Render-only kinds never appear in a persisted workspace or a mutation (SPEC §6.4);
            // drop defensively so an unexpected one never lands in the node list.
            if Self.isRenderOnly(node.kind) { return }
            if let nIdx = project.nodes.firstIndex(where: { $0.id == node.id }) {
                project.nodes[nIdx] = node
            } else {
                project.nodes.append(node)
            }
        case let .remove(id, _):
            project.nodes.removeAll { $0.id == id }
        case .unknown:
            return
        }
        ws.projects[pIdx] = project
        workspace = ws
    }

    /// The current snapshot, or `nil` before the first load (SPEC §6.4).
    public func snapshot() async -> Workspace? { workspace }

    /// A single project by id from the current snapshot (SPEC §6.4).
    public func project(id: String) async -> Project? {
        workspace?.projects.first { $0.id == id }
    }

    // MARK: - Render-only filtering (SPEC §6.4)

    /// `subagent`/`loop` are render-only and never persisted (SPEC §6.4). `NodeKind` has no case
    /// for them, so they decode to `.unknown("subagent")` / `.unknown("loop")` — filter those.
    static func isRenderOnly(_ kind: NodeKind) -> Bool {
        if case let .unknown(raw) = kind { return raw == "subagent" || raw == "loop" }
        return false
    }

    /// Strip any render-only nodes from every project on load (SPEC §6.4).
    static func sanitize(_ workspace: Workspace) -> Workspace {
        var out = workspace
        out.projects = workspace.projects.map { project in
            var p = project
            p.nodes = project.nodes.filter { !isRenderOnly($0.kind) }
            return p
        }
        return out
    }
}
