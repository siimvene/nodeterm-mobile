import SwiftUI
import NodetermKit

/// Server detail / project list (SPEC §9.2): projects from `workspace:load` (hide `closed`, grey
/// out `unavailable`), each with its terminal-node session rows. SSH projects are shown read-only
/// (their sessions can't be live on the Server Edition — SPEC §11.2).
public struct ServerDetailView: View {
    @EnvironmentObject private var env: AppEnvironment
    let profile: ServerProfile

    public init(profile: ServerProfile) { self.profile = profile }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let runtime = env.runtime(for: profile.id) {
                    projects(runtime)
                } else {
                    EmptyHint("This server is offline. Pull to connect or sign in from Home.")
                }
                logoutButton
            }
            .padding(16)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(profile.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder private func projects(_ runtime: ServerRuntime) -> some View {
        let visible = (runtime.workspace?.projects ?? []).filter { $0.closed != true }
        if visible.isEmpty {
            EmptyHint("No open projects on this server.")
        } else {
            ForEach(visible, id: \.id) { project in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Circle().fill(Theme.accent).frame(width: 8, height: 8)
                        Text(project.name).font(.headline).foregroundStyle(Theme.textPrimary)
                        if project.isSSH {
                            Text("SSH").font(.caption2.weight(.bold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Theme.separator).clipShape(Capsule())
                                .foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                    }
                    let rows = SessionListModel.rows(serverId: profile.id, serverName: profile.name,
                                                     workspace: Workspace(projects: [project])) { runtime.status(for: $0) }
                    if rows.isEmpty {
                        Text("No terminal sessions").font(.caption).foregroundStyle(Theme.textTertiary)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(rows) { row in
                                SessionRowView(row: row, showServer: false)
                                if row.id != rows.last?.id { Divider().background(Theme.separator) }
                            }
                        }
                    }
                }
                .opacity(project.unavailable == true ? 0.5 : 1)   // grey out unavailable (§9.2)
                .padding(14).card()
            }
        }
    }

    private var logoutButton: some View {
        Button(role: .destructive) {
            Task { await env.removeServer(profile) }
        } label: {
            Label("Log out & remove server", systemImage: "rectangle.portrait.and.arrow.right")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(Theme.needsYou)
        .padding(.top, 8)
        .overlay(alignment: .bottom) {
            // SPEC §3.4 / §9 rule 9: be honest that the server session survives to TTL.
            Text("The server session stays valid until it expires (30 days). Logging out removes it from this device.")
                .font(.caption2).foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center).offset(y: 36)
        }
        .padding(.bottom, 40)
    }
}
