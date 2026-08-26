import SwiftUI
import NodetermKit

/// A navigation target for a session (SPEC §9.1 → §9.3). Node ids are only per-launch unique, so
/// the target is keyed by (server, node).
public struct TerminalTarget: Hashable {
    public let serverId: String
    public let nodeId: String
}

/// HOME (SPEC §9.1): header, greeting, 3 stat tiles, SESSIONS list, SERVERS list, Add Server,
/// DISCOVER carousel. NO subscription banner, quota, "Unlock", Pair Desktop, or Restore Purchase
/// anywhere (SPEC §1/§9.1 hard requirement).
public struct HomeView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var showAddServer = false
    @State private var showSettings = false

    public init() {}

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    greeting
                    statTiles
                    sessionsSection
                    serversSection
                    DiscoverCarousel()
                }
                .padding(16)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { headerToolbar }
            .sheet(isPresented: $showAddServer) { AddServerView() }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(item: $env.reauthNeeded) { profile in ReauthSheet(profile: profile) }
            .navigationDestination(for: TerminalTarget.self) { target in
                if let runtime = env.runtime(for: target.serverId),
                   let row = runtime.sessionRows.first(where: { $0.nodeId == target.nodeId }) {
                    TerminalScreen(runtime: runtime, row: row)
                } else {
                    ContentUnavailableView("Session unavailable", systemImage: "terminal")
                }
            }
        }
    }

    // MARK: Header

    // iOS 26's Liquid Glass toolbar wraps each item in a tight capsule chip — a logo+text HStack
    // gets clipped into a circle. The brand therefore lives in the page content (greeting row);
    // the toolbar keeps only the gear, which a chip suits.
    @ToolbarContentBuilder private var headerToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button { showSettings = true } label: { Image(systemName: "gearshape") }
                .tint(Theme.textSecondary)
        }
    }

    private var greeting: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image("LogoMark").resizable().scaledToFit().frame(width: 22, height: 22)
                Text("Remote Claude").font(.headline.bold()).foregroundStyle(Theme.textSecondary)
            }
            .padding(.bottom, 6)
            Text("Welcome back").font(.largeTitle.bold()).foregroundStyle(Theme.textPrimary)
            Text("Your terminals, wherever you are.")
                .font(.subheadline).foregroundStyle(Theme.textSecondary)
        }
    }

    // MARK: Stat tiles (SPEC §9.1)

    private var statTiles: some View {
        HStack(spacing: 12) {
            StatTile(title: "Active sessions", value: "\(env.activeSessionCount)", icon: "terminal.fill")
            StatTile(title: "Servers", value: "\(env.onlineServerCount)/\(env.profiles.count)", icon: "server.rack")
            StatTile(title: "Projects", value: "\(env.projectCount)", icon: "folder.fill")
        }
    }

    // MARK: Sessions (SPEC §9.1 / §6.3)

    private var sessionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Sessions")
            let grouped = env.groupedSessions
            if grouped.isEmpty {
                EmptyHint("No live sessions on connected servers yet.")
            } else {
                ForEach(grouped, id: \.title) { group in
                    Text(group.title.uppercased())
                        .font(.caption.weight(.semibold)).foregroundStyle(Theme.textTertiary)
                        .padding(.top, 4)
                    VStack(spacing: 0) {
                        ForEach(group.rows) { row in
                            // Server already rides the group title on multi-server setups.
                            SessionRowView(row: row, showServer: false)
                            if row.id != group.rows.last?.id { Divider().background(Theme.separator) }
                        }
                    }
                    .card()
                }
            }
        }
    }

    // MARK: Servers (SPEC §9.1)

    private var serversSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionHeader("Servers")
                Spacer()
                Button { showAddServer = true } label: {
                    Label("Add Server", systemImage: "plus.circle.fill").font(.subheadline.weight(.semibold))
                }
                .tint(Theme.accent)
            }
            if env.profiles.isEmpty {
                EmptyHint("Add a self-hosted nodeterm server to get started.")
            } else {
                VStack(spacing: 0) {
                    ForEach(env.profiles) { profile in
                        ServerRowView(profile: profile,
                                      state: env.runtime(for: profile.id)?.connectionState ?? .offline)
                        if profile.id != env.profiles.last?.id { Divider().background(Theme.separator) }
                    }
                }
                .card()
            }
        }
    }
}

// MARK: - Components

struct SectionHeader: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.title3.bold()).foregroundStyle(Theme.textPrimary)
    }
}

struct EmptyHint: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.subheadline).foregroundStyle(Theme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(16).card()
    }
}

struct StatTile: View {
    let title: String
    let value: String
    let icon: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon).foregroundStyle(Theme.accent)
            Text(value).font(.title2.bold()).foregroundStyle(Theme.textPrimary)
            Text(title).font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .card()
    }
}

/// A session row across servers (SPEC §9.1). Inline Allow/Deny only on a held APPROVAL (§6.2).
struct SessionRowView: View {
    @EnvironmentObject private var env: AppEnvironment
    let row: SessionRow
    let showServer: Bool

    var body: some View {
        NavigationLink(value: TerminalTarget(serverId: row.serverId, nodeId: row.nodeId)) {
            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    if row.unread { Circle().fill(Theme.unread).frame(width: 8, height: 8) }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.title).font(.body.weight(.medium)).foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            Text(row.projectName).lineLimit(1)
                            if showServer { Text("· \(row.serverName)").lineLimit(1) }
                            if let pct = row.contextPercent {
                                Text("· \(Int(pct))%").monospacedDigit()
                            }
                        }
                        .font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    BadgeView(badge: row.badge)
                }
                if row.showsApproval { approvalButtons }
            }
            .padding(14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var approvalButtons: some View {
        HStack(spacing: 10) {
            Spacer()
            Button("Deny") { answer(.deny) }
                .buttonStyle(.bordered).tint(Theme.needsYou)
            Button("Allow") { answer(.allow) }
                .buttonStyle(.borderedProminent).tint(Theme.accent)
        }
        .font(.subheadline.weight(.semibold))
    }

    private func answer(_ decision: PermissionDecision) {
        guard let pendingId = row.pendingId, let runtime = env.runtime(for: row.serverId) else { return }
        Task { await runtime.answerPermission(nodeId: row.nodeId, pendingId: pendingId, decision: decision) }
    }
}

/// The badge per SPEC §6.3 (RUNNING pulsing / NEEDS YOU / idle=none).
struct BadgeView: View {
    let badge: AgentBadge
    @State private var pulse = false

    var body: some View {
        switch badge {
        case .running:
            label("RUNNING", color: Theme.running)
                .opacity(pulse ? 0.55 : 1)
                .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true } }
        case .needsYou:
            label("NEEDS YOU", color: Theme.needsYou)
        case .idle, .none:
            EmptyView()
        }
    }

    private func label(_ text: String, color: Color) -> some View {
        Text(text).font(.caption2.weight(.bold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.18)).foregroundStyle(color)
            .clipShape(Capsule())
    }
}

struct ServerRowView: View {
    @EnvironmentObject private var env: AppEnvironment
    let profile: ServerProfile
    let state: ConnectionState

    var body: some View {
        NavigationLink {
            ServerDetailView(profile: profile)
        } label: {
            HStack(spacing: 12) {
                Circle().fill(color).frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.name).font(.body.weight(.medium)).foregroundStyle(Theme.textPrimary)
                    Text(profile.baseURL.host() ?? profile.baseURL.absoluteString)
                        .font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
                Spacer()
                Text(stateText).font(.caption).foregroundStyle(Theme.textSecondary)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.textTertiary)
            }
            .padding(14).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture().onEnded {
            if state == .authRequired { env.reauthNeeded = profile }
        })
    }

    private var color: Color {
        switch state {
        case .connected: return Theme.running
        case .reconnecting: return Theme.needsYou
        case .authRequired: return Theme.needsYou
        case .offline: return Theme.textTertiary
        }
    }
    private var stateText: String {
        switch state {
        case .connected: return "Online"
        case .reconnecting: return "Reconnecting…"
        case .authRequired: return "Sign in"
        case .offline: return "Offline"
        }
    }
}

/// The three static education cards (SPEC §9.1 DISCOVER). No product upsell.
struct DiscoverCarousel: View {
    private let cards = [
        ("bolt.horizontal.circle", "tmux Sessions", "Your sessions keep running even when the app is closed."),
        ("clock.arrow.circlepath", "Scrollback", "History is restored after reboots — pick up where you left off."),
        ("mic.circle", "Voice → Terminal", "Dictate commands on-device or via your server's whisper."),
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Discover")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(cards, id: \.1) { card in
                        VStack(alignment: .leading, spacing: 10) {
                            Image(systemName: card.0).font(.title2).foregroundStyle(Theme.accent)
                            Text(card.1).font(.headline).foregroundStyle(Theme.textPrimary)
                            Text(card.2).font(.caption).foregroundStyle(Theme.textSecondary)
                        }
                        .frame(width: 220, alignment: .leading).padding(16).card(elevated: true)
                    }
                }
            }
        }
    }
}
