import Foundation

/// A transcript role (SPEC §11.7). `ChatMessage` uses `user|assistant`; `TranscriptLine` also
/// uses `tool`. Tolerant so an unknown role never fails decoding. All transcript text is DATA —
/// render as plain text, never markup/commands (SPEC §10 rule 6).
public enum ChatRole: TolerantStringEnum {
    case user, assistant, tool
    case unknown(String)

    public init(wire: String) {
        switch wire {
        case "user": self = .user
        case "assistant": self = .assistant
        case "tool": self = .tool
        default: self = .unknown(wire)
        }
    }
    public var wire: String {
        switch self {
        case .user: return "user"
        case .assistant: return "assistant"
        case .tool: return "tool"
        case .unknown(let s): return s
        }
    }
}

/// The `summary` sub-object of a tool `ChatPart` (SPEC §11.7).
public struct ChatToolSummary: Codable, Sendable, Equatable {
    public var filePath: String?
    public var added: Int?
    public var removed: Int?
    public init(filePath: String? = nil, added: Int? = nil, removed: Int? = nil) {
        self.filePath = filePath
        self.added = added
        self.removed = removed
    }
}

/// One part of a `ChatMessage` (SPEC §11.7). Discriminated on `kind`; an unknown kind decodes to
/// `.unknown` and never crashes the stream.
public enum ChatPart: Sendable, Equatable {
    case text(String)
    case thinking(String)
    case tool(name: String, arg: JSONValue?, result: String?, summary: ChatToolSummary?)
    case unknown(kind: String)
}

extension ChatPart: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, text, name, arg, result, summary
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "text":
            self = .text(try c.decodeIfPresent(String.self, forKey: .text) ?? "")
        case "thinking":
            self = .thinking(try c.decodeIfPresent(String.self, forKey: .text) ?? "")
        case "tool":
            self = .tool(
                name: try c.decodeIfPresent(String.self, forKey: .name) ?? "",
                arg: try c.decodeIfPresent(JSONValue.self, forKey: .arg),
                result: try c.decodeIfPresent(String.self, forKey: .result),
                summary: try c.decodeIfPresent(ChatToolSummary.self, forKey: .summary)
            )
        default:
            self = .unknown(kind: kind)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let t):
            try c.encode("text", forKey: .kind)
            try c.encode(t, forKey: .text)
        case .thinking(let t):
            try c.encode("thinking", forKey: .kind)
            try c.encode(t, forKey: .text)
        case let .tool(name, arg, result, summary):
            try c.encode("tool", forKey: .kind)
            try c.encode(name, forKey: .name)
            try c.encodeIfPresent(arg, forKey: .arg)
            try c.encodeIfPresent(result, forKey: .result)
            try c.encodeIfPresent(summary, forKey: .summary)
        case .unknown(let kind):
            try c.encode(kind, forKey: .kind)
        }
    }
}

/// One rendered chat message (SPEC §11.7).
public struct ChatMessage: Codable, Sendable, Equatable {
    public var role: ChatRole
    public var parts: [ChatPart]
    public init(role: ChatRole, parts: [ChatPart]) {
        self.role = role
        self.parts = parts
    }
}

/// The `chat:read-transcript` result (SPEC §5.4/§11.7). `found:false` = transcript UNRESOLVABLE
/// (other machine / cleaned up); `found:true` + empty `messages` = a real empty session. The client
/// MUST render these two differently (§5.4).
public struct ChatTranscriptResult: Codable, Sendable, Equatable {
    public var messages: [ChatMessage]
    public var found: Bool
    public init(messages: [ChatMessage], found: Bool) {
        self.messages = messages
        self.found = found
    }
}

/// A flat transcript line from `claude:read-transcript` (for search, SPEC §5.4/§11.7).
public struct TranscriptLine: Codable, Sendable, Equatable {
    public var role: ChatRole
    public var text: String
    public init(role: ChatRole, text: String) {
        self.role = role
        self.text = text
    }
}
