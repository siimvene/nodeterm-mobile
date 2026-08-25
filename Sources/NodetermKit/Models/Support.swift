import Foundation

/// A string-backed enum that decodes tolerantly: an unrecognized wire value maps to a
/// `.unknown(String)` case instead of throwing. SPEC repeatedly requires that one bad or
/// unexpected value never crashes the connection (§4.3) and that unknown future kinds
/// render neutrally (§6.4). Discriminated unions on the wire adopt this so the client is
/// forward-compatible with a newer server.
public protocol TolerantStringEnum: Codable, Sendable, Equatable, Hashable {
    /// Build the case from a raw wire string (must map any unknown value, never fail).
    init(wire: String)
    /// The exact wire string this case serializes to.
    var wire: String { get }
}

extension TolerantStringEnum {
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self.init(wire: raw)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wire)
    }
}
