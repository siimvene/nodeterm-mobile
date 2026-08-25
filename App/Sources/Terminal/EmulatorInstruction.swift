import Foundation
import NodetermKit

// GAP NOTE (reported in the return): the task referenced an "emulator-instruction enum from
// NodetermKit's terminal controller (reset/paint/coAttachMouse/replay)". No such controller or
// enum exists in NodetermKit (Contracts.swift exposes `TerminalSessionControlling`, the co-attach
// RPC surface, but nothing that turns a `PtyCreateResult` into paint operations). This file is the
// faithful App-layer variant: a Foundation-only instruction enum plus the pure §7.2 seed-paint
// planner, so the SwiftTerm view stays a dumb executor and the load-bearing logic is testable
// without UIKit. If a Kit controller lands later, delete this and route through it.

/// One low-level operation the SwiftTerm surface performs. The emulator is a dumb executor
/// (SPEC §8.3): the VM computes the ordered instruction list, the view applies it verbatim.
public enum EmulatorInstruction: Sendable, Equatable {
    /// Clear buffer AND scrollback. Used for a `pty:resync` replacement and before a reconnect
    /// repaint (SPEC §7.8 / §4.8 step 3) — never for the live stream.
    case reset
    /// Live VT bytes fed verbatim, no EOL conversion (SPEC §8.3).
    case feedRaw(Data)
    /// Capture text (`screen` / scrollback snapshot / resync). The executor MUST strip exactly one
    /// trailing `\n` then convert `\n`→`\r\n` before feeding (SPEC §7.2 step 3 / §8.3). Carried as
    /// the RAW capture; `SeedPaint.captureToTerminalString` does the transform at apply time.
    case paintCapture(String)
    /// After a seed paint, position the cursor: `ESC[{y+1};{x+1}H` then show/hide (SPEC §7.2 step 3).
    case cursor(x: Int, y: Int, visible: Bool)
    /// Write `CO_ATTACH_MOUSE_SEQ` so wheel/touch drives tmux copy-mode history (SPEC §7.2 step 5).
    case coAttachMouse
    /// A "session restored / cold start" separator line on a `fresh:true` replay (SPEC §7.2 step 2).
    case coldStartSeparator
}

/// Pure seed-paint planning (SPEC §7.2). No UIKit/SwiftTerm — unit-testable on macOS.
public enum SeedPaint {

    /// The capture-text transform (SPEC §7.2 step 3 / §8.3): capture is LF-separated with no CR;
    /// strip exactly ONE trailing newline, then `\n`→`\r\n`. Anything else staircases the paint.
    public static func captureToTerminalString(_ capture: String) -> String {
        var t = capture
        if t.hasSuffix("\n") { t.removeLast() }
        return t.replacingOccurrences(of: "\n", with: "\r\n")
    }

    /// The `ESC[y+1;x+1H` + `ESC[?25h/l` sequence for a cursor instruction (0-based → 1-based).
    public static func cursorSequence(x: Int, y: Int, visible: Bool) -> String {
        "\u{1b}[\(y + 1);\(x + 1)H" + (visible ? "\u{1b}[?25h" : "\u{1b}[?25l")
    }

    /// Plan the seed paint for a `pty:create` result (SPEC §7.2). Caller MUST have already handled
    /// a refusal (`result.isRefusal`) and, for `fresh:true`, fetched the scrollback snapshot.
    ///
    /// - Parameter isReconnect: true when this create is the reconnect re-issue (SPEC §4.8 step 3):
    ///   the native emulator still holds pre-drop content, so we reset first and treat `screen` as
    ///   a resync capture. On a first attach this is false.
    public static func plan(result: PtyCreateResult,
                            scrollback: String?,
                            isReconnect: Bool) -> [EmulatorInstruction] {
        var out: [EmulatorInstruction] = []
        if isReconnect { out.append(.reset) }

        if result.fresh {
            // Cold start (SPEC §7.2 step 2): tmux server died. Replay the persisted snapshot; do
            // NOT auto-resume the agent CLI (owner concern).
            if let sb = scrollback, !sb.isEmpty { out.append(.paintCapture(sb)) }
            out.append(.coldStartSeparator)
        } else if let screen = result.screen, !screen.isEmpty {
            // Warm join, our grid ≥ pty grid: no redraw coming, paint `screen` first (step 3).
            out.append(.paintCapture(screen))
            if let c = result.cursor {
                out.append(.cursor(x: c.x, y: c.y, visible: c.visible))
            }
        }
        // step 4: fresh:false with `screen` absent ⇒ tmux is redrawing over the live stream ⇒
        // paint nothing (handled by the two branches above producing no paintCapture).

        // step 5: enable tmux mouse tracking AFTER the seed paint, when asked.
        if result.coAttachMouse == true { out.append(.coAttachMouse) }
        return out
    }

    /// Plan a `pty:resync:<sid>` handler (SPEC §7.8): reset + repaint, but IGNORE an empty payload
    /// (a wrongly-reset screen is unrecoverable).
    public static func planResync(_ capture: String) -> [EmulatorInstruction] {
        capture.isEmpty ? [] : [.reset, .paintCapture(capture)]
    }
}
