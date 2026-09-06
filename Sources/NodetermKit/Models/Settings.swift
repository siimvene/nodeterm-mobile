import Foundation

/// One managed agent account from `settings:load` → `claudeAccounts` / `codexAccounts`
/// (SPEC §7.11.3 / §11.7). The phone reads these to populate the account picker when SPAWNING a
/// new session. Only the fields the picker needs are modeled; everything else is ignored.
///
/// **Skip rule (SPEC §7.11.3 / §5.6):** an account with `pending == true` (never captured) or a
/// non-nil `host` (its config dir lives on an SSH host, unreachable from this edition) is NOT a
/// usable launch identity — filter those out before offering them.
public struct ManagedAccount: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var id: String
    public var label: String?
    public var email: String?
    public var pending: Bool?
    public var host: String?

    public init(id: String, label: String? = nil, email: String? = nil,
                pending: Bool? = nil, host: String? = nil) {
        self.id = id
        self.label = label
        self.email = email
        self.pending = pending
        self.host = host
    }

    // Tolerant decode: an account row missing an optional-in-practice field must not reject the
    // whole settings object (same discipline as AccountUsage). `id` is required.
    private enum CodingKeys: String, CodingKey { case id, label, email, pending, host }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.label = try c.decodeIfPresent(String.self, forKey: .label)
        self.email = try c.decodeIfPresent(String.self, forKey: .email)
        self.pending = try c.decodeIfPresent(Bool.self, forKey: .pending)
        self.host = try c.decodeIfPresent(String.self, forKey: .host)
    }

    /// Usable as a launch identity from THIS server: not pending, and not host-pinned (SPEC §7.11.3).
    public var isUsableHere: Bool { pending != true && host == nil }

    /// Best display name for the picker: label → email → the id.
    public var displayName: String {
        if let l = label, !l.isEmpty { return l }
        if let e = email, !e.isEmpty { return e }
        return id
    }
}

/// The read-only subset of server `Settings` a phone MAY read (SPEC §11.7 / §5.2). Everything else
/// is desktop render config — ignored, and NEVER written back (`settings:save` MUST NOT be called
/// in v0). Missing fields fall back to the spec defaults.
public struct Settings: Sendable, Equatable {
    /// Default `'auto'` (SPEC §11.7).
    public var claudePermissionMode: String
    public var defaultShell: String?
    /// Default `50000` (SPEC §11.7).
    public var tmuxScrollback: Int
    /// Managed Claude accounts (SPEC §7.11.3). Filter with `ManagedAccount.isUsableHere` before use.
    public var claudeAccounts: [ManagedAccount]
    /// Managed Codex accounts (SPEC §7.11.3), same shape and skip rule.
    public var codexAccounts: [ManagedAccount]

    public init(claudePermissionMode: String = "auto",
                defaultShell: String? = nil,
                tmuxScrollback: Int = 50000,
                claudeAccounts: [ManagedAccount] = [],
                codexAccounts: [ManagedAccount] = []) {
        self.claudePermissionMode = claudePermissionMode
        self.defaultShell = defaultShell
        self.tmuxScrollback = tmuxScrollback
        self.claudeAccounts = claudeAccounts
        self.codexAccounts = codexAccounts
    }
}

extension Settings: Codable {
    private enum CodingKeys: String, CodingKey {
        case claudePermissionMode, defaultShell, tmuxScrollback, claudeAccounts, codexAccounts
    }

    public init(from decoder: Decoder) throws {
        // Tolerant: an absent field yields the spec default (§11.7), unknown keys are ignored.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.claudePermissionMode =
            try c.decodeIfPresent(String.self, forKey: .claudePermissionMode) ?? "auto"
        self.defaultShell = try c.decodeIfPresent(String.self, forKey: .defaultShell)
        self.tmuxScrollback =
            try c.decodeIfPresent(Int.self, forKey: .tmuxScrollback) ?? 50000
        // PER-ROW tolerance (the phone's tolerant-decoding house rule, as AccountUsage does): one
        // malformed account row — no `id`, or not an object — is skipped and the rest are kept. The
        // earlier `try? [ManagedAccount]` dropped the WHOLE list on a single bad row, which hid every
        // usable account behind one stale entry. A non-array value still yields `[]`.
        self.claudeAccounts = Settings.tolerantAccounts(c, .claudeAccounts)
        self.codexAccounts = Settings.tolerantAccounts(c, .codexAccounts)
    }

    private static func tolerantAccounts(_ c: KeyedDecodingContainer<CodingKeys>,
                                         _ key: CodingKeys) -> [ManagedAccount] {
        let rows = ((try? c.decodeIfPresent([TolerantRow<ManagedAccount>].self, forKey: key)) ?? nil) ?? []
        return rows.compactMap(\.value)
    }
}

/// One array element decoded leniently: a row that fails to decode becomes `nil` instead of
/// failing the enclosing array, so callers `compactMap` the good rows and drop the bad one.
struct TolerantRow<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) {
        value = try? T(from: decoder)
    }
}
