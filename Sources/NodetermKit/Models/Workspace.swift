import Foundation

/// Node kind on the wire (SPEC §11.3). Tolerant so a future kind never breaks decoding.
/// `subagent`/`loop` are render-only and NEVER appear in a persisted workspace or a mutation
/// (§6.4) — they are included only so an unexpected value still round-trips.
public enum NodeKind: TolerantStringEnum {
    case terminal, sticky, group, editor, diff, video, web, browser, dino
    case unknown(String)

    public init(wire: String) {
        switch wire {
        case "terminal": self = .terminal
        case "sticky": self = .sticky
        case "group": self = .group
        case "editor": self = .editor
        case "diff": self = .diff
        case "video": self = .video
        case "web": self = .web
        case "browser": self = .browser
        case "dino": self = .dino
        default: self = .unknown(wire)
        }
    }

    public var wire: String {
        switch self {
        case .terminal: return "terminal"
        case .sticky: return "sticky"
        case .group: return "group"
        case .editor: return "editor"
        case .diff: return "diff"
        case .video: return "video"
        case .web: return "web"
        case .browser: return "browser"
        case .dino: return "dino"
        case .unknown(let s): return s
        }
    }
}

/// A canvas node — a session/note/frame (SPEC §11.3, phone-relevant subset). Geometry fields
/// (`position`, `size`, `collapsed`, …) are deliberately NOT modeled; they are ignored on decode.
public struct CanvasNodeState: Codable, Sendable, Equatable {
    /// Node id == tmux persist key (`nt-<id>`).
    public var id: String
    public var kind: NodeKind
    public var title: String
    public var color: String
    /// Terminal working dir.
    public var cwd: String?
    /// `claude | codex | gemini | opencode | grok | copilot | <custom>` — an "agent node" is a
    /// terminal with this set. Kept as a raw String because the set is open (custom agents).
    public var agentId: String?
    /// Managed Claude account id (pass to transcript reads, §5.4).
    public var accountId: String?
    /// Minted agent session id for resume — an OWNER concern; the phone never resumes (§7.2).
    public var agentSessionId: String?
    public var tags: [String]?
    /// Group-frame parent id.
    public var parentId: String?
    /// The node's session runs in REMOTE tmux on an SSH host — attachment must pass
    /// `requireRemote` so the server refuses instead of spawning a phantom local shell
    /// (SPEC §7.1/§11.2; consort finding — this was only derivable from the project before).
    public var sshRemoteTmux: Bool?

    public init(
        id: String,
        kind: NodeKind,
        title: String,
        color: String,
        cwd: String? = nil,
        agentId: String? = nil,
        accountId: String? = nil,
        agentSessionId: String? = nil,
        tags: [String]? = nil,
        parentId: String? = nil,
        sshRemoteTmux: Bool? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.color = color
        self.cwd = cwd
        self.agentId = agentId
        self.accountId = accountId
        self.agentSessionId = agentSessionId
        self.tags = tags
        self.parentId = parentId
        self.sshRemoteTmux = sshRemoteTmux
    }
}

/// An SSH project marker (SPEC §11.2). Present ⇒ the project's node sessions live on ANOTHER host
/// the Server Edition cannot reach (no SSH manager). Show read-only / not-openable in v0.
public struct ProjectSSH: Codable, Sendable, Equatable, Hashable {
    public var server: String
    public var remoteCwd: String?
    public init(server: String, remoteCwd: String? = nil) {
        self.server = server
        self.remoteCwd = remoteCwd
    }
}

/// A project / canvas page (SPEC §11.2, fields a phone reads). Canvas/machine-local fields
/// (`viewport`, `breadcrumbs`, `capabilityAck`, `bridges`, `ropes`, `remote`, …) are ignored.
public struct Project: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var color: String
    public var cwd: String?
    public var ssh: ProjectSSH?
    public var nodes: [CanvasNodeState]
    public var defaultPermissionMode: String?
    /// Kanban board (v1). Kept opaque for tolerant decoding; not interpreted in v0.
    public var kanban: JSONValue?
    public var closed: Bool?
    public var unavailable: Bool?

    public init(
        id: String,
        name: String,
        color: String,
        nodes: [CanvasNodeState],
        cwd: String? = nil,
        ssh: ProjectSSH? = nil,
        defaultPermissionMode: String? = nil,
        kanban: JSONValue? = nil,
        closed: Bool? = nil,
        unavailable: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.color = color
        self.nodes = nodes
        self.cwd = cwd
        self.ssh = ssh
        self.defaultPermissionMode = defaultPermissionMode
        self.kanban = kanban
        self.closed = closed
        self.unavailable = unavailable
    }

    /// A project is an SSH project iff it carries an `ssh` marker (§11.2).
    public var isSSH: Bool { ssh != nil }
}

/// The `workspace:load` result (SPEC §11.1). `activeProjectId == ""` ⇒ welcome/no-project.
public struct Workspace: Codable, Sendable, Equatable {
    public var version: Int
    public var activeProjectId: String
    public var projects: [Project]

    public init(version: Int = 2, activeProjectId: String = "", projects: [Project] = []) {
        self.version = version
        self.activeProjectId = activeProjectId
        self.projects = projects
    }
}

/// A `canvas:mut` delta (SPEC §6.4/§11.9). `seq` is SERVER-authoritative — never trust a
/// client-set value. An unrecognized `op` decodes to `.unknown` (never crashes the stream).
public enum CanvasMutation: Sendable, Equatable {
    case upsert(node: CanvasNodeState, seq: Int?)
    case remove(id: String, seq: Int?)
    case unknown(op: String)
}

extension CanvasMutation: Codable {
    private enum CodingKeys: String, CodingKey { case op, node, id, seq }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let op = try c.decode(String.self, forKey: .op)
        let seq = try c.decodeIfPresent(Int.self, forKey: .seq)
        switch op {
        case "upsert":
            let node = try c.decode(CanvasNodeState.self, forKey: .node)
            self = .upsert(node: node, seq: seq)
        case "remove":
            let id = try c.decode(String.self, forKey: .id)
            self = .remove(id: id, seq: seq)
        default:
            self = .unknown(op: op)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .upsert(node, seq):
            try c.encode("upsert", forKey: .op)
            try c.encode(node, forKey: .node)
            try c.encodeIfPresent(seq, forKey: .seq)
        case let .remove(id, seq):
            try c.encode("remove", forKey: .op)
            try c.encode(id, forKey: .id)
            try c.encodeIfPresent(seq, forKey: .seq)
        case let .unknown(op):
            try c.encode(op, forKey: .op)
        }
    }
}
