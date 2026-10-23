import Foundation

/// Feature-detected Claude CLI capabilities from `claude-cli:caps` (SPEC §7.11.3). Both flags are
/// probed from the CLI's `--help`, never a version floor: an unknown flag makes the CLI exit, so a
/// launcher must only emit a flag the probe confirmed.
///
/// **Fail-closed decode:** a missing/mangled field → `false`, and a failed probe (no reply at all)
/// → the all-false default. That degrades to the bare, safe command line rather than a launch that
/// dies on an unrecognized flag.
public struct ClaudeCliCaps: Codable, Sendable, Equatable, Hashable {
    /// Whether `--permission-mode auto` may be emitted. **CLAUDE only** — an old claude CLI exits 1
    /// on the value, and the flag has no meaning for other agents (SPEC §7.11.3).
    public var autoPermissionMode: Bool
    /// Whether `--session-id <uuid>` may be minted for a first launch (claude-base only, SPEC §7.11.3).
    public var sessionIdFlag: Bool

    public init(autoPermissionMode: Bool = false, sessionIdFlag: Bool = false) {
        self.autoPermissionMode = autoPermissionMode
        self.sessionIdFlag = sessionIdFlag
    }

    private enum CodingKeys: String, CodingKey { case autoPermissionMode, sessionIdFlag }
    public init(from decoder: Decoder) throws {
        // Tolerant + fail-closed: an absent or non-bool field reads as `false`.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.autoPermissionMode =
            ((try? c.decodeIfPresent(Bool.self, forKey: .autoPermissionMode)) ?? nil) ?? false
        self.sessionIdFlag =
            ((try? c.decodeIfPresent(Bool.self, forKey: .sessionIdFlag)) ?? nil) ?? false
    }
}
