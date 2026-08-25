import Foundation

/// Why an OSC 52 sequence was NOT written to the device clipboard (SPEC §7.7).
public enum Osc52Ignore: Sendable, Equatable {
    /// A `?` payload is a clipboard READ query from the remote program — MUST be ignored so the
    /// phone's clipboard is never exposed to the remote side (SPEC §7.7).
    case readQuery
    /// Empty payload.
    case empty
    /// Missing `;` separator, invalid base64, or non-UTF-8 bytes.
    case malformed
    /// Base64 payload larger than the 1 MB cap (SPEC §7.7).
    case tooLarge
}

/// The classification of one OSC 52 sequence (SPEC §7.7). WRITE-ONLY: only `.write` reaches the
/// clipboard; everything else is swallowed.
public enum Osc52Outcome: Sendable, Equatable {
    /// Decoded UTF-8 text to write to the device clipboard (App-side: `UIPasteboard`).
    case write(text: String)
    case ignore(Osc52Ignore)
}

/// Pure OSC 52 parse / classify (SPEC §7.7). The actual clipboard write is App-side; this layer
/// only decides what (if anything) should be written and always swallows the sequence.
public enum TerminalOsc52 {

    /// Max base64 payload length before the sequence is dropped (SPEC §7.7: ">1 MB-base64").
    public static let maxBase64Bytes = 1024 * 1024

    /// Classify an OSC 52 body of the form `<selection>;<base64>` (the content AFTER the `52;`
    /// introducer, matching `osc52.ts`). Returns `.write(text:)` only for a valid, in-bounds,
    /// non-query payload; otherwise `.ignore(reason)`.
    public static func classify(_ body: String) -> Osc52Outcome {
        // Split on the FIRST `;` into <selection>;<payload>.
        guard let sep = body.firstIndex(of: ";") else {
            return .ignore(.malformed) // SPEC §7.7: no separator ⇒ malformed.
        }
        let payload = String(body[body.index(after: sep)...])

        if payload.isEmpty {
            return .ignore(.empty)
        }
        if payload == "?" {
            // SPEC §7.7: a `?` payload is a READ query — never answer it.
            return .ignore(.readQuery)
        }
        if payload.utf8.count > maxBase64Bytes {
            return .ignore(.tooLarge)
        }
        guard let data = Data(base64Encoded: payload) else {
            return .ignore(.malformed)
        }
        // Decode to UTF-8; reject non-UTF-8 rather than write mojibake.
        guard let text = String(data: data, encoding: .utf8) else {
            return .ignore(.malformed)
        }
        return .write(text: text)
    }
}
