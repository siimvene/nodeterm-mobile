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
        case esc, tab, ctrl, arrows, paste, mic
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .esc: return "Esc"; case .tab: return "Tab"; case .ctrl: return "Ctrl"
            case .arrows: return "Arrows"; case .paste: return "Paste"; case .mic: return "Mic"
            }
        }
    }

    /// Dictation engine choice (SPEC §9.5). `.apple` is on-device default; `.serverWhisper` is the
    /// opt-in per-server alternative.
    public enum SpeechEngine: String, CaseIterable, Identifiable, Sendable {
        case apple, serverWhisper
        public var id: String { rawValue }
        public var label: String { self == .apple ? "Apple on-device" : "Server whisper" }
    }

    @AppStorage("term.theme") private var themeRaw: String = TerminalTheme.dark.rawValue
    /// Default font size 13 pt (SPEC §8.3 / §9.4).
    @AppStorage("term.fontSize") public var fontSize: Double = 13
    @AppStorage("term.bell") public var bellEnabled: Bool = true
    @AppStorage("term.blockCursor") public var blockCursor: Bool = true

    @AppStorage("input.hapticKeys") public var hapticKeys: Bool = true
    /// The default speech engine; a per-server override lives in `serverSpeechEngine`.
    @AppStorage("input.speechEngine") private var speechEngineRaw: String = SpeechEngine.apple.rawValue

    @AppStorage("notify.completion") public var notifyOnCompletion: Bool = true
    @AppStorage("notify.needsYou") public var notifyOnNeedsYou: Bool = true

    /// Ordered toolbar keys (JSON in UserDefaults). Default order matches SPEC §9.3.
    @AppStorage("input.toolbarOrder") private var toolbarOrderData: Data = Data()
    /// Per-server whisper opt-in (serverProfileId → engine). JSON in UserDefaults.
    @AppStorage("input.serverSpeech") private var serverSpeechData: Data = Data()

    public var theme: TerminalTheme {
        get { TerminalTheme(rawValue: themeRaw) ?? .dark }
        set { themeRaw = newValue.rawValue; objectWillChange.send() }
    }

    public var defaultSpeechEngine: SpeechEngine {
        get { SpeechEngine(rawValue: speechEngineRaw) ?? .apple }
        set { speechEngineRaw = newValue.rawValue; objectWillChange.send() }
    }

    public var toolbarKeys: [ToolbarKey] {
        get {
            guard let decoded = try? JSONDecoder().decode([ToolbarKey].self, from: toolbarOrderData),
                  !decoded.isEmpty else { return ToolbarKey.allCases }
            return decoded
        }
        set {
            toolbarOrderData = (try? JSONEncoder().encode(newValue)) ?? Data()
            objectWillChange.send()
        }
    }

    /// Effective speech engine for a server: its override if set, else the default.
    public func speechEngine(forServer profileId: String) -> SpeechEngine {
        let map = (try? JSONDecoder().decode([String: String].self, from: serverSpeechData)) ?? [:]
        return map[profileId].flatMap(SpeechEngine.init(rawValue:)) ?? defaultSpeechEngine
    }

    public func setSpeechEngine(_ engine: SpeechEngine, forServer profileId: String) {
        var map = (try? JSONDecoder().decode([String: String].self, from: serverSpeechData)) ?? [:]
        map[profileId] = engine.rawValue
        serverSpeechData = (try? JSONEncoder().encode(map)) ?? serverSpeechData
        objectWillChange.send()
    }

    public init() {}
}
