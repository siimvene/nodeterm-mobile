import Foundation

/// The §7.11.4 read-back decision for a node the phone SPAWNED: was it recorded on the canvas?
/// A pure function of the `workspace:load` result so the whole decision table is unit-tested and
/// the App layer cannot re-derive it wrong (the first cut said "not saved" whenever the load itself
/// had failed and the stale snapshot lacked the node).
///
/// | evidence | outcome |
/// |---|---|
/// | the load FAILED (no fresh snapshot) | `.unknown` — a stale snapshot is not evidence |
/// | project missing from the reply | `.unknown` |
/// | project present but `unavailable == true` | `.unknown` — its empty `nodes` is not evidence |
/// | readable project, node present | `.registered` (a landed-but-lost write) |
/// | readable project, node absent | `.unsaved` (genuinely not recorded) |
///
/// The session is running throughout and is NEVER respawned on any of these; the outcome decides
/// only what the phone says about the canvas.
public enum RegistrationOutcome: String, Sendable, Equatable {
    case registered
    case unsaved
    case unknown

    public static func decide(workspace: Workspace?, loadSucceeded: Bool,
                              projectId: String, nodeId: String) -> RegistrationOutcome {
        guard loadSucceeded, let workspace else { return .unknown }
        guard let project = workspace.projects.first(where: { $0.id == projectId }) else { return .unknown }
        if project.unavailable == true { return .unknown }
        return project.nodes.contains(where: { $0.id == nodeId }) ? .registered : .unsaved
    }
}

/// Whether a launch line may be (re-)delivered into a spawned pane (SPEC §7.11.3). The FIRST
/// delivery goes into a pane the phone created moments ago and needs no check; a RE-delivery — after
/// a `pty:send-text` that threw or answered `false` — must first prove the pane is still a bare
/// shell, because a throw can hide a request that actually landed, and typing `claude` into a
/// running `claude` is a stray prompt, not a launch.
public enum LaunchRedelivery: Sendable, Equatable {
    /// The pane's foreground is an interactive shell at a prompt: deliver.
    case send
    /// Something other than a shell is in the foreground (the agent, an editor): the launch is
    /// already there or would be typed into the wrong process — drop it.
    case alreadyRunning
    /// `pty:pane-command` could not say (`nil`): do nothing now, ask again on the next reconnect.
    case unknown

    /// Mirrors the desktop's `HEAL_SHELL_COMMANDS` — the set of foregrounds a heal may type into.
    /// tmux answers `#{pane_current_command}` as a bare name; a login shell carries a leading `-`.
    static let shellNames: Set<String> = ["zsh", "bash", "sh", "dash", "fish", "ksh", "tcsh", "csh"]

    public static func decide(paneCommand: String?) -> LaunchRedelivery {
        guard let raw = paneCommand?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return .unknown
        }
        var name = raw
        if let slash = name.lastIndex(of: "/") { name = String(name[name.index(after: slash)...]) }
        if name.hasPrefix("-") { name.removeFirst() }
        return shellNames.contains(name) ? .send : .alreadyRunning
    }
}
