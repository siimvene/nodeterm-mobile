import Foundation

/// OSC 52 clipboard handling (SPEC §7.7 / §10 rule 5). WRITE-ONLY: a `?` payload is a clipboard
/// READ query from the remote program and MUST be ignored — never expose the phone's clipboard to
/// the remote side. Pure (no UIKit) so it is testable; the App wires the result to `UIPasteboard`.
public enum Osc52 {

    /// Max base64 payload we honor (SPEC §7.7): ignore anything over ~1 MB of base64.
    public static let maxBase64Bytes = 1_000_000

    /// Given the OSC 52 payload — everything AFTER `ESC ] 52 ;` and before the ST/BEL terminator —
    /// return the UTF-8 text to write to the device clipboard, or `nil` to ignore the sequence.
    ///
    /// Layout: `<selection>;<base64>`. `selection` (c/p/…) is ignored. Ignore when the base64 field
    /// is `?` (read query), empty, malformed, or larger than `maxBase64Bytes`.
    public static func clipboardText(fromPayload payload: String) -> String? {
        guard let semi = payload.firstIndex(of: ";") else { return nil }
        let b64 = String(payload[payload.index(after: semi)...])
        guard b64 != "?", !b64.isEmpty, b64.utf8.count <= maxBase64Bytes else { return nil }
        // Base64 may carry whitespace/newlines from line-wrapped emitters; be lenient.
        guard let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
