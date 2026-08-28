import SwiftUI
import NodetermKit

/// Settings → Usage: account rate-limit stats forwarded from the desktop over `usage:update`.
/// Read-only; the phone renders the desktop usage service's own snapshots (it cannot query the
/// provider APIs itself — the credentials live on the host). One expandable card per connected
/// server, each listing its accounts and their limit windows.
struct UsageView: View {
    @EnvironmentObject private var env: AppEnvironment

    var body: some View {
        Form {
            let servers = env.runtimes.filter { $0.connectionState == .connected }
            if servers.allSatisfy({ $0.accountUsage.isEmpty }) {
                Section {
                    Text("No usage reported yet. Connect a server whose desktop is publishing account usage.")
                        .font(.subheadline).foregroundStyle(Theme.textSecondary)
                }
            } else {
                ForEach(servers, id: \.profile.id) { server in
                    if !server.accountUsage.isEmpty {
                        Section(server.profile.name) {
                            ForEach(server.accountUsage) { account in
                                AccountUsageRow(account: account)
                            }
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Usage")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct AccountUsageRow: View {
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

private struct LimitBar: View {
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
                    Capsule().fill(Theme.card).frame(height: 6)
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
        guard let ms = limit.resetsAt, ms > 0 else { return nil }
        let interval = ms / 1000 - Date().timeIntervalSince1970
        guard interval > 0 else { return "Resetting…" }
        let h = Int(interval) / 3600
        let m = (Int(interval) % 3600) / 60
        if h >= 24 { return "Resets in \(h / 24)d \(h % 24)h" }
        if h >= 1 { return "Resets in \(h)h \(m)m" }
        return "Resets in \(m)m"
    }
}
