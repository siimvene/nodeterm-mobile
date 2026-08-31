import SwiftUI
import NodetermKit

/// Account rate-limit usage rendering, shared by the Home dashboard's Usage section (SPEC §9.1 /
/// §5.6). The numbers are the host usage service's own snapshots, forwarded over `usage:update`;
/// the phone renders them read-only (the provider credentials live on the host). One row per
/// account, each listing its limit windows.
///
/// (Previously a standalone Settings → Usage page; moved onto the dashboard below the servers
/// block so it is visible without a detour into Settings.)

struct AccountUsageRow: View {
    let account: AccountUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(Theme.accent).frame(width: 8, height: 8)
                Text(account.displayName).font(.body.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                Spacer()
                if account.status != "ok" {
                    Text(account.status).font(.caption).foregroundStyle(Theme.textTertiary)
                }
            }
            if account.limits.isEmpty {
                Text(account.status == "ok" ? "No limits reported." : "Usage unavailable.")
                    .font(.caption).foregroundStyle(Theme.textTertiary)
            } else {
                ForEach(account.limits) { limit in
                    LimitBar(limit: limit)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct LimitBar: View {
    let limit: AccountUsageLimit

    private var color: Color {
        let left = limit.leftPercent
        if left <= 5 { return Theme.needsYou }
        if left <= 20 { return .orange }
        return Theme.running
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.subheadline.weight(.medium)).foregroundStyle(Theme.textPrimary)
                Spacer()
                Text("\(Int(limit.leftPercent.rounded()))% left")
                    .font(.caption).monospacedDigit().foregroundStyle(Theme.textSecondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // cardElevated, not card: the row now sits inside a .card() whose
                    // background IS Theme.card, so a same-colour track would be invisible.
                    Capsule().fill(Theme.cardElevated).frame(height: 6)
                    Capsule().fill(color)
                        .frame(width: max(0, geo.size.width * limit.leftPercent / 100), height: 6)
                }
            }
            .frame(height: 6)
            if let resets = resetText {
                Text(resets).font(.caption2).foregroundStyle(Theme.textTertiary)
            }
        }
    }

    private var title: String {
        if let scope = limit.scopeLabel, !scope.isEmpty { return scope }
        switch limit.group ?? limit.kind {
        case "session": return "Session"
        case "weekly": return "Weekly"
        default: return limit.kind.capitalized
        }
    }

    private var resetText: String? {
        guard let ms = limit.resetsAt, ms.isFinite, ms > 0 else { return nil }
        let interval = ms / 1000 - Date().timeIntervalSince1970
        // Clamp before Int(): Int(Double) TRAPS on an out-of-range value (a hostile/buggy
        // `resetsAt: 1e308`) — cap at a week (consort finding).
        guard interval > 0 else { return "Resetting…" }
        let secs = Int(min(interval, 7 * 24 * 3600))
        let h = secs / 3600
        let m = (secs % 3600) / 60
        if h >= 24 { return "Resets in \(h / 24)d \(h % 24)h" }
        if h >= 1 { return "Resets in \(h)h \(m)m" }
        return "Resets in \(m)m"
    }
}
