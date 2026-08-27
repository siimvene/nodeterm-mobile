import Foundation

/// A fully general JSON value. RPC `args`, `res.result`, and `ev` payloads are heterogeneous
/// on the wire (SPEC §4.3), so the transport layer speaks in `JSONValue` and the typed models
/// are decoded from it on demand.
///
/// Numbers are stored as `Double` (JSON has a single number type). Whole values encode without
/// a fractional part, which the server-side JS treats identically to an integer.
public enum JSONValue: Sendable, Equatable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    indirect case array([JSONValue])
    indirect case object([String: JSONValue])
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let d = try? container.decode(Double.self) {
            self = .number(d)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let a = try? container.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? container.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let b): try container.encode(b)
        case .number(let n): try container.encode(n)
        case .string(let s): try container.encode(s)
        case .array(let a): try container.encode(a)
        case .object(let o): try container.encode(o)
        }
    }
}

// MARK: - Ergonomic accessors (for builders reading RPC results/events)

extension JSONValue {
    public var isNull: Bool { if case .null = self { return true }; return false }

    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    public var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var doubleValue: Double? { if case .number(let n) = self { return n }; return nil }
    /// Number narrowed to `Int` (JSON has no integer type; use for ids/counts/timestamps).
    /// Guarded: `Int(Double)` TRAPS on out-of-range values, so a hostile/buggy server sending
    /// `1e300` would crash the client (consort finding). Non-integral or out-of-range → nil.
    public var intValue: Int? {
        guard case .number(let n) = self, n.isFinite, n == n.rounded(),
              n >= -9_007_199_254_740_991, n <= 9_007_199_254_740_991 else { return nil }
        return Int(n)
    }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    public var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }

    /// Object member access. Returns `nil` for non-objects or absent keys.
    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    /// Array index access. Returns `nil` for non-arrays or out-of-range indexes.
    public subscript(index: Int) -> JSONValue? {
        if case .array(let a) = self, a.indices.contains(index) { return a[index] }
        return nil
    }
}

// MARK: - Literals (for building outbound args concisely)

extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}
extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
}
extension JSONValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .number(value) }
}
extension JSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}
extension JSONValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}

// MARK: - Decoding typed models out of a JSONValue

extension JSONValue {
    /// Re-encode this value and decode it as a concrete `Codable` model. Convenience for
    /// turning an RPC `result` / event arg into a typed struct from §11.
    public func decoded<T: Decodable>(as type: T.Type) throws -> T {
        let data = try JSONEncoder().encode(self)
        return try JSONDecoder().decode(T.self, from: data)
    }
}
