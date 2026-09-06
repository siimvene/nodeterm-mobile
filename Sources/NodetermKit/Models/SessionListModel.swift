import Foundation

// Lives in NodetermKit (moved from the App layer) so the HOME grouping rule — which decides WHICH
// project a card's "+" spawns into — is unit-tested, not just rendered.

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

/// One HOME project card (SPEC §9.1): the rows of ONE (server, project) pair. `id` is the stable
/// group key (`serverId/projectId`) — the collapsed-state key and the `ForEach` identity; `title`
/// is display-only and may carry a disambiguator when two projects share a name.
public struct ProjectGroup: Identifiable, Sendable, Equatable {
    public var id: String
    public var serverId: String
    public var projectId: String
    /// The undecorated title (server-prefixed on multi-server setups); the legacy collapsed key.
    public var baseTitle: String
    public var title: String
    public var projectCwd: String?
    public var rows: [SessionRow]

    public static func key(serverId: String, projectId: String) -> String { "\(serverId)/\(projectId)" }
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

    /// HOME grouping: one card per PROJECT (server first when several are connected), preserving
    /// workspace order — the desktop sidebar's shape. Status stays a per-row badge: on the phone
    /// most rows sit in `unknown` anyway (desktop-spawned sessions report hooks to the desktop
    /// instance), so status sections degenerated into one big UNKNOWN list.
    ///
    /// Buckets are keyed by **(serverId, projectId)**, never by the project's NAME: two projects on
    /// one server may share a title (two clones of the same repo), and a title-keyed bucket merged
    /// them into one card whose "+" then spawned into whichever project happened to come first — a
    /// permanently wrong cwd (SPEC §7.11.2). Colliding titles are disambiguated for DISPLAY only:
    /// by the project cwd's basename when those differ, else with an ordinal (" (2)", " (3)"…).
    public static func groupedByProject(_ rows: [SessionRow], multiServer: Bool) -> [ProjectGroup] {
        var order: [String] = []
        var buckets: [String: [SessionRow]] = [:]
        for row in rows {
            let key = ProjectGroup.key(serverId: row.serverId, projectId: row.projectId)
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(row)
        }
        var groups: [ProjectGroup] = order.compactMap { key in
            guard let rows = buckets[key], let first = rows.first else { return nil }
            let base = multiServer ? "\(first.serverName) · \(first.projectName)" : first.projectName
            return ProjectGroup(id: key, serverId: first.serverId, projectId: first.projectId,
                                baseTitle: base, title: base, projectCwd: first.projectCwd, rows: rows)
        }
        disambiguateTitles(&groups)
        return groups
    }

    /// Give same-titled groups distinct display titles. The cwd basename is preferred (it is what
    /// tells two clones apart); an ordinal is the fallback when basenames are missing or also equal.
    /// The first group of a collision set keeps its bare title only in the ordinal scheme.
    private static func disambiguateTitles(_ groups: inout [ProjectGroup]) {
        var byTitle: [String: [Int]] = [:]
        for (i, g) in groups.enumerated() { byTitle[g.baseTitle, default: []].append(i) }
        for (_, indices) in byTitle where indices.count > 1 {
            let basenames = indices.map { groups[$0].projectCwd.flatMap(cwdBasename) }
            let distinct = Set(basenames.compactMap { $0 })
            if distinct.count == indices.count {
                for (i, name) in zip(indices, basenames) {
                    if let name { groups[i].title = "\(groups[i].baseTitle) · \(name)" }
                }
            } else {
                for (n, i) in indices.enumerated() where n > 0 {
                    groups[i].title = "\(groups[i].baseTitle) (\(n + 1))"
                }
            }
        }
    }

    private static func cwdBasename(_ cwd: String) -> String? {
        let trimmed = cwd.hasSuffix("/") && cwd.count > 1 ? String(cwd.dropLast()) : cwd
        let leaf = trimmed.split(separator: "/").last.map(String.init) ?? trimmed
        return leaf.isEmpty ? nil : leaf
    }

    /// Group + sort for display (SPEC §6.3): section by reduced state; within a section newest-first
    /// by `lastTransitionAt`, missing clocks last (no invented timestamp), then stable by title.

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
