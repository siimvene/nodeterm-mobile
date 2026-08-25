import Foundation

/// `NormalizedAgentEvent.kind` (SPEC §6.2/§11.4). Tolerant.
public enum AgentEventKind: TolerantStringEnum {
    case state, subagentStart, subagentEnd, recurring, session, backgroundTask
    case unknown(String)

    public init(wire: String) {
        switch wire {
        case "state": self = .state
        case "subagent-start": self = .subagentStart
        case "subagent-end": self = .subagentEnd
        case "recurring": self = .recurring
        case "session": self = .session
        case "background-task": self = .backgroundTask
        default: self = .unknown(wire)
        }
    }
    public var wire: String {
        switch self {
        case .state: return "state"
        case .subagentStart: return "subagent-start"
        case .subagentEnd: return "subagent-end"
        case .recurring: return "recurring"
        case .session: return "session"
        case .backgroundTask: return "background-task"
        case .unknown(let s): return s
        }
    }
}

/// Live agent state on a `kind:'state'` event (SPEC §6.2/§6.3). Tolerant.
public enum AgentState: TolerantStringEnum {
    case working, waiting, blocked, done
    case unknown(String)

    public init(wire: String) {
        switch wire {
        case "working": self = .working
        case "waiting": self = .waiting
        case "blocked": self = .blocked
        case "done": self = .done
        default: self = .unknown(wire)
        }
    }
    public var wire: String {
        switch self {
        case .working: return "working"
        case .waiting: return "waiting"
        case .blocked: return "blocked"
        case .done: return "done"
        case .unknown(let s): return s
        }
    }
}

/// `askKind` on a needs-you event (SPEC §6.2). `approval` ⇒ show Allow/Deny (a `pendingId` is
/// present); `question` ⇒ deep-link into the terminal (the `pendingId` was stripped). Tolerant.
public enum AskKind: TolerantStringEnum {
    case question, approval
    case unknown(String)

    public init(wire: String) {
        switch wire {
        case "question": self = .question
        case "approval": self = .approval
        default: self = .unknown(wire)
        }
    }
    public var wire: String {
        switch self {
        case .question: return "question"
        case .approval: return "approval"
        case .unknown(let s): return s
        }
    }
}

/// `sessionPhase` on a `kind:'session'` event (SPEC §6.2/§6.3). Tolerant.
public enum SessionPhase: TolerantStringEnum {
    case start, end
    case unknown(String)

    public init(wire: String) {
        switch wire {
        case "start": self = .start
        case "end": self = .end
        default: self = .unknown(wire)
        }
    }
    public var wire: String {
        switch self {
        case .start: return "start"
        case .end: return "end"
        case .unknown(let s): return s
        }
    }
}

/// `NormalizedAgentEvent` — the `agent:status` payload that drives the badge machine (SPEC §11.4).
/// Optional fields are absent-tolerant. `sessionTitle` is a TRAP: declared but NEVER emitted by any
/// producer (§6.2) — do not build the session-name feature on it; use the node `title` instead.
public struct AgentStatusEvent: Codable, Sendable, Equatable {
    public var nodeId: String
    public var agentId: String
    public var kind: AgentEventKind

    // kind:'state'
    public var state: AgentState?
    public var interrupted: Bool?   // done-only: suppress alert/unread
    public var idle: Bool?          // done-only rescue: only moves a still-`working` node
    public var awaitingInput: Bool? // waiting-only: hold through turn-end done
    public var newTurn: Bool?       // clears per-turn fan-out

    public var sessionId: String?
    public var lastMessage: String?

    // needs-you / approval
    public var pendingId: String?   // present ⇒ show Allow/Deny
    public var askKind: AskKind?

    // session lifecycle
    public var sessionTitle: String?   // TRAP: never emitted (§6.2)
    public var sessionPhase: SessionPhase?

    // subagent card data
    public var toolUseId: String?
    public var subagentType: String?
    public var taskLabel: String?
    public var durationMs: Int?
    public var tokens: JSONValue?   // shape unpinned (number or object)
    public var toolUses: Int?
    public var result: String?

    // labels only — NEVER reject on these (§6.2)
    public var verified: Bool?
    public var clientRevision: JSONValue?

    // loop / schedule / cron card
    public var recurringKind: String?
    public var recurringEnd: Bool?
    public var task: String?
    public var schedule: JSONValue?

    public init(
        nodeId: String,
        agentId: String,
        kind: AgentEventKind,
        state: AgentState? = nil,
        interrupted: Bool? = nil,
        idle: Bool? = nil,
        awaitingInput: Bool? = nil,
        newTurn: Bool? = nil,
        sessionId: String? = nil,
        lastMessage: String? = nil,
        pendingId: String? = nil,
        askKind: AskKind? = nil,
        sessionTitle: String? = nil,
        sessionPhase: SessionPhase? = nil,
        toolUseId: String? = nil,
        subagentType: String? = nil,
        taskLabel: String? = nil,
        durationMs: Int? = nil,
        tokens: JSONValue? = nil,
        toolUses: Int? = nil,
        result: String? = nil,
        verified: Bool? = nil,
        clientRevision: JSONValue? = nil,
        recurringKind: String? = nil,
        recurringEnd: Bool? = nil,
        task: String? = nil,
        schedule: JSONValue? = nil
    ) {
        self.nodeId = nodeId
        self.agentId = agentId
        self.kind = kind
        self.state = state
        self.interrupted = interrupted
        self.idle = idle
        self.awaitingInput = awaitingInput
        self.newTurn = newTurn
        self.sessionId = sessionId
        self.lastMessage = lastMessage
        self.pendingId = pendingId
        self.askKind = askKind
        self.sessionTitle = sessionTitle
        self.sessionPhase = sessionPhase
        self.toolUseId = toolUseId
        self.subagentType = subagentType
        self.taskLabel = taskLabel
        self.durationMs = durationMs
        self.tokens = tokens
        self.toolUses = toolUses
        self.result = result
        self.verified = verified
        self.clientRevision = clientRevision
        self.recurringKind = recurringKind
        self.recurringEnd = recurringEnd
        self.task = task
        self.schedule = schedule
    }
}

/// `agent:subagent-activity` payload (SPEC §6.1, Claude only).
public struct SubagentActivity: Codable, Sendable, Equatable {
    public var toolUseId: String
    public var chunk: String
    public init(toolUseId: String, chunk: String) {
        self.toolUseId = toolUseId
        self.chunk = chunk
    }
}

/// `ContextWindowUsage` — the `context:update` payload / per-session meter (SPEC §11.6). `model`
/// null ≡ absent for a consumer (both surface as `nil`); the phone just renders `usedPercent` + `model`.
public struct ContextWindowUsage: Codable, Sendable, Equatable, Hashable {
    public var sessionId: String
    public var usedTokens: Int
    public var windowTokens: Int
    public var usedPercent: Double   // 0-100
    public var model: String?
    public var updatedAt: Int        // ms

    public init(sessionId: String, usedTokens: Int, windowTokens: Int,
                usedPercent: Double, model: String? = nil, updatedAt: Int) {
        self.sessionId = sessionId
        self.usedTokens = usedTokens
        self.windowTokens = windowTokens
        self.usedPercent = usedPercent
        self.model = model
        self.updatedAt = updatedAt
    }
}

// MARK: - Reduced badge model (SPEC §6.3)

/// The reduced live state per node. Initial state is `.unknown` (live state is transient
/// server-side and not persisted; a node is unknown until its next hook fires — §6.3).
public enum ReducedAgentState: String, Codable, Sendable, Equatable, Hashable {
    case working, waiting, blocked, done, unknown
}

/// The visible badge for a list row (SPEC §6.3 badge mapping).
public enum AgentBadge: String, Sendable, Equatable, Hashable {
    case running    // working (pulsing)
    case needsYou   // waiting or blocked
    case idle       // done (no badge; unread dot if unread)
    case none       // unknown (no badge)
}

/// The reduced status the client maintains per node from the `agent:status` stream (§6.3), plus
/// the latest `context:update`. Produced by an `AgentStatusReducing` implementation.
public struct AgentNodeStatus: Sendable, Equatable {
    public var nodeId: String
    public var state: ReducedAgentState
    /// Set on a working→(done|waiting|blocked) edge while off screen; INDEPENDENT of state (§6.3 #8).
    public var unread: Bool
    public var sessionId: String?
    /// Present ⇒ an approval is held; drives inline Allow/Deny (§6.2/§6.3).
    public var pendingId: String?
    public var askKind: AskKind?
    /// Last transition time (ms) for newest-first sorting; `nil` sorts last (§6.3 grouping).
    public var lastTransitionAt: Int?
    public var context: ContextWindowUsage?

    public init(
        nodeId: String,
        state: ReducedAgentState = .unknown,
        unread: Bool = false,
        sessionId: String? = nil,
        pendingId: String? = nil,
        askKind: AskKind? = nil,
        lastTransitionAt: Int? = nil,
        context: ContextWindowUsage? = nil
    ) {
        self.nodeId = nodeId
        self.state = state
        self.unread = unread
        self.sessionId = sessionId
        self.pendingId = pendingId
        self.askKind = askKind
        self.lastTransitionAt = lastTransitionAt
        self.context = context
    }

    /// Badge for a list row (SPEC §6.3). The unread dot is a separate concern (`unread`).
    public var badge: AgentBadge {
        switch state {
        case .working: return .running
        case .waiting, .blocked: return .needsYou
        case .done: return .idle
        case .unknown: return .none
        }
    }
}

// MARK: - agent:answer-permission request (SPEC §5.3)

/// Decision for `agent:answer-permission` (SPEC §5.3). Only sent on `askKind:'approval'` rows.
public enum PermissionDecision: String, Codable, Sendable, Equatable, Hashable {
    case allow, deny
}

/// The single argument object of `agent:answer-permission` (SPEC §5.3).
public struct AnswerPermissionRequest: Codable, Sendable, Equatable, Hashable {
    public var nodeId: String
    public var pendingId: String
    public var decision: PermissionDecision
    public init(nodeId: String, pendingId: String, decision: PermissionDecision) {
        self.nodeId = nodeId
        self.pendingId = pendingId
        self.decision = decision
    }
}
