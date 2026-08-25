import Foundation

/// Error payload of a negative `res` frame. SPEC §4.3: `error: { code, message }`.
public struct RpcErrorPayload: Codable, Sendable, Equatable, Hashable {
    public var code: String
    public var message: String
    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

/// A single top-level RPC argument slot in a `req`/`cast`. SPEC §4.4 / §8.2.
///
/// The three states exist because JSON has no `undefined` and several methods *mean* `null`:
/// - `.value` — a real value.
/// - `.null`  — a MEANINGFUL null (e.g. the `pty:resize(sid, null, null)` park signal). Emitted
///   as bare JSON `null`, and its index is **NOT** listed in `undef`.
/// - `.omitted` — a logically absent trailing optional. Emitted as JSON `null`, and its index
///   **IS** listed in `undef` so the server treats it as absent and its default fires.
public enum RpcArg: Sendable, Equatable {
    case value(JSONValue)
    case null
    case omitted
}

extension RpcArg {
    public init(_ value: JSONValue) { self = .value(value) }
    /// Wrap an optional as `.value` when present, `.omitted` when nil (the common trailing-optional case).
    public static func optional(_ value: JSONValue?) -> RpcArg {
        value.map(RpcArg.value) ?? .omitted
    }
}

/// The four RPC frame shapes on this connection. SPEC §4.3.
///
/// Direction on the Server Edition: the client sends only `.req` / `.cast`; the server sends
/// only `.resOk` / `.resErr` / `.ev`. Frames arriving in the wrong direction are ignored (§4.3).
public enum RpcFrame: Sendable, Equatable {
    case req(id: Int, method: String, args: [JSONValue], undef: [Int])
    case cast(method: String, args: [JSONValue], undef: [Int])
    case resOk(id: Int, result: JSONValue)
    case resErr(id: Int, error: RpcErrorPayload)
    case ev(channel: String, args: [JSONValue], undef: [Int])
}

extension RpcFrame {
    /// Parse an inbound TEXT frame. Returns `nil` for anything that must be DROPPED rather than
    /// crash the connection (SPEC §4.3: non-JSON / non-object → drop; a `res` is valid iff `id`
    /// is a number and either `ok===true` or `ok===false` with a non-null object `error`; an `ev`
    /// is valid iff `channel` is a string and `args` is an array; anything else → drop).
    public static func parse(text: String) -> RpcFrame? {
        guard let data = text.data(using: .utf8) else { return nil }
        return parse(data: data)
    }

    public static func parse(data: Data) -> RpcFrame? {
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object(let obj) = root,
              let t = obj["t"]?.stringValue
        else { return nil }

        func args(_ key: String) -> [JSONValue]? { obj[key]?.arrayValue }
        func undef() -> [Int] {
            (obj["undef"]?.arrayValue ?? []).compactMap { $0.intValue }
        }

        switch t {
        case "res":
            guard let id = obj["id"]?.intValue else { return nil }
            switch obj["ok"]?.boolValue {
            case .some(true):
                // `result` may legitimately be null (§4.6). Absent → treat as null.
                return .resOk(id: id, result: obj["result"] ?? .null)
            case .some(false):
                guard case .object(let e)? = obj["error"],
                      let code = e["code"]?.stringValue,
                      let message = e["message"]?.stringValue
                else { return nil }
                return .resErr(id: id, error: RpcErrorPayload(code: code, message: message))
            default:
                return nil
            }
        case "ev":
            guard let channel = obj["channel"]?.stringValue,
                  let a = args("args")
            else { return nil }
            return .ev(channel: channel, args: a, undef: undef())
        case "req":
            // The server never sends these; parse for completeness / symmetry.
            guard let id = obj["id"]?.intValue,
                  let method = obj["method"]?.stringValue,
                  let a = args("args")
            else { return nil }
            return .req(id: id, method: method, args: a, undef: undef())
        case "cast":
            guard let method = obj["method"]?.stringValue,
                  let a = args("args")
            else { return nil }
            return .cast(method: method, args: a, undef: undef())
        default:
            return nil
        }
    }

    /// Serialize an outbound frame to a compact JSON string. SPEC §4.3/§4.4: the `undef` field is
    /// emitted only when non-empty.
    public func encodedText() throws -> String {
        var obj: [String: JSONValue] = [:]
        switch self {
        case let .req(id, method, args, undef):
            obj = ["t": "req", "id": .number(Double(id)), "method": .string(method),
                   "args": .array(args)]
            if !undef.isEmpty { obj["undef"] = .array(undef.map { .number(Double($0)) }) }
        case let .cast(method, args, undef):
            obj = ["t": "cast", "method": .string(method), "args": .array(args)]
            if !undef.isEmpty { obj["undef"] = .array(undef.map { .number(Double($0)) }) }
        case let .resOk(id, result):
            obj = ["t": "res", "id": .number(Double(id)), "ok": .bool(true), "result": result]
        case let .resErr(id, error):
            obj = ["t": "res", "id": .number(Double(id)), "ok": .bool(false),
                   "error": .object(["code": .string(error.code), "message": .string(error.message)])]
        case let .ev(channel, args, undef):
            obj = ["t": "ev", "channel": .string(channel), "args": .array(args)]
            if !undef.isEmpty { obj["undef"] = .array(undef.map { .number(Double($0)) }) }
        }
        let data = try JSONEncoder().encode(JSONValue.object(obj))
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - The `undef` codec (SPEC §4.4) — MANDATORY on every outbound req/cast

public enum RpcArgs {
    /// Encode positional argument slots into `(args, undef)`. SPEC §4.4:
    /// an OMITTED slot emits JSON `null` and its index is appended to `undef`; a meaningful `null`
    /// emits `null` and is NOT listed; a value emits itself. Only top-level slots are ever marked.
    public static func encode(_ slots: [RpcArg]) -> (args: [JSONValue], undef: [Int]) {
        var args: [JSONValue] = []
        var undef: [Int] = []
        args.reserveCapacity(slots.count)
        for (i, slot) in slots.enumerated() {
            switch slot {
            case .value(let v): args.append(v)
            case .null: args.append(.null)
            case .omitted:
                args.append(.null)
                undef.append(i)
            }
        }
        return (args, undef)
    }

    /// Decode an inbound `undef` list into the set of argument indexes to treat as ABSENT.
    /// SPEC §4.4: only integers `i` with `0 <= i < count` mark a slot; junk/out-of-range mark
    /// nothing and can never lengthen the array.
    public static func absentIndexes(_ undef: [Int], count: Int) -> Set<Int> {
        Set(undef.filter { $0 >= 0 && $0 < count })
    }
}

// MARK: - Binary pty frame (SPEC §4.5) — server→client only

public enum PtyBinaryFrame {
    /// The only binary frame kind (`PTY_DATA_FRAME`). SPEC §4.5 byte 0.
    public static let dataFrameTag: UInt8 = 0x01

    /// Decode a binary pty output frame. Layout (SPEC §4.5):
    /// `[0]=0x01`, `[1..2]=sidLen (big-endian uint16)`, `[3..3+L-1]=sessionId UTF-8`,
    /// `[3+L..]=payload UTF-8`. Returns `nil` (DROP) if `length < 3`, `buf[0] != 0x01`, or
    /// `3 + sidLen > length`. A decoded frame is semantically an event on channel
    /// `pty:data:<sessionId>` with `args = [payloadString]`.
    public static func decode(_ buf: Data) -> (sessionId: String, payload: Data)? {
        guard buf.count >= 3 else { return nil }
        let bytes = [UInt8](buf)
        guard bytes[0] == dataFrameTag else { return nil }
        let sidLen = Int(bytes[1]) << 8 | Int(bytes[2])
        guard 3 + sidLen <= bytes.count else { return nil }
        let sidBytes = bytes[3..<(3 + sidLen)]
        let sessionId = String(decoding: sidBytes, as: UTF8.self)
        let payload = Data(bytes[(3 + sidLen)...])
        return (sessionId, payload)
    }

    /// Event channel name for a session's pty output stream (SPEC §4.5/§6.1).
    public static func channel(for sessionId: String) -> String { "pty:data:\(sessionId)" }
}
