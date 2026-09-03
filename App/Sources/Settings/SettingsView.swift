import SwiftUI
import NodetermKit

/// SETTINGS (SPEC §9.4): Terminal · Input · Notifications (honest scope, §9.6) · Integrations
/// (empty in v0) · About. No subscription/entitlement UI anywhere (SPEC §1). Server-side `Settings`
/// is read-only and never written back (SPEC §5.2).
public struct SettingsView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    public init() {}

    public var body: some View {
        NavigationStack {
            Form {
                terminalSection
                inputSection
                notificationsSection
                integrationsSection
                aboutSection
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    // MARK: Terminal (SPEC §9.4)

    private var terminalSection: some View {
        Section("Terminal") {
            Picker("Theme", selection: Binding(get: { settings.theme }, set: { settings.theme = $0 })) {
                ForEach(AppSettings.TerminalTheme.allCases) { Text($0.label).tag($0) }
            }
            HStack {
                Text("Font size")
                Spacer()
                Text("\(Int(settings.fontSize)) pt").foregroundStyle(Theme.textSecondary)
            }
            Slider(value: $settings.fontSize, in: 9...22, step: 1)   // default 13 pt (§8.3/§9.4)
            Toggle("Terminal bell", isOn: $settings.bellEnabled)
            Toggle("Block cursor", isOn: $settings.blockCursor)
        }
    }

    // MARK: Input (SPEC §9.4)

    private var inputSection: some View {
        Section("Input") {
            NavigationLink("Toolbar keys") { ToolbarConfigView() }
            Picker("Speech engine",
                   selection: Binding(get: { settings.defaultSpeechEngine },
                                      set: { settings.defaultSpeechEngine = $0 })) {
                ForEach(AppSettings.SpeechEngine.allCases) { Text($0.label).tag($0) }
            }
            if !env.profiles.isEmpty {
                NavigationLink("Server whisper (per server)") { PerServerSpeechView() }
            }
            Toggle("Haptic keys", isOn: $settings.hapticKeys)
        }
    }

    // MARK: Notifications — honest scope (SPEC §9.6)

    private var notificationsSection: some View {
        Section("Notifications") {
            Toggle("Session finished", isOn: $settings.notifyOnCompletion)
            Toggle("Needs your response", isOn: $settings.notifyOnNeedsYou)
            // §9.6: the self-hosted server has NO push relay — be explicit, no fake background toggles.
            Text("Notifications work while Termscape is open; iOS may occasionally check in the background. There is no push server, so alerts can't arrive when the app is fully closed.")
                .font(.caption).foregroundStyle(Theme.textSecondary)
        }
    }

    // MARK: Integrations (empty in v0) / About (SPEC §9.4)

    private var integrationsSection: some View {
        Section("Integrations") {
            Text("None yet.").foregroundStyle(Theme.textTertiary)
        }
    }

    private var aboutSection: some View {
        Section("About") {
            HStack { Text("Version"); Spacer()
                Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                    .foregroundStyle(Theme.textSecondary) }
            NavigationLink("Open source licenses") { LicensesView() }
            Link("Built on nodeterm", destination: URL(string: "https://nodeterm.dev")!)
        }
    }
}

/// Reorder / enable the accessory toolbar keys (SPEC §9.3/§9.4 Input).
struct ToolbarConfigView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var keys: [AppSettings.ToolbarKey] = []

    var body: some View {
        List {
            Section {
                ForEach(keys) { key in Text(key.label) }
                    .onMove { keys.move(fromOffsets: $0, toOffset: $1); settings.toolbarKeys = keys }
                    .onDelete { keys.remove(atOffsets: $0); settings.toolbarKeys = keys }
            } footer: {
                Text("Drag to reorder, swipe to remove. Removed keys can be restored with Reset.")
            }
            Section {
                let missing = AppSettings.ToolbarKey.allCases.filter { !keys.contains($0) }
                ForEach(missing) { key in
                    Button {
                        keys.append(key); settings.toolbarKeys = keys
                    } label: { Label("Add \(key.label)", systemImage: "plus") }
                }
                Button("Reset to default") { settings.toolbarKeys = AppSettings.ToolbarKey.allCases; keys = settings.toolbarKeys }
            }
        }
        .navigationTitle("Toolbar keys")
        .environment(\.editMode, .constant(.active))
        .onAppear { keys = settings.toolbarKeys }
    }
}

/// Per-server whisper opt-in (SPEC §9.4 Input / §9.5).
struct PerServerSpeechView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            ForEach(env.profiles) { profile in
                Picker(profile.name,
                       selection: Binding(get: { settings.speechEngine(forServer: profile.id) },
                                          set: { settings.setSpeechEngine($0, forServer: profile.id) })) {
                    ForEach(AppSettings.SpeechEngine.allCases) { Text($0.label).tag($0) }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Server whisper")
    }
}

struct LicensesView: View {
    var body: some View {
        List {
            Section("Third-party") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("SwiftTerm").font(.headline)
                    Text("MIT License · migueldeicaza/SwiftTerm").font(.caption).foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .navigationTitle("Licenses")
    }
}
