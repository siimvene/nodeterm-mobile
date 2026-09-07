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
    /// `settings:load` AND `claude-cli:caps` have both answered (or failed, tolerated). Start is
    /// held until then: a Start pressed earlier would mint a launch line from the all-false caps
    /// default and a permission mode from the `auto` placeholder — a guess where a read was one
    /// round trip away (consort finding).
    @State private var loaded = false
    /// The user touched the account picker. `resetAccountDefault` (the load completing, or a later
    /// re-run) must not overwrite an explicit pick with the project default (consort finding); an
    /// agent switch resets it, since the pick belonged to the other agent's account list.
    @State private var userPickedAccount = false

    /// SPEC §7.11.2: only a LOCAL project with a cwd can spawn here. An `unavailable` project (its
    /// `project.json` is unreadable right now) is also refused: a `register-node` against it can only
    /// ever resolve UNKNOWN, so starting a session that cannot be saved to the canvas is worse than
    /// explaining why the "+" does nothing yet.
    private var canStart: Bool {
        !project.isSSH && (project.cwd?.isEmpty == false) && project.unavailable != true
    }

    /// The account picker's binding: a write through it is a USER pick (a programmatic default goes
    /// straight to `accountId`), so `resetAccountDefault` can tell the two apart.
    private var pickedAccount: Binding<String?> {
        Binding(get: { accountId }, set: { accountId = $0; userPickedAccount = true })
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
                if agentChoice.agentId != nil { permissionSection }
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
                    if loaded {
                        Button("Start") { start() }.disabled(!canStart).tint(Theme.accent)
                    } else {
                        ProgressView().tint(Theme.textSecondary)
                            .accessibilityLabel("Loading server settings")
                    }
                }
            }
            .task { await load() }
            .onChange(of: agentChoice) { _, _ in
                userPickedAccount = false
                resetAccountDefault()
            }
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
            Picker("Account", selection: pickedAccount) {
                Text("System account").tag(String?.none)
                ForEach(accountsForAgent) { account in
                    Text(account.displayName).tag(String?.some(account.id))
                }
            }
        }
    }

    /// Read-only, mode-taking agents only (claude/codex/gemini): show the RESOLVED permission mode
    /// and where it came from, so an inherited approvals-bypass from a git-shared `project.json`
    /// (or the server setting) is visible before Start, not silent (SPEC §7.11.3). Not editable —
    /// the desktop inherits the project default the same way; the phone only surfaces it.
    private var permissionSection: some View {
        let resolved = NewSessionPlan.resolvePermissionModeWithSource(
            projectMode: project.defaultPermissionMode, settingsMode: settingsMode)
        let bypass = NewSessionPlan.isBypassMode(resolved.mode)
        return Section("Permission mode") {
            HStack {
                Text(Self.modeLabel(resolved.mode))
                    .foregroundStyle(bypass ? Theme.needsYou : Theme.textPrimary)
                Spacer()
                Text(Self.sourceLabel(resolved.source))
                    .font(.caption).foregroundStyle(Theme.textTertiary)
            }
            if bypass {
                Label(agentChoice == .codex
                      ? "Runs without approval prompts and sandbox"
                      : "Runs without approval prompts",
                      systemImage: "exclamationmark.shield")
                    .font(.caption).foregroundStyle(Theme.needsYou)
            }
        }
    }

    /// A resolved permission mode → its display name (the mode strings come from `NewSessionPlan`).
    private static func modeLabel(_ mode: String) -> String {
        switch mode {
        case "manual": return "Manual"
        case "auto": return "Auto"
        case "acceptEdits": return "Accept edits"
        case "plan": return "Plan"
        case "bypassPermissions": return "Bypass approvals"
        default: return mode
        }
    }

    private static func sourceLabel(_ source: NewSessionPlan.PermissionModeSource) -> String {
        switch source {
        case .projectDefault: return "project default"
        case .serverSetting: return "server setting"
        case .fallbackDefault: return "default"
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
        // Tolerate failure: no accounts, caps false (SPEC §7.11.3). Both reads run together — Start
        // stays hidden behind a spinner until both have answered (`loaded`), so a launch line is
        // never minted from the placeholders. The account default is applied as soon as the
        // accounts are known, not after the caps read too, so the picker never shows a list the
        // user can act on and then snaps it back.
        async let settingsRead = runtime.loadSettings()
        async let peerRead = runtime.loadPeerClaudeAccounts()
        async let capsRead = runtime.loadClaudeCliCaps()
        let settings = await settingsRead
        if let settings {
            codexAccounts = settings.codexAccounts
            settingsMode = settings.claudePermissionMode
        }
        // A Server Edition beside a desktop lists no accounts of its own; the desktop's managed
        // Claude accounts arrive through the peer list and are unioned in (SPEC §7.11.3), so the
        // picker exists on that topology at all (it used to offer only the System account).
        claudeAccounts = NewSessionPlan.mergeAccounts(settings: settings?.claudeAccounts ?? [],
                                                      peer: await peerRead)
        resetAccountDefault()
        caps = await capsRead
        loaded = true
    }

    /// Preselect the project's default account when it is a usable option for this agent, else the
    /// System account (SPEC §7.11.3). `Project.defaultAccountId` is a CLAUDE concept on the desktop
    /// (its Canvas applies it to Claude targets only; a Codex target has no project default), so it
    /// is honored for the Claude agent alone — an id that happened to match a Codex account would
    /// otherwise be preselected for Codex (consort finding). Never overrides an explicit user pick.
    private func resetAccountDefault() {
        guard !userPickedAccount else { return }
        if agentChoice == .claude, let preferred = project.defaultAccountId,
           accountsForAgent.contains(where: { $0.id == preferred }) {
            accountId = preferred
        } else {
            accountId = nil
        }
    }

    private func start() {
        guard canStart, loaded else { return }
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
