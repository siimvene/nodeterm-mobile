import Foundation
import NodetermKit

/// One session row aggregated across servers for the HOME sessions list (SPEC §9.1). Pure value
/// type — the view maps these to SwiftUI rows. Combines a persisted terminal node with its reduced
/// live status (`nil` = never seen ⇒ unknown, no badge).
public struct SessionRow: Identifiable, Sendable, Equatable {
    public var serverId: String
    public var serverName: String
    public var projectId: String
    public var projectName: String
    public var nodeId: String
    /// Persisted node `title` — the v0 session name (SPEC §5.1: live session names not on the wire).
    public var title: String
    public var agentId: String?
    public var cwd: String?
    public var accountId: String?
    /// Project-level cwd fallback for a cold spawn (SPEC §7.1; consort finding).
    public var projectCwd: String?
    /// Node runs in remote tmux — attachment must set requireRemote (consort finding).
    public var sshRemoteTmux: Bool
    public var status: AgentNodeStatus?

    /// Row id must be unique across servers (node ids are only per-launch unique — SPEC §7.4).
    public var id: String { "\(serverId)/\(nodeId)" }

    public var badge: AgentBadge { status?.badge ?? .none }
    public var unread: Bool { status?.unread ?? false }
    /// Inline Allow/Deny only for a held APPROVAL (SPEC §6.2: `pendingId` present + askKind approval).
    public var showsApproval: Bool { status?.pendingId != nil && status?.askKind == .approval }
    public var pendingId: String? { status?.pendingId }
    public var contextPercent: Double? { status?.context?.usedPercent }
    public var contextModel: String? { status?.context?.model }

    public init(serverId: String, serverName: String, projectId: String, projectName: String,
                nodeId: String, title: String, agentId: String? = nil, cwd: String? = nil,
                accountId: String? = nil, projectCwd: String? = nil,
                sshRemoteTmux: Bool = false, status: AgentNodeStatus? = nil) {
        self.serverId = serverId
        self.serverName = serverName
        self.projectId = projectId
        self.projectName = projectName
        self.nodeId = nodeId
        self.title = title
        self.agentId = agentId
        self.cwd = cwd
        self.accountId = accountId
        self.projectCwd = projectCwd
        self.sshRemoteTmux = sshRemoteTmux
        self.status = status
    }
}

/// The three always-visible sections of the sessions list (SPEC §6.3 grouping):
/// **Waiting for your response** = done ∪ waiting ∪ blocked · **Running** = working ·
/// **Unknown** = no live state.
public enum SessionSection: String, CaseIterable, Sendable {
    case waiting = "Waiting for your response"
    case running = "Running"
    case unknown = "Unknown"

    public static func section(for state: ReducedAgentState) -> SessionSection {
        switch state {
        case .working: return .running
        case .done, .waiting, .blocked: return .waiting
        case .unknown: return .unknown
        }
    }
}

public enum SessionListModel {
    /// Build the flat rows from every connected server's workspace + reduced statuses (SPEC §9.1).
    /// Only `terminal`-kind nodes in non-`closed` projects; SSH projects are read-only but still
    /// listed (their sessions cannot be live on the server — SPEC §11.2).
    public static func rows(serverId: String,
                            serverName: String,
                            workspace: Workspace?,
                            status: (String) -> AgentNodeStatus?) -> [SessionRow] {
        guard let ws = workspace else { return [] }
        var rows: [SessionRow] = []
        for project in ws.projects where project.closed != true {
            for node in project.nodes where node.kind == .terminal {
                rows.append(SessionRow(
                    serverId: serverId, serverName: serverName,
                    projectId: project.id, projectName: project.name,
                    nodeId: node.id, title: node.title,
                    agentId: node.agentId, cwd: node.cwd, accountId: node.accountId,
                    projectCwd: project.cwd, sshRemoteTmux: node.sshRemoteTmux == true,
                    status: status(node.id)))
            }
        }
        return rows
    }

    /// Group + sort for display (SPEC §6.3): section by reduced state; within a section newest-first
    /// by `lastTransitionAt`, missing clocks last (no invented timestamp), then stable by title.
    /// HOME grouping: by PROJECT (server first when several are connected), preserving workspace
    /// order — the desktop sidebar's shape. Status stays a per-row badge: on the phone most rows
    /// sit in `unknown` anyway (desktop-spawned sessions report hooks to the desktop instance),
    /// so status sections degenerated into one big UNKNOWN list.
    public static func groupedByProject(_ rows: [SessionRow], multiServer: Bool)
        -> [(title: String, rows: [SessionRow])] {
        var order: [String] = []
        var buckets: [String: [SessionRow]] = [:]
        for row in rows {
            let title = multiServer ? "\(row.serverName) · \(row.projectName)" : row.projectName
            if buckets[title] == nil { order.append(title) }
            buckets[title, default: []].append(row)
        }
        return order.map { (title: $0, rows: buckets[$0]!) }
    }

    public static func grouped(_ rows: [SessionRow]) -> [(section: SessionSection, rows: [SessionRow])] {
        SessionSection.allCases.compactMap { section in
            let inSection = rows
                .filter { SessionSection.section(for: $0.status?.state ?? .unknown) == section }
                .sorted { lhs, rhs in
                    switch (lhs.status?.lastTransitionAt, rhs.status?.lastTransitionAt) {
                    case let (l?, r?) where l != r: return l > r        // newest first
                    case (_?, nil): return true                          // a clock beats none
                    case (nil, _?): return false
                    default: return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                    }
                }
            return inSection.isEmpty ? nil : (section, inSection)
        }
    }
}
