import SwiftUI
import UIKit
import SwiftTerm
import NodetermKit

/// A live handle onto the mounted `TerminalView` so the VM can apply `EmulatorInstruction`s and the
/// authoritative `pty:size` grid (SPEC §7.3) without the view owning any session logic. MainActor —
/// UIKit is main-only.
@MainActor
public final class TerminalHandle {
    fileprivate weak var view: TerminalView?

    /// Execute the ordered instruction list (SPEC §7.2/§7.8/§8.3). The emulator is a dumb executor.
    public func apply(_ instructions: [EmulatorInstruction]) {
        guard let view else { return }
        for ins in instructions {
            switch ins {
            case .reset:
                // RIS (ESC c): full reset — clears buffer AND scrollback (SPEC §7.8).
                view.feed(text: "\u{1b}c")
            case .feedRaw(let data):
                view.feed(byteArray: [UInt8](data)[...])   // live VT stream, verbatim (§8.3)
            case .paintCapture(let capture):
                view.feed(text: SeedPaint.captureToTerminalString(capture))   // LF→CRLF (§7.2)
            case .cursor(let x, let y, let visible):
                view.feed(text: SeedPaint.cursorSequence(x: x, y: y, visible: visible))
            case .coAttachMouse:
                view.feed(text: NodetermWire.coAttachMouseSeq)                // §7.2 step 5
            case .coldStartSeparator:
                view.feed(text: "\r\n\u{1b}[90m── session restored · cold start (agent resume happens on the desktop) ──\u{1b}[0m\r\n")
            }
        }
    }

    /// Apply the authoritative co-attach grid (SPEC §7.3): resize the emulator to exactly this grid.
    /// (Letterboxing the slack is a follow-up — see SYMBOLS.md gaps.)
    public func applyGrid(cols: Int, rows: Int) {
        view?.getTerminal().resize(cols: cols, rows: rows)
    }

    /// Current local fit, for the initial `pty:resize` report (SPEC §7.3: a solo viewer never gets
    /// a `pty:size`, so it must report its own fit).
    public func currentSize() -> (cols: Int, rows: Int)? {
        guard let t = view?.getTerminal() else { return nil }
        return (t.cols, t.rows)
    }
}

/// `UIViewRepresentable` wrapping SwiftTerm's `TerminalView` (SPEC §8.3). Feeds `pty:data` verbatim,
/// routes user keystrokes to `pty:write` (with the Ctrl latch), and forwards OSC 52 writes to the
/// device clipboard (write-only, SPEC §7.7/§10.5).
public struct SwiftTermView: UIViewRepresentable {
    let handle: TerminalHandle
    let fontSize: CGFloat
    let theme: AppSettings.TerminalTheme
    /// Raw keystroke bytes from the emulator → route to `pty:write` (already Ctrl-transformed).
    let onInput: (Data) -> Void
    /// Emulator local fit changed → report via `pty:resize` (SPEC §7.3).
    let onSizeChange: (Int, Int) -> Void
    /// OSC 52 clipboard WRITE content (SPEC §7.7).
    let onClipboardWrite: (String) -> Void
    /// Live Ctrl latch state, consulted per keystroke.
    let ctrlLatched: () -> Bool
    let clearCtrlLatch: () -> Void

    public init(handle: TerminalHandle, fontSize: CGFloat, theme: AppSettings.TerminalTheme,
                onInput: @escaping (Data) -> Void, onSizeChange: @escaping (Int, Int) -> Void,
                onClipboardWrite: @escaping (String) -> Void,
                ctrlLatched: @escaping () -> Bool, clearCtrlLatch: @escaping () -> Void) {
        self.handle = handle
        self.fontSize = fontSize
        self.theme = theme
        self.onInput = onInput
        self.onSizeChange = onSizeChange
        self.onClipboardWrite = onClipboardWrite
        self.ctrlLatched = ctrlLatched
        self.clearCtrlLatch = clearCtrlLatch
    }

    public func makeCoordinator() -> Coordinator { Coordinator(self) }

    public func makeUIView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero)
        view.terminalDelegate = context.coordinator
        view.font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        applyTheme(to: view)
        handle.view = view
        return view
    }

    public func updateUIView(_ view: TerminalView, context: Context) {
        context.coordinator.parent = self
        if view.font.pointSize != fontSize {
            view.font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        }
        applyTheme(to: view)
    }

    private func applyTheme(to view: TerminalView) {
        let (bg, fg): (UIColor, UIColor)
        switch theme {
        case .dark: (bg, fg) = (.black, UIColor(white: 0.92, alpha: 1))
        case .dimmed: (bg, fg) = (UIColor(white: 0.08, alpha: 1), UIColor(white: 0.85, alpha: 1))
        case .solarizedDark: (bg, fg) = (UIColor(red: 0, green: 0.17, blue: 0.21, alpha: 1),
                                         UIColor(red: 0.51, green: 0.58, blue: 0.59, alpha: 1))
        case .highContrast: (bg, fg) = (.black, .white)
        }
        view.nativeBackgroundColor = bg
        view.nativeForegroundColor = fg
        view.backgroundColor = bg
    }

    public final class Coordinator: NSObject, TerminalViewDelegate {
        var parent: SwiftTermView
        init(_ parent: SwiftTermView) { self.parent = parent }

        // User keystrokes → pty:write, applying the Ctrl latch (SPEC §9.3).
        public func send(source: TerminalView, data: ArraySlice<UInt8>) {
            var bytes = [UInt8](data)
            if parent.ctrlLatched() {
                // Transform the first printable byte to its control code (c & 0x1f), then clear.
                if let first = bytes.first, (0x40...0x7f).contains(first) {
                    bytes[0] = first & 0x1f
                }
                parent.clearCtrlLatch()
            }
            parent.onInput(Data(bytes))
        }

        // SwiftTerm hands us already-decoded OSC 52 WRITE content; a read query is never delivered
        // here (SPEC §7.7 write-only).
        public func clipboardCopy(source: TerminalView, content: Data) {
            if let text = String(data: content, encoding: .utf8) { parent.onClipboardWrite(text) }
        }

        public func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            parent.onSizeChange(newCols, newRows)
        }

        public func setTerminalTitle(source: TerminalView, title: String) {}
        public func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        public func scrolled(source: TerminalView, position: Double) {}
        public func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
        public func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        public func bell(source: TerminalView) {}
    }
}
