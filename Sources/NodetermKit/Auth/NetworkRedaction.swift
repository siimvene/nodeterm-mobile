import Foundation

/// Redaction for network debug output (SPEC §10 rule 2). The `nt_session` cookie, passwords,
/// download-ticket tokens and setup tokens MUST NOT appear in logs. Any place that stringifies a
/// header dictionary or a `Cookie`/`Set-Cookie` value routes through here first.
public enum NetworkRedaction {

    /// Header names whose VALUE carries a secret and must never be logged verbatim (SPEC §10 rule 2).
    /// Compared case-insensitively (HTTP header names are case-insensitive).
    static let sensitiveHeaderNames: Set<String> = ["cookie", "set-cookie", "authorization"]

    public static let placeholder = "<redacted>"

    /// True iff a header with this name must have its value masked in any log/description.
    public static func isSensitive(headerName: String) -> Bool {
        sensitiveHeaderNames.contains(headerName.lowercased())
    }

    /// Return the value to log for one header: the real value for a benign header, the placeholder
    /// for a sensitive one (SPEC §10 rule 2).
    public static func redactedValue(headerName: String, value: String) -> String {
        isSensitive(headerName: headerName) ? placeholder : value
    }

    /// Produce a stable, secret-free description of a header set for debug output (SPEC §10 rule 2).
    /// Sensitive values are replaced wholesale; nothing partial is emitted (no prefix/length leak).
    public static func redactedDescription(headers: [String: String]) -> String {
        let body = headers
            .sorted { $0.key.lowercased() < $1.key.lowercased() }
            .map { "\($0.key): \(redactedValue(headerName: $0.key, value: $0.value))" }
            .joined(separator: ", ")
        return "[\(body)]"
    }

    /// Mask any `nt_session=<value>` (or arbitrary cookie value) inside a free-form string that may
    /// have already been assembled (e.g. a `Cookie:` request-header line). Everything from the `=`
    /// after the cookie name up to the next `;` or end is replaced (SPEC §10 rule 2).
    public static func maskCookieValues(in text: String) -> String {
        var result = ""
        var i = text.startIndex
        let cookieName = NodetermWire.sessionCookieName
        while i < text.endIndex {
            if text[i...].hasPrefix("\(cookieName)=") {
                result += "\(cookieName)=\(placeholder)"
                // advance past name= and the value (until ';' or whitespace-newline or end)
                var j = text.index(i, offsetBy: cookieName.count + 1)
                while j < text.endIndex, text[j] != ";", text[j] != "\n" {
                    j = text.index(after: j)
                }
                i = j
            } else {
                result.append(text[i])
                i = text.index(after: i)
            }
        }
        return result
    }
}
