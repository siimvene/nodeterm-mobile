import SwiftUI
import UIKit
import NodetermKit

/// App entry point + composition root wiring (SPEC §8). Builds `AppEnvironment` from the `Factory`
/// singletons and injects it. Foreground connects auto-connect servers; background disconnects
/// (SPEC §8.4 — the socket is expected to die in background, §12 item 1).
@main
struct TermscapeApp: App {
    @StateObject private var environment: AppEnvironment
    @StateObject private var settings: AppSettings
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // SwiftUI creates the App on the main thread; `AppSettings`/`AppEnvironment`/`Factory` are
        // all @MainActor, so assert isolation to build them here.
        let (env, settings) = MainActor.assumeIsolated { () -> (AppEnvironment, AppSettings) in
            let settings = AppSettings()
            let env = AppEnvironment(settings: settings,
                                     profileStore: Factory.makeProfileStore(),
                                     keychain: Factory.makeKeychain(),
                                     auth: Factory.makeAuth(),
                                     deviceName: UIDevice.current.name)
            return (env, settings)
        }
        _settings = StateObject(wrappedValue: settings)
        _environment = StateObject(wrappedValue: env)
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(environment)
                .environmentObject(settings)
                .preferredColorScheme(.dark)   // SPEC §9: dark app
                .tint(Theme.accent)
                .onAppear { environment.enableNotifications() }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: environment.connectAll()
            case .background: environment.disconnectAll()
            default: break
            }
        }
    }
}
