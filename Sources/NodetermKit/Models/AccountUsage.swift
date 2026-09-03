import Foundation

/// Account rate-limit usage forwarded from the desktop's status mirror over the `usage:update`
/// WS event (server: peer-status-bridge). The phone renders these on the Home dashboard's Usage section; it never
/// computes them — the numbers are the desktop usage service's own snapshots.
///
/// Tolerant decoding throughout (unknown fields ignored, absent optionals nil): the mirror is
/// written by a desktop that may be a different app version than the phone.

/// One rate-limit window (a 5h session bucket, a weekly cap, a per-model quota…).
public struct AccountUsageLimit: Codable, Sendable, Equatable, Identifiable {
    public var kind: String
    public var group: String?
    /// 0–100, portion USED (providers' own convention; the UI shows "left" = 100 − this).
    public var usedPercent: Double
    public var severity: String?
    /// Unix ms when this window resets, or nil.
    public var resetsAt: Double?
    public var windowMinutes: Double?
    /// Per-model label (e.g. "Fable") when the window is a model quota.
    public var scopeLabel: String?

    /// Stable within one account row — kind is unique per account in the mirror.
    public var id: String { "\(kind)\(scopeLabel ?? "")" }

    public var leftPercent: Double { max(0, min(100, 100 - usedPercent)) }
}

/// One account's usage (system `~/.claude`, or a managed account).
public struct AccountUsage: Codable, Sendable, Equatable, Identifiable {
    /// nil = the system account.
    public var accountId: String?
    public var label: String?
    public var email: String?
    public var agentId: String
    /// "ok" | "unavailable" | "error" | "fetching".
    public var status: String
    public var updatedAt: Double
    public var limits: [AccountUsageLimit]

    // Tolerant decode: a single account missing/mangling an optional-in-practice field must not
    // reject the WHOLE snapshot and strand every account on stale data (consort finding).
    private enum CodingKeys: String, CodingKey {
        case accountId, label, email, agentId, status, updatedAt, limits
    }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        accountId = try c.decodeIfPresent(String.self, forKey: .accountId) ?? nil
        label = try c.decodeIfPresent(String.self, forKey: .label)
        email = try c.decodeIfPresent(String.self, forKey: .email)
        agentId = (try? c.decode(String.self, forKey: .agentId)) ?? "claude"
        status = (try? c.decode(String.self, forKey: .status)) ?? "ok"
        updatedAt = (try? c.decode(Double.self, forKey: .updatedAt)) ?? 0
        limits = (try? c.decode([AccountUsageLimit].self, forKey: .limits)) ?? []
    }
    public init(accountId: String?, label: String?, email: String?, agentId: String,
                status: String, updatedAt: Double, limits: [AccountUsageLimit]) {
        self.accountId = accountId; self.label = label; self.email = email
        self.agentId = agentId; self.status = status; self.updatedAt = updatedAt; self.limits = limits
    }

    /// Row id: the account id, or a stable token for the (single) system row.
    public var id: String { accountId ?? "system:\(agentId)" }

    /// Best display name: label → email → a generic fallback.
    public var displayName: String {
        if let l = label, !l.isEmpty { return l }
        if let e = email, !e.isEmpty { return e }
        return accountId == nil ? "System account" : agentId.capitalized
    }
}

/// The `usage:update` event payload.
public struct AccountUsageUpdate: Codable, Sendable, Equatable {
    public var updatedAt: Double
    public var accounts: [AccountUsage]
}
