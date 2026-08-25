import Foundation

/// Pure `PtyCreateOptions` composition for the phone's co-attach join (SPEC §7.1).
public enum TerminalCreatePlan {

    /// Compose the `pty:create` options for co-attaching a canvas terminal node (SPEC §7.1).
    ///
    /// - persistKey is the node id (the SAME id the desktop uses) so `tmux -A` reattaches the
    ///   existing session.
    /// - viewerId is unique within this connection (a fresh UUID per attach); it never collides
    ///   with the desktop (a different clientId), only with the phone's own views of one session.
    /// - cwd / agentId / accountId / ownerProjectId are carried so a `fresh:true` spawn (host
    ///   reboot / phone-first open) lands in the right directory & account rather than the server's
    ///   `$HOME` — a wrong session would become permanent via `tmux -A`.
    /// - requireRemote is set for an SSH-project node or a node with `sshRemoteTmux:true`, so the
    ///   Server Edition (no SSH manager) REFUSES instead of spawning a phantom local shell under
    ///   the remote node's id.
    /// - sshRemote / everySocket are NEVER set (§7.1).
    ///
    /// `sshRemoteTmux` is passed explicitly because `CanvasNodeState` does not model the node's
    /// `data.sshRemoteTmux` flag (see the interface-gap note in the module summary); the project's
    /// SSH marker is derived from `project.isSSH`.
    public static func createOptions(
        for node: CanvasNodeState,
        in project: Project?,
        cols: Int,
        rows: Int,
        viewerId: String,
        shell: String? = nil,
        sshRemoteTmux: Bool = false
    ) -> PtyCreateOptions {
        // SPEC §7.1: prefer the node's own cwd; fall back to the project cwd so a cold spawn still
        // lands in the project folder rather than the server's $HOME.
        let cwd = node.cwd ?? project?.cwd

        // SPEC §7.1: refuse-instead-of-phantom for remote sessions. Only ever `true` or omitted —
        // never `false` (which the encoder would still drop, but keep the intent explicit).
        let requireRemote: Bool? = (project?.isSSH == true || sshRemoteTmux) ? true : nil

        return PtyCreateOptions(
            cols: cols,
            rows: rows,
            persistKey: node.id,          // SPEC §7.1: persistKey == nodeId
            viewerId: viewerId,           // SPEC §7.1: unique per attach
            cwd: cwd,
            shell: shell,                 // usually nil ⇒ server settings-default shell
            shellArgs: nil,
            ownerProjectId: project?.id,
            agentId: node.agentId,
            agentModel: nil,
            accountId: node.accountId,
            sshRemote: nil,               // SPEC §7.1: the phone MUST NEVER set this
            requireRemote: requireRemote
        )
    }
}
