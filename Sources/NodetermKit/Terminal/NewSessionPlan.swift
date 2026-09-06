import Foundation

/// Pure composition for SPAWNING a new session as a node (SPEC §7.11) — the one place the phone is
/// the first client. Every function here is a pure value transform with an injectable clock/random,
/// so the whole launch grammar is unit-tested without a live server.
///
/// The four wire steps (mint → `pty:create` → `pty:send-text` → `workspace:register-node`) live in
/// the App layer's terminal VM; this module owns only the pieces that must match the desktop
/// byte-for-byte: the node id shape, the launch command grammar, and the registration payload.
public enum NewSessionPlan {

    // MARK: - Node id (SPEC §7.11.1)

    /// Mint a node id of the desktop shape `term-<base36 ms>-<hex>` that satisfies BOTH the
    /// registration regex `^term-[a-z0-9]+-[a-z0-9]{1,16}$` AND the 128-char `NODE_ID_MAX`. The id
    /// becomes a tmux session name, so the alphabet is not negotiable. Mint ONCE and reuse the same
    /// string as `persistKey` in every later call.
    ///
    /// `random` supplies the trailing entropy (a UInt64 rendered as 1–16 lowercase hex chars);
    /// `now` supplies the base36 millisecond stamp. Both injected so the shape is testable.
    public static func mintNodeId(now: Date, random: () -> UInt64) -> String {
        let ms = UInt64(max(0, (now.timeIntervalSince1970 * 1000).rounded(.down)))
        let base36 = String(ms, radix: 36)          // [0-9a-z]+ (never empty; ms ≥ 0)
        var hex = String(random(), radix: 16)        // [0-9a-f], 1…16 chars (UInt64 → ≤16)
        if hex.count > 16 { hex = String(hex.suffix(16)) }
        let id = "term-\(base36)-\(hex)"
        // The middle segment is unbounded, so the 128 cap is a separate check (SPEC §7.11.1). It is
        // never reached in practice (base36 of a millisecond stamp is ~8 chars), so truncating from
        // the end here cannot land mid-suffix for any real clock.
        return id.count > 128 ? String(id.prefix(128)) : id
    }

    // MARK: - Launch command (SPEC §7.11.3)

    /// The permission modes the CLIs understand (mirrors `ALL_PERMISSION_MODES`). An unrecognized
    /// value yields the bare, safe command — the value comes from hand-editable, git-shared JSON.
    private static let knownModes: Set<String> =
        ["manual", "auto", "acceptEdits", "plan", "bypassPermissions"]

    /// Mirrors the desktop's `DEFAULT_PERMISSION_MODE`.
    public static let defaultPermissionMode = "auto"

    /// Mirrors the desktop's `isPermissionMode`: usable only if it is one of the known modes.
    public static func isPermissionMode(_ value: String?) -> Bool {
        guard let value else { return false }
        return knownModes.contains(value)
    }

    /// The mode a NEW session starts in — the desktop's `resolvePermissionMode`, layer for layer: a
    /// VALID project override wins; else a VALID global setting; else the default (`auto`). Each
    /// layer is validated on its own, so a stale/mistyped project value falls THROUGH to the setting
    /// rather than to the bare command (both come from hand-editable, git-shared JSON). The
    /// claude-only `auto` gate (`caps.autoPermissionMode`) applies AFTER this, in `launchCommand`.
    public static func resolvePermissionMode(projectMode: String?, settingsMode: String?) -> String {
        if let projectMode, isPermissionMode(projectMode) { return projectMode }
        if let settingsMode, isPermissionMode(settingsMode) { return settingsMode }
        return defaultPermissionMode
    }

    /// Assemble the launch line for a FRESH session, mirroring the desktop's `assembleLaunchCommand`
    /// + `approvalFlags` for the three builtins the phone can spawn. Returns `nil` for a plain
    /// terminal (no `agentId`) or any agent outside claude/codex/gemini — nothing is typed then.
    ///
    /// claude/codex/gemini declare no `argvPromptSeparator`, so the approval flag goes LAST and the
    /// command line stays byte-identical to the desktop's. A mode a CLI cannot express emits NO flag
    /// (never a substituted nearest match), and `--permission-mode auto` is emitted only when the
    /// probe advertises it AND only for claude.
    public static func launchCommand(agentId: String?, permissionMode: String,
                                     caps: ClaudeCliCaps) -> String? {
        guard let agentId else { return nil }
        switch agentId {
        case "claude": return joined("claude", claudeFlags(permissionMode, caps: caps))
        case "codex":  return joined("codex", codexFlags(permissionMode))
        case "gemini": return joined("gemini", geminiFlags(permissionMode))
        default:       return nil
        }
    }

    private static func joined(_ program: String, _ flags: [String]) -> String {
        flags.isEmpty ? program : "\(program) \(flags.joined(separator: " "))"
    }

    /// claude — `permissionModeFlag` behind the `auto` gate (`gatePermissionMode`): `auto` degrades
    /// to `manual` (= no flag) unless `caps.autoPermissionMode`; `manual` and any unknown value emit
    /// no flag; the other three emit `--permission-mode <mode>`.
    private static func claudeFlags(_ mode: String, caps: ClaudeCliCaps) -> [String] {
        guard knownModes.contains(mode) else { return [] }
        let gated = (mode == "auto" && !caps.autoPermissionMode) ? "manual" : mode
        if gated == "manual" { return [] }
        return ["--permission-mode", gated]
    }

    /// codex — `--ask-for-approval untrusted|on-request`, or the full-yolo bypass flag. `acceptEdits`
    /// and `plan` have NO codex equivalent, so they emit nothing (its own `OnRequest` default).
    private static func codexFlags(_ mode: String) -> [String] {
        switch mode {
        case "manual":            return ["--ask-for-approval", "untrusted"]
        case "auto":              return ["--ask-for-approval", "on-request"]
        case "bypassPermissions": return ["--dangerously-bypass-approvals-and-sandbox"]
        default:                  return []   // acceptEdits / plan / unknown → bare command
        }
    }

    /// gemini — `--approval-mode plan|auto_edit|yolo`. `manual` is gemini's own `default` (no flag),
    /// and `auto` has NO gemini equivalent (nothing means "approve most but not edits"), so it emits
    /// nothing rather than silently widening edits.
    private static func geminiFlags(_ mode: String) -> [String] {
        switch mode {
        case "acceptEdits":       return ["--approval-mode", "auto_edit"]
        case "plan":              return ["--approval-mode", "plan"]
        case "bypassPermissions": return ["--approval-mode", "yolo"]
        default:                  return []   // manual / auto / unknown → bare command
        }
    }

    // MARK: - Registration payload (SPEC §7.11.4)

    /// The `workspace:register-node` payload object `{id, title?, agentId?, accountId?}`. A nil
    /// optional is OMITTED (encodeIfPresent semantics) rather than sent as `null` — the server reads
    /// `null` as "omitted" but refuses any non-string value, so only strings or absence may appear.
    public static func registerPayload(id: String, title: String?, agentId: String?,
                                       accountId: String?) -> JSONValue {
        var obj: [String: JSONValue] = ["id": .string(id)]
        if let title { obj["title"] = .string(title) }
        if let agentId { obj["agentId"] = .string(agentId) }
        if let accountId { obj["accountId"] = .string(accountId) }
        return .object(obj)
    }

    /// The starting title the CANVAS will draw for a registration that sends NO explicit title,
    /// mirroring the host's `appendProjectNode` (`agent?.label ?? "Mobile session"`, SPEC §7.11.4).
    /// The phone shows this on the synthetic row/header so it matches the node once it registers —
    /// the host stamps `titleAuto:true`, so the agent's own session name takes over later either way.
    /// Labels mirror the desktop `agentConfig` for the three builtins the phone can spawn; a plain
    /// terminal (nil agentId), or any id outside them, falls back to the literal "Mobile session".
    public static func derivedTitle(agentId: String?) -> String {
        switch agentId {
        case "claude": return "Claude Code"
        case "codex":  return "Codex"
        case "gemini": return "Gemini"
        default:       return "Mobile session"
        }
    }
}
