import Testing
@testable import NodetermKit

private func sessionRow(agentId: String? = nil, status: AgentNodeStatus? = nil) -> SessionRow {
    SessionRow(serverId: "server", serverName: "Server", projectId: "project",
               projectName: "Project", nodeId: "node", title: "Fix authentication",
               agentId: agentId, status: status)
}

@Test func sessionRowsNameAgentsWithoutOpeningTerminals() {
    for (id, label) in [("claude", "Claude Code"), ("codex", "Codex"), ("gemini", "Gemini"),
                        ("grok", "Grok"), ("opencode", "OpenCode"), ("copilot", "Copilot")] {
        let row = sessionRow(agentId: id)
        #expect(row.agentLabel == label)
        #expect(row.effectiveAgentId == id)
        #expect(row.badge == .none)
    }
    #expect(sessionRow().agentLabel == "Shell")
    #expect(sessionRow(agentId: "").agentLabel == "Shell")
    #expect(sessionRow(agentId: "team-helper").agentLabel == "team-helper")
}

@Test func sessionRowsPreferLiveIdentityWithoutChangingSpawnIdentity() {
    let status = AgentNodeStatus(nodeId: "node", agentId: "codex", state: .working)
    let row = sessionRow(agentId: "claude", status: status)
    #expect(row.agentLabel == "Codex")
    #expect(row.effectiveAgentId == "codex")
    #expect(row.agentId == "claude")
    #expect(row.badge == .running)
    #expect(sessionRow(status: status).agentLabel == "Codex")
    #expect(sessionRow(agentId: "claude", status: AgentNodeStatus(nodeId: "node")).agentLabel == "Claude Code")
}

@Test func homeRowsReflectStatusBeforeAnyTerminalIsViewed() async {
    let store = AgentStatusStore(clock: { 10_000 })
    let workspace = Workspace(projects: [Project(id: "project", name: "Project", color: "#000",
        nodes: [CanvasNodeState(id: "node", kind: .terminal, title: "Fix authentication", color: "#fff")])])
    for (state, badge) in [(AgentState.working, AgentBadge.running), (.blocked, .needsYou), (.done, .idle)] {
        await store.ingest(AgentStatusEvent(nodeId: "node", agentId: "codex", kind: .state,
                                           state: state), onScreen: false)
        let status = await store.status(for: "node")
        let rows = SessionListModel.rows(serverId: "server", serverName: "Server",
                                        workspace: workspace) { _ in status }
        #expect(rows.count == 1)
        #expect(rows.first?.agentLabel == "Codex")
        #expect(rows.first?.badge == badge)
    }
}
