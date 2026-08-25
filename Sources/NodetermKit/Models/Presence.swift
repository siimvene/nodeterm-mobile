import Foundation

/// A presence peer's client kind (SPEC §11.8). v0 ignores presence, but MUST tolerate the
/// unsolicited `presence:sync` push (§4.9). Tolerant.
public enum PeerKind: TolerantStringEnum {
    case browser, phone, desktop
    case unknown(String)

    public init(wire: String) {
        switch wire {
        case "browser": self = .browser
        case "phone": self = .phone
        case "desktop": self = .desktop
        default: self = .unknown(wire)
        }
    }
    public var wire: String {
        switch self {
        case .browser: return "browser"
        case .phone: return "phone"
        case .desktop: return "desktop"
        case .unknown(let s): return s
        }
    }
}

public struct PeerCursor: Codable, Sendable, Equatable, Hashable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

public struct PeerTyping: Codable, Sendable, Equatable, Hashable {
    public var nodeId: String
    public var at: Int
    public init(nodeId: String, at: Int) { self.nodeId = nodeId; self.at = at }
}

/// `PeerState` (SPEC §11.8). Caps (server-enforced): name 32, chat 200, ref 128. v0 may ignore.
public struct PeerState: Codable, Sendable, Equatable {
    public var clientId: Int
    public var name: String
    public var color: String
    public var cursor: PeerCursor?
    public var focus: String?
    public var chat: String?
    public var typing: PeerTyping?
    public var projectId: String?
    public var dino: JSONValue?        // opaque
    public var kind: PeerKind

    public init(clientId: Int, name: String, color: String, kind: PeerKind,
                cursor: PeerCursor? = nil, focus: String? = nil, chat: String? = nil,
                typing: PeerTyping? = nil, projectId: String? = nil, dino: JSONValue? = nil) {
        self.clientId = clientId
        self.name = name
        self.color = color
        self.kind = kind
        self.cursor = cursor
        self.focus = focus
        self.chat = chat
        self.typing = typing
        self.projectId = projectId
        self.dino = dino
    }
}

/// `PeerDiff` (SPEC §11.8): join/update/leave. `patch` is a partial `PeerState` (opaque here).
public enum PeerDiff: Sendable, Equatable {
    case join(peer: PeerState)
    case update(clientId: Int, patch: JSONValue)
    case leave(clientId: Int)
    case unknown(op: String)
}

extension PeerDiff: Codable {
    private enum CodingKeys: String, CodingKey { case op, peer, clientId, patch }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let op = try c.decode(String.self, forKey: .op)
        switch op {
        case "join":
            self = .join(peer: try c.decode(PeerState.self, forKey: .peer))
        case "update":
            self = .update(
                clientId: try c.decode(Int.self, forKey: .clientId),
                patch: try c.decodeIfPresent(JSONValue.self, forKey: .patch) ?? .object([:]))
        case "leave":
            self = .leave(clientId: try c.decode(Int.self, forKey: .clientId))
        default:
            self = .unknown(op: op)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .join(let peer):
            try c.encode("join", forKey: .op)
            try c.encode(peer, forKey: .peer)
        case let .update(clientId, patch):
            try c.encode("update", forKey: .op)
            try c.encode(clientId, forKey: .clientId)
            try c.encode(patch, forKey: .patch)
        case .leave(let clientId):
            try c.encode("leave", forKey: .op)
            try c.encode(clientId, forKey: .clientId)
        case .unknown(let op):
            try c.encode(op, forKey: .op)
        }
    }
}
