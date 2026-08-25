import Foundation

/// Pure parsing of `Set-Cookie` response headers (SPEC §3.2). A native client reads the raw
/// header freely — `HttpOnly` binds browser JS only (RFC 6265). We capture the cookie VALUE and
/// deliberately ignore every attribute (`HttpOnly`, `SameSite`, `Path`, `Secure`, `Max-Age`),
/// because the client manages its own jar keyed by profile id (§10 rule 1a) and never depends on
/// `Secure` being present (§2.2).
public enum SetCookieParser {

    /// Extract the value of a named cookie from a single `Set-Cookie` header line.
    /// The line shape is `name=value; Attr; Attr=x` — only the leading `name=value` pair is the
    /// cookie itself; the rest are attributes and are ignored (SPEC §3.2).
    ///
    /// Returns `nil` when the header is malformed (no `=`, empty name, or a different cookie name).
    /// An empty value (`nt_session=`) parses to `""` — the caller decides whether an empty cookie
    /// counts (a logout clear is `nt_session=; Max-Age=0`, §3.4).
    public static func value(named name: String, in header: String) -> String? {
        // The cookie pair is everything up to the first ';' (attributes follow).
        let firstSegment = header.split(separator: ";", maxSplits: 1,
                                        omittingEmptySubsequences: false)[0]
        guard let eq = firstSegment.firstIndex(of: "=") else { return nil }
        let rawName = firstSegment[firstSegment.startIndex..<eq]
            .trimmingCharacters(in: .whitespaces)
        guard !rawName.isEmpty, rawName == name else { return nil }
        let valueStart = firstSegment.index(after: eq)
        let rawValue = firstSegment[valueStart...].trimmingCharacters(in: .whitespaces)
        return rawValue
    }

    /// Scan an array of `Set-Cookie` header lines and return the FIRST non-empty value for `name`.
    /// A trailing empty value (a clear) is skipped in favor of a real one; if only empty values
    /// exist, `nil` is returned (SPEC §3.2 — success requires a real `nt_session` value).
    public static func value(named name: String, inHeaders headers: [String]) -> String? {
        var sawEmpty = false
        for header in headers {
            if let v = value(named: name, in: header) {
                if v.isEmpty { sawEmpty = true; continue }
                return v
            }
        }
        // A present-but-empty cookie is not a valid session (it is the logout clear, §3.4).
        _ = sawEmpty
        return nil
    }

    /// Some HTTP stacks fold multiple `Set-Cookie` headers into one comma-joined string
    /// (`HTTPURLResponse.allHeaderFields`). Split conservatively: the auth cookies on this branch
    /// carry no date-valued attribute (no `Expires`), so a comma only ever separates cookies here
    /// (SPEC §2.2 attributes = `HttpOnly; SameSite=Strict; Path=/`). We still guard by only
    /// splitting on a comma that is followed by a `token=` pair, never inside an attribute.
    public static func splitFolded(_ combined: String) -> [String] {
        guard combined.contains(",") else { return [combined] }
        var parts: [String] = []
        var current = ""
        let scalars = Array(combined)
        var i = 0
        while i < scalars.count {
            let c = scalars[i]
            if c == "," {
                // Look ahead: a new cookie starts if the upcoming run (up to ';' or ',') has an '='.
                var j = i + 1
                while j < scalars.count && scalars[j] == " " { j += 1 }
                var k = j
                var hasEq = false
                while k < scalars.count, scalars[k] != ";", scalars[k] != "," {
                    if scalars[k] == "=" { hasEq = true; break }
                    k += 1
                }
                if hasEq {
                    parts.append(current)
                    current = ""
                    i = j
                    continue
                }
            }
            current.append(c)
            i += 1
        }
        parts.append(current)
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
