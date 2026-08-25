import Foundation

/// One instruction for the App-side emulator (SwiftTerm) to execute in order. The seed-paint and
/// resync decisions (SPEC §7.2 / §4.8 / §7.8) are modeled as a PURE list of these so the App layer
/// only executes; all policy lives here and is unit-tested.
public enum EmulatorInstruction: Sendable, Equatable {
    /// Clear buffer + scrollback before painting. Emitted on a reconnect re-attach and on resync,
    /// where the emulator still holds pre-drop content that `screen` would otherwise stack under
    /// (SPEC §4.8 / §7.8).
    case reset
    /// Write this text verbatim into the emulator. Already LF→CRLF transformed (SPEC §7.2 step 3):
    /// exactly one trailing newline stripped, every remaining `\n` rewritten to `\r\n`.
    case paint(screen: String)
    /// Position the cursor. 1-based ANSI coordinates (already `y+1` / `x+1`), so the App emits
    /// `ESC [ row ; col H` (SPEC §7.2 step 3).
    case moveCursor(row: Int, col: Int)
    /// `ESC [ ?25h` (true) / `ESC [ ?25l` (false) after the cursor move (SPEC §7.2 step 3).
    case setCursorVisible(Bool)
    /// Write `CO_ATTACH_MOUSE_SEQ` AFTER the seed paint so wheel/touch drives tmux copy-mode
    /// history. Idempotent (SPEC §7.2 step 5).
    case writeCoAttachMouse(seq: String)
    /// Cold start (SPEC §7.2 step 2): the App must `pty:read-scrollback`, run it through the same
    /// LF→CRLF transform, write it, THEN show the cold-start separator. It MUST NOT auto-resume the
    /// agent CLI — resume is an owner/canvas concern (SPEC §7.2).
    case replayScrollback
    /// Show the "session restored / cold start" separator after a scrollback replay (SPEC §7.2).
    case coldStartSeparator
    /// The node was permanently destroyed elsewhere or refused as closed; show "closed", do not
    /// respawn (SPEC §7.2 step 1). `by` is the destroying client id, or nil = unknown.
    case showClosed(by: Int?)
    /// The session cannot run here (`'ssh'` / `'codex-account'`); show "not available", wait
    /// (SPEC §7.2 step 1 / §11.5).
    case showUnavailable(reason: String)
}

/// Pure seed-paint / resync planners (SPEC §7.2, §4.8, §7.8). No I/O; the App executes the plan.
public enum TerminalSeedPaint {

    /// LF→CRLF transform for `capture-pane` output (SPEC §7.2 step 3). Strips EXACTLY ONE trailing
    /// newline (else the top row doubles / the paint staircases), then rewrites every `\n` → `\r\n`.
    /// The emulator MUST be in a no-EOL-conversion mode; this client owns the conversion.
    public static func lfToCRLF(_ screen: String) -> String {
        var text = screen
        // Strip exactly one trailing LF (capture-pane is LF-separated, no CR — SPEC §7.2).
        if text.hasSuffix("\n") { text.removeLast() }
        return text.replacingOccurrences(of: "\n", with: "\r\n")
    }

    /// Decide the ordered emulator instructions for a `pty:create` result (SPEC §7.2). Set
    /// `isReattach` for the reconnect re-issue path (SPEC §4.8): the native emulator still holds the
    /// pre-drop content, so `screen` is treated as a RESYNC (reset-then-paint), never an append.
    public static func plan(for result: PtyCreateResult, isReattach: Bool = false) -> [EmulatorInstruction] {
        // SPEC §7.2 step 1: refusals short-circuit — never respawn, never paint.
        if let closed = result.closed { return [.showClosed(by: closed.by)] }
        if let unavailable = result.unavailable { return [.showUnavailable(reason: unavailable)] }

        var plan: [EmulatorInstruction] = []

        if result.fresh {
            // SPEC §7.2 step 2: cold start (tmux server died / phone-first open). Replay the
            // persisted scrollback + separator. Explicitly NO agent auto-resume (owner concern).
            plan.append(.replayScrollback)
            plan.append(.coldStartSeparator)
        } else {
            // SPEC §4.8: on a reconnect re-attach the emulator holds stale content — clear it FIRST
            // so a present `screen` replaces rather than stacks (the §7.8 corruption).
            if isReattach {
                plan.append(.reset)
            }
            if let screen = result.screen {
                // SPEC §7.2 step 3: grid ≥ pty grid, no redraw is coming — paint `screen` first.
                plan.append(.paint(screen: lfToCRLF(screen)))
                if let cursor = result.cursor {
                    // 0-based → 1-based ANSI (SPEC §7.2 step 3).
                    plan.append(.moveCursor(row: cursor.y + 1, col: cursor.x + 1))
                    plan.append(.setCursorVisible(cursor.visible))
                }
            }
            // SPEC §7.2 step 4: `screen` absent on a warm join ⇒ the pty resized down to us and tmux
            // is redrawing over the live stream — paint nothing (the reset above, if any, is safe
            // because that redraw is guaranteed by our resize).
        }

        // SPEC §7.2 step 5: enable tmux mouse tracking AFTER the seed paint, when requested.
        if result.coAttachMouse == true {
            plan.append(.writeCoAttachMouse(seq: NodetermWire.coAttachMouseSeq))
        }

        return plan
    }

    /// The `pty:resync:<sid>` recipe (SPEC §7.8): reset the emulator and write the capture — it
    /// REPLACES the buffer, never stacks. An EMPTY payload is ignored (a wrongly-reset screen is
    /// unrecoverable). Returns `[]` for the ignore case.
    public static func resyncPlan(screen: String) -> [EmulatorInstruction] {
        guard !screen.isEmpty else { return [] } // SPEC §7.8: ignore an empty payload.
        return [.reset, .paint(screen: lfToCRLF(screen))]
    }
}
