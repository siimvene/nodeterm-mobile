import SwiftUI
import NodetermKit

// Placeholder app entry point. Builder 5 (App / UI) replaces this with the real
// SwiftUI surface (Home, Server detail, Terminal view, Settings — SPEC §9).
// It exists so the iOS app target links against NodetermKit and SwiftTerm and the
// project generates before any UI work has landed.
@main
struct NodetermMobileApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

private struct ContentView: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("nodeterm")
                .font(.largeTitle.bold())
            Text("skeleton — UI not built yet")
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}
