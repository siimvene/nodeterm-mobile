import SwiftUI
import Combine

/// Device-local UI settings (SPEC §9.4). These are the PHONE's own preferences — distinct from the
/// server `Settings` (§11.7, read-only). Persisted to `UserDefaults` (NOT secrets — those are
/// Keychain-only, §10). No subscription/entitlement fields exist anywhere (§1 hard requirement).
@MainActor
public final class AppSettings: ObservableObject {

    public enum TerminalTheme: String, CaseIterable, Identifiable, Sendable {
        case dark, dimmed, solarizedDark, highContrast
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .dark: return "nodeterm Dark"
            case .dimmed: return "Dimmed"
            case .solarizedDark: return "Solarized Dark"
            case .highContrast: return "High Contrast"
            }
        }
    }

    /// A toolbar accessory key the user can enable/order (SPEC §9.3 / §9.4 Input).
    public enum ToolbarKey: String, CaseIterable, Identifiable, Codable, Sendable {
        case esc, tab, ctrl, upDown, arrows, paste, mic
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .esc: return "Esc"; case .tab: return "Tab"; case .ctrl: return "Ctrl"
            case .upDown: return "↑↓"; case .arrows: return "Arrows (all 4)"
            case .paste: return "Paste"; case .mic: return "Mic"
            }
        }

        /// Default set, sized for the phone's main job — reading a Claude session and answering
        /// it: Esc (interrupt/back out), Tab (accept the greyed-out ghost suggestion / complete —
        /// the same key that accepts it on desktop), ↑↓ (pick options, recall history), Paste, Mic.
        /// Ctrl and the full arrow cluster stay opt-in via Settings → Toolbar.
        public static let defaultSet: [ToolbarKey] = [.esc, .tab, .upDown, .paste, .mic]
    }

    /// Dictation engine choice (SPEC §9.5). `.apple` is on-device default; `.serverWhisper` is the
    /// opt-in per-server alternative.
    public enum SpeechEngine: String, CaseIterable, Identifiable, Sendable {
        case apple, serverWhisper
        public var id: String { rawValue }
        public var label: String { self == .apple ? "Apple on-device" : "Server whisper" }
    }

    // ── Persistence ──────────────────────────────────────────────────────────
    // NOT @AppStorage: that wrapper only publishes inside a View — in an ObservableObject it
    // writes UserDefaults silently and `objectWillChange` never fires, so Settings changes
    // persisted but no screen re-rendered (the original bug). @Published + didSet-persist gives
    // both halves: observation for SwiftUI, UserDefaults for restarts.

    private static let d = UserDefaults.standard

    @Published public var fontSize: Double {
        didSet { Self.d.set(fontSize, forKey: "term.fontSize") }
    }
    @Published public var bellEnabled: Bool {
        didSet { Self.d.set(bellEnabled, forKey: "term.bell") }
    }
    @Published public var blockCursor: Bool {
        didSet { Self.d.set(blockCursor, forKey: "term.blockCursor") }
    }
    @Published public var hapticKeys: Bool {
        didSet { Self.d.set(hapticKeys, forKey: "input.hapticKeys") }
    }
    @Published public var notifyOnCompletion: Bool {
        didSet { Self.d.set(notifyOnCompletion, forKey: "notify.completion") }
    }
    @Published public var notifyOnNeedsYou: Bool {
        didSet { Self.d.set(notifyOnNeedsYou, forKey: "notify.needsYou") }
    }
    @Published public var theme: TerminalTheme {
        didSet { Self.d.set(theme.rawValue, forKey: "term.theme") }
    }
    @Published public var defaultSpeechEngine: SpeechEngine {
        didSet { Self.d.set(defaultSpeechEngine.rawValue, forKey: "input.speechEngine") }
    }
    @Published public var toolbarKeys: [ToolbarKey] {
        didSet { Self.d.set((try? JSONEncoder().encode(toolbarKeys)) ?? Data(), forKey: "input.toolbarOrder") }
    }
    @Published private var serverSpeech: [String: String] {
        didSet { Self.d.set((try? JSONEncoder().encode(serverSpeech)) ?? Data(), forKey: "input.serverSpeech") }
    }

    /// Effective speech engine for a server: its override if set, else the default.
    public func speechEngine(forServer profileId: String) -> SpeechEngine {
        serverSpeech[profileId].flatMap(SpeechEngine.init(rawValue:)) ?? defaultSpeechEngine
    }

    public func setSpeechEngine(_ engine: SpeechEngine, forServer profileId: String) {
        serverSpeech[profileId] = engine.rawValue
    }

    public init() {
        let d = Self.d
        fontSize = d.object(forKey: "term.fontSize") as? Double ?? 13   // default 13 pt (§8.3/§9.4)
        bellEnabled = d.object(forKey: "term.bell") as? Bool ?? true
        blockCursor = d.object(forKey: "term.blockCursor") as? Bool ?? true
        hapticKeys = d.object(forKey: "input.hapticKeys") as? Bool ?? true
        notifyOnCompletion = d.object(forKey: "notify.completion") as? Bool ?? true
        notifyOnNeedsYou = d.object(forKey: "notify.needsYou") as? Bool ?? true
        theme = (d.string(forKey: "term.theme")).flatMap(TerminalTheme.init(rawValue:)) ?? .dark
        defaultSpeechEngine = (d.string(forKey: "input.speechEngine")).flatMap(SpeechEngine.init(rawValue:)) ?? .apple
        if let data = d.data(forKey: "input.toolbarOrder"),
           let decoded = try? JSONDecoder().decode([ToolbarKey].self, from: data), !decoded.isEmpty {
            toolbarKeys = decoded
        } else {
            toolbarKeys = ToolbarKey.defaultSet
        }
        if let data = d.data(forKey: "input.serverSpeech"),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            serverSpeech = decoded
        } else {
            serverSpeech = [:]
        }
    }
}
