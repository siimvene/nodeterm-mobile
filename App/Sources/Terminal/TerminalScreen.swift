import SwiftUI
import UIKit
import NodetermKit

/// Writes to the device clipboard (SPEC §7.7 OSC 52 write path). Isolated so `UIPasteboard` has one
/// owner and never a read exposed to the remote side.
enum ClipboardBridge {
    @MainActor static func write(_ text: String) { UIPasteboard.general.string = text }
    @MainActor static func read() -> String? { UIPasteboard.general.string }
}

/// TERMINAL VIEW (SPEC §9.3): SwiftTerm surface + full co-attach lifecycle (§7), header with badge
/// + context meter, and the keyboard accessory toolbar (Esc/Tab/Ctrl/arrows/paste/mic).
public struct TerminalScreen: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var vm: TerminalSessionVM
    @ObservedObject private var runtime: ServerRuntime

    @State private var showDictation = false
    @State private var copiedPill = false

    private let row: SessionRow

    public init(runtime: ServerRuntime, row: SessionRow) {
        self.runtime = runtime
        self.row = row
        _vm = StateObject(wrappedValue: TerminalSessionVM(runtime: runtime, row: row))
    }

    public var body: some View {
        VStack(spacing: 0) {
            terminalSurface
            AccessoryToolbar(vm: vm, settings: settings, onMic: { showDictation = true })
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(row.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { headerToolbar }
        .overlay(alignment: .bottomTrailing) { if copiedPill { copiedView } }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { vm.park() }      // SPEC §7.3 PARK on background
            if phase == .active { vm.unpark() }
        }
        .sheet(isPresented: $showDictation) {
            DictationSheet(runtime: runtime, settings: settings) { text, submit in
                Task { await vm.sendText(text, submit: submit) }
            }
        }
    }

    // MARK: Terminal surface

    private var terminalSurface: some View {
        GeometryReader { geo in
            ZStack {
                SwiftTermView(
                    handle: vm.handle,
                    fontSize: CGFloat(settings.fontSize),
                    theme: settings.theme,
                    onInput: { vm.write($0) },
                    onSizeChange: { cols, rows in vm.reportSize(cols: cols, rows: rows) },
                    onClipboardWrite: { text in vm.onClipboardWrite(text); flashCopied() },
                    ctrlLatched: { vm.ctrlLatched },
                    clearCtrlLatch: { vm.ctrlLatched = false }
                )
                overlayForPhase
            }
            .onAppear {
                // Approximate initial grid from the surface; the emulator's sizeChanged refines it.
                let cols = max(Int(geo.size.width / (CGFloat(settings.fontSize) * 0.6)), 20)
                let rows = max(Int(geo.size.height / (CGFloat(settings.fontSize) * 1.2)), 10)
                vm.onAppear(initialCols: cols, initialRows: rows)
            }
            .onDisappear { vm.onDisappear() }   // kill-own-viewer (SPEC §7.4)
        }
    }

    @ViewBuilder private var overlayForPhase: some View {
        switch vm.phase {
        case .connecting:
            ProgressView().tint(Theme.accent)
        case .closed(let by):
            phaseCard(icon: "xmark.octagon", title: "Session closed",
                      detail: by != nil ? "Closed on another device." : "This session was closed.")
        case .unavailable(let reason):
            phaseCard(icon: "exclamationmark.triangle",
                      title: "Not available",
                      detail: reason == "ssh" ? "This is an SSH session the server can't reach." :
                              reason == "codex-account" ? "The Codex account isn't available here." :
                              "This session can't run here right now.")
        case .exited(let code):
            phaseCard(icon: "power", title: "Process exited", detail: "Exit code \(code).")
        case .ready:
            EmptyView()
        }
    }

    private func phaseCard(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.largeTitle).foregroundStyle(Theme.needsYou)
            Text(title).font(.headline).foregroundStyle(Theme.textPrimary)
            Text(detail).font(.caption).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
        }
        .padding(20).card().padding(24)
    }

    // MARK: Header (SPEC §9.3)

    @ToolbarContentBuilder private var headerToolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            HStack(spacing: 8) {
                Text(row.title).font(.headline).foregroundStyle(Theme.textPrimary).lineLimit(1)
                BadgeView(badge: runtime.status(for: row.nodeId)?.badge ?? .none)
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            if let ctx = runtime.status(for: row.nodeId)?.context {
                ContextPill(model: ctx.model, percent: ctx.usedPercent)
            }
        }
    }

    private var copiedView: some View {
        Text("Copied").font(.caption2.weight(.semibold))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Theme.accent.opacity(0.9)).foregroundStyle(.white)
            .clipShape(Capsule()).padding(16)
            .transition(.opacity)
    }

    private func flashCopied() {
        withAnimation { copiedPill = true }
        Task { try? await Task.sleep(for: .seconds(1.2)); withAnimation { copiedPill = false } }
    }
}

/// Context-window meter pill (SPEC §9.3): model + % from `context:update`.
struct ContextPill: View {
    let model: String?
    let percent: Double
    var body: some View {
        HStack(spacing: 4) {
            if let model { Text(model).lineLimit(1) }
            Text("\(Int(percent))%").monospacedDigit()
        }
        .font(.caption2.weight(.medium)).foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Theme.card).clipShape(Capsule())
    }
}

/// The keyboard accessory toolbar (SPEC §9.3): Esc · Tab · Ctrl (latch) · arrows · paste · mic,
/// user-configurable order (Settings → Input). Haptics when enabled.
struct AccessoryToolbar: View {
    @ObservedObject var vm: TerminalSessionVM
    @ObservedObject var settings: AppSettings
    let onMic: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(settings.toolbarKeys) { key in keyButton(key) }
                // Shift+Enter is a hardware-keyboard chord (SPEC §7.6) surfaced as a soft key.
                pill("⇧⏎") { haptic(); vm.sendShiftEnter() }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .background(Theme.card.ignoresSafeArea(edges: .bottom))
    }

    @ViewBuilder private func keyButton(_ key: AppSettings.ToolbarKey) -> some View {
        switch key {
        case .esc: pill("Esc") { haptic(); vm.writeRaw("\u{1b}") }
        case .tab: pill("Tab") { haptic(); vm.writeRaw("\t") }
        case .ctrl:
            pill("Ctrl", active: vm.ctrlLatched) { haptic(); vm.ctrlLatched.toggle() }
        case .arrows:
            pill("←") { haptic(); vm.writeRaw("\u{1b}[D") }
            pill("↓") { haptic(); vm.writeRaw("\u{1b}[B") }
            pill("↑") { haptic(); vm.writeRaw("\u{1b}[A") }
            pill("→") { haptic(); vm.writeRaw("\u{1b}[C") }
        case .paste:
            pill("Paste") { haptic(); if let text = ClipboardBridge.read() { vm.pasteFromClipboard(text) } }
        case .mic:
            pill("Mic", systemImage: "mic.fill") { haptic(); onMic() }
        }
    }

    private func pill(_ title: String, systemImage: String? = nil, active: Bool = false,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title)
            }
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(active ? Theme.accent.opacity(0.3) : Theme.cardElevated)
            .foregroundStyle(active ? Theme.accent : Theme.textPrimary)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func haptic() {
        guard settings.hapticKeys else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}
