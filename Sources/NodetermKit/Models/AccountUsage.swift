import Foundation

/// Account rate-limit usage forwarded from the desktop's status mirror over the `usage:update`
/// WS event (server: peer-status-bridge). The phone renders these in Settings → Usage; it never
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
