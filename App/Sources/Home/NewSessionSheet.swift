import SwiftUI
import NodetermKit

/// The registration + launch payload handed to a freshly-spawned TerminalScreen (SPEC §7.11.3/4).
/// Hashable so it can ride `NewSessionNav` through `navigationDestination(item:)`.
public struct PendingLaunch: Hashable, Sendable {
    /// The launch line to deliver after the shell-settle window, or nil for a plain terminal.
    public var command: String?
    /// Registration fields (§7.11.4) — each omitted from the wire payload when nil.
    public var title: String?
    public var agentId: String?
    public var accountId: String?

    public init(command: String?, title: String?, agentId: String?, accountId: String?) {
        self.command = command
        self.title = title
        self.agentId = agentId
        self.accountId = accountId
    }
}

/// A navigation target for a session the phone is SPAWNING (SPEC §7.11). Distinct from
/// `TerminalTarget`, whose row must already exist in `sessionRows`; a not-yet-registered node is
/// not there, so this carries the synthetic row's fields plus the pending launch directly.
public struct NewSessionNav: Hashable, Sendable {
    public var serverId: String
    public var serverName: String
    public var projectId: String
    public var projectName: String
    public var nodeId: String
    public var title: String
    public var cwd: String?
    public var projectCwd: String?
    public var agentId: String?
    public var accountId: String?
    public var launch: PendingLaunch

    /// The synthetic SessionRow the TerminalScreen mounts against (nodeId = the minted id).
    public func makeRow() -> SessionRow {
        SessionRow(serverId: serverId, serverName: serverName,
                   projectId: projectId, projectName: projectName,
                   nodeId: nodeId, title: title, agentId: agentId,
                   cwd: cwd, accountId: accountId, projectCwd: projectCwd,
                   sshRemoteTmux: false, status: nil)
    }
}

/// A (server, project) pair for presenting `NewSessionSheet` via `.sheet(item:)`. Shared by HOME's
/// project cards and the server-detail project rows.
public struct NewSessionContext: Identifiable {
    public let runtime: ServerRuntime
    public let project: Project
    public var id: String { "\(runtime.profile.id)/\(project.id)" }
    public init(runtime: ServerRuntime, project: Project) {
        self.runtime = runtime
        self.project = project
    }
}

/// Start a NEW session under a project (SPEC §7.11): pick an agent (Terminal / Claude / Codex /
/// Gemini), optionally a managed account and a title, then Start. On Start the sheet mints the node
/// id, assembles the launch line, and hands a `NewSessionNav` to `AppEnvironment` — HOME pushes the
/// TerminalScreen, which spawns, delivers the launch line, and registers the node.
public struct NewSessionSheet: View {
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    let runtime: ServerRuntime
    let project: Project

    public init(runtime: ServerRuntime, project: Project) {
        self.runtime = runtime
        self.project = project
    }

    enum AgentChoice: String, CaseIterable, Identifiable {
        case terminal, claude, codex, gemini
        var id: String { rawValue }
        var label: String {
            switch self {
            case .terminal: return "Terminal"
            case .claude: return "Claude"
            case .codex: return "Codex"
            case .gemini: return "Gemini"
            }
        }
        /// The wire agentId (nil for a plain terminal — no launch line, no agent hook env).
        var agentId: String? { self == .terminal ? nil : rawValue }
        /// Only Claude and Codex run under a managed account.
        var usesAccounts: Bool { self == .claude || self == .codex }
    }

    @State private var agentChoice: AgentChoice = .terminal
    /// nil = the System account (the host's own `~/.claude` / default codex identity).
    @State private var accountId: String?
    @State private var titleText = ""
    @State private var claudeAccounts: [ManagedAccount] = []
    @State private var codexAccounts: [ManagedAccount] = []
    @State private var settingsMode = "auto"
    @State private var caps = ClaudeCliCaps()

    /// SPEC §7.11.2: only a LOCAL project with a cwd can spawn here. An `unavailable` project (its
    /// `project.json` is unreadable right now) is also refused: a `register-node` against it can only
    /// ever resolve UNKNOWN, so starting a session that cannot be saved to the canvas is worse than
    /// explaining why the "+" does nothing yet.
    private var canStart: Bool {
        !project.isSSH && (project.cwd?.isEmpty == false) && project.unavailable != true
    }

    /// The usable managed accounts for the current agent (skip pending / host-pinned, §7.11.3).
    private var accountsForAgent: [ManagedAccount] {
        let all = agentChoice == .codex ? codexAccounts : claudeAccounts
        return all.filter { $0.isUsableHere }
    }

    public var body: some View {
        NavigationStack {
            Form {
                agentSection
                if agentChoice.usesAccounts && !accountsForAgent.isEmpty { accountSection }
                titleSection
                if !canStart { unavailableSection }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("New session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.tint(Theme.textSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") { start() }.disabled(!canStart).tint(Theme.accent)
                }
            }
            .task { await load() }
            .onChange(of: agentChoice) { _, _ in resetAccountDefault() }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: Sections

    private var agentSection: some View {
        Section("Agent") {
            Picker("Agent", selection: $agentChoice) {
                ForEach(AgentChoice.allCases) { choice in Text(choice.label).tag(choice) }
            }
            .pickerStyle(.segmented)
            Text("Runs in \(project.name)\(project.cwd.map { " · \($0)" } ?? "")")
                .font(.caption).foregroundStyle(Theme.textTertiary)
        }
    }

    private var accountSection: some View {
        Section("Account") {
            Picker("Account", selection: $accountId) {
                Text("System account").tag(String?.none)
                ForEach(accountsForAgent) { account in
                    Text(account.displayName).tag(String?.some(account.id))
                }
            }
        }
    }

    private var titleSection: some View {
        Section("Starting name (optional)") {
            TextField("Session name", text: $titleText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Text("Agents rename the session as they work, so this is just the starting name.")
                .font(.caption).foregroundStyle(Theme.textTertiary)
        }
    }

    private var unavailableSection: some View {
        Section {
            Label(unavailableHint, systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(Theme.needsYou)
        }
    }

    /// Why the sheet can't start a session here (SPEC §7.11.2). SSH and cwd-less checks are the
    /// original two; an `unavailable` project (its `project.json` is unreadable) is the third — a
    /// registration would always land UNKNOWN, so the sheet says so rather than starting one blind.
    private var unavailableHint: String {
        if project.isSSH {
            return "SSH projects can't be started from the phone — the server can't reach the host."
        }
        if project.unavailable == true {
            return "The server can't read this project right now."
        }
        return "This project has no working directory, so a session can't be started here."
    }

    // MARK: Load / actions

    private func load() async {
        // Tolerate failure: no accounts, caps false (SPEC §7.11.3).
        if let settings = await runtime.loadSettings() {
            claudeAccounts = settings.claudeAccounts
            codexAccounts = settings.codexAccounts
            settingsMode = settings.claudePermissionMode
        }
        caps = await runtime.loadClaudeCliCaps()
        resetAccountDefault()
    }

    /// Preselect the project's default account when it is a usable option for this agent, else the
    /// System account (SPEC §7.11.3).
    private func resetAccountDefault() {
        if let preferred = project.defaultAccountId,
           accountsForAgent.contains(where: { $0.id == preferred }) {
            accountId = preferred
        } else {
            accountId = nil
        }
    }

    private func start() {
        guard canStart else { return }
        let agentId = agentChoice.agentId
        // The desktop's resolvePermissionMode (SPEC §7.11.3): a VALID project override, else a
        // VALID global setting, else `auto`. The claude-only auto gate applies inside launchCommand.
        let mode = NewSessionPlan.resolvePermissionMode(projectMode: project.defaultPermissionMode,
                                                        settingsMode: settingsMode)
        let command = NewSessionPlan.launchCommand(agentId: agentId, permissionMode: mode, caps: caps)
        let nodeId = NewSessionPlan.mintNodeId(now: Date()) { UInt64.random(in: .min ... .max) }
        let account = agentChoice.usesAccounts ? accountId : nil
        let trimmed = titleText.trimmingCharacters(in: .whitespacesAndNewlines)
        // Send `title` in the registration ONLY when the user typed one. The host stamps `titleAuto`
        // regardless, so a typed name is replaced by the agent's own session name later either way;
        // omitting it lets the host derive the SAME starting label the canvas would (the agent's
        // label, or "Mobile session" for a plain terminal), instead of the phone forcing a second
        // one. The synthetic row/header shows exactly what the canvas will draw — the typed name, or
        // that same derived label — so the two never disagree while registration is in flight.
        let payloadTitle: String? = trimmed.isEmpty ? nil : trimmed
        let displayTitle = payloadTitle ?? NewSessionPlan.derivedTitle(agentId: agentId)
        let launch = PendingLaunch(command: command,
                                   title: payloadTitle,
                                   agentId: agentId,
                                   accountId: account)
        env.newSessionNav = NewSessionNav(
            serverId: runtime.profile.id, serverName: runtime.profile.name,
            projectId: project.id, projectName: project.name,
            nodeId: nodeId, title: displayTitle,
            cwd: project.cwd, projectCwd: project.cwd,
            agentId: agentId, accountId: account, launch: launch)
        dismiss()
    }
}

/// A 44pt "+" button for a project header that opens `NewSessionSheet` without toggling anything
/// else (SPEC §7.11). Shared by HOME's project cards and the server-detail rows.
struct NewSessionButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.body.weight(.semibold))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .tint(Theme.accent)
        .foregroundStyle(Theme.accent)
        .accessibilityLabel("New session")
    }
}
