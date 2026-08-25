import Foundation

// The binary pty frame is server→client ONLY (SPEC §4.5): a real client never encodes one, and
// the fixed `PtyBinaryFrame` (Models/RpcFrame.swift) exposes only `decode`. This encoder exists so
// a fake in-memory server (tests) and any diagnostic tooling can build a byte-exact frame to feed
// the DECODE path — it is the inverse of `PtyBinaryFrame.decode`, same layout (§4.5):
//   [0]=0x01, [1..2]=sidLen big-endian uint16, [3..]=sid UTF-8, then payload UTF-8.
extension PtyBinaryFrame {
    /// Encode a pty output frame. Returns `nil` when the sessionId's UTF-8 length exceeds a
    /// uint16 (65535) — the length field cannot represent it, matching what `decode` can read back.
    public static func encode(sessionId: String, payload: Data) -> Data? {
        let sid = Array(sessionId.utf8)
        guard sid.count <= 0xFFFF else { return nil }
        var out = Data(capacity: 3 + sid.count + payload.count)
        out.append(dataFrameTag)                       // byte 0: 0x01
        out.append(UInt8((sid.count >> 8) & 0xFF))     // bytes 1..2: big-endian uint16 length
        out.append(UInt8(sid.count & 0xFF))
        out.append(contentsOf: sid)                    // sessionId UTF-8
        out.append(payload)                            // payload UTF-8
        return out
    }

    /// Convenience for a UTF-8 string payload.
    public static func encode(sessionId: String, text: String) -> Data? {
        encode(sessionId: sessionId, payload: Data(text.utf8))
    }
}
