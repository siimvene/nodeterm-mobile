import Foundation

/// The read-only subset of server `Settings` a phone MAY read (SPEC §11.7 / §5.2). Everything else
/// is desktop render config — ignored, and NEVER written back (`settings:save` MUST NOT be called
/// in v0). Missing fields fall back to the spec defaults.
public struct Settings: Sendable, Equatable {
    /// Default `'auto'` (SPEC §11.7).
    public var claudePermissionMode: String
    public var defaultShell: String?
    /// Default `50000` (SPEC §11.7).
    public var tmuxScrollback: Int

    public init(claudePermissionMode: String = "auto",
                defaultShell: String? = nil,
                tmuxScrollback: Int = 50000) {
        self.claudePermissionMode = claudePermissionMode
        self.defaultShell = defaultShell
        self.tmuxScrollback = tmuxScrollback
    }
}

extension Settings: Codable {
    private enum CodingKeys: String, CodingKey {
        case claudePermissionMode, defaultShell, tmuxScrollback
    }

    public init(from decoder: Decoder) throws {
        // Tolerant: an absent field yields the spec default (§11.7), unknown keys are ignored.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.claudePermissionMode =
            try c.decodeIfPresent(String.self, forKey: .claudePermissionMode) ?? "auto"
        self.defaultShell = try c.decodeIfPresent(String.self, forKey: .defaultShell)
        self.tmuxScrollback =
            try c.decodeIfPresent(Int.self, forKey: .tmuxScrollback) ?? 50000
    }
}
