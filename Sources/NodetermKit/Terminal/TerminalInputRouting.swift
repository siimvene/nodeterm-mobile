import Foundation

/// A user input event, source-tagged, so routing can pick the right delivery path (SPEC §7.6).
public enum TerminalInput: Sendable, Equatable {
    /// Live keystroke(s) from the soft/hardware keyboard — raw bytes to the pty.
    case keystroke(String)
    /// The Shift+Enter chord — a newline the agent CLI must NOT read as a submit.
    case shiftEnter
    /// A paste / composed multi-line block — framed delivery, never auto-submitted.
    case paste(String)
    /// Dictation "Send" — framed delivery WITH a trailing submit.
    case dictationSend(String)
    /// Dictation "Insert" — framed delivery WITHOUT a submit.
    case dictationInsert(String)
    /// "Submit whatever is composed" — a lone Enter (empty framed text with submit).
    case submitComposed
}

/// The concrete wire path an input maps to (SPEC §7.6).
public enum InputDelivery: Sendable, Equatable {
    /// `pty:write(sessionId, data)` CAST — raw bytes, NO framing. A multi-line blob would become
    /// one submit per `\n`, so this path is only used for a single line / a control chord.
    case write(data: String)
    /// `pty:send-text(persistKey, text, enter)` REQ — tmux `load-buffer` + `paste-buffer -p -r`,
    /// bracketed-paste-safe, multi-line-safe. `enter` appends a submit in the same invocation.
    case sendText(text: String, enter: Bool)
}

/// Pure input routing (SPEC §7.6). Decides `pty:write` vs `pty:send-text` and the `enter` flag.
public enum TerminalInputRouting {

    /// Map a source-tagged input to its delivery path (SPEC §7.6).
    public static func delivery(for input: TerminalInput) -> InputDelivery {
        switch input {
        case .keystroke(let text):
            // SPEC §7.6: a raw multi-line blob on `pty:write` becomes one submit per `\n`, so any
            // text carrying a newline is force-routed to the framed path even from the "typing"
            // source (defensive — normal keystrokes are single characters).
            if text.contains("\n") {
                return .sendText(text: text, enter: false)
            }
            return .write(data: text)
        case .shiftEnter:
            // SPEC §7.6: ESC+CR so agent CLIs insert a newline instead of submitting.
            return .write(data: NodetermWire.shiftEnterSeq)
        case .paste(let text):
            // SPEC §7.6: multi-line paste MUST use send-text; never auto-submit a paste.
            return .sendText(text: text, enter: false)
        case .dictationSend(let text):
            // SPEC §7.6 / §9.5: Send = framed with a trailing submit.
            return .sendText(text: text, enter: true)
        case .dictationInsert(let text):
            // SPEC §7.6 / §9.5: Insert = framed without submitting.
            return .sendText(text: text, enter: false)
        case .submitComposed:
            // SPEC §7.6: send-text('', enter:true) = submit the composed line (a lone Enter).
            return .sendText(text: "", enter: true)
        }
    }

    /// True when text MUST NOT be delivered over a raw `pty:write` (SPEC §7.6): it spans lines, so a
    /// raw write would submit each line. The App uses this as a guard before ever choosing `write`.
    public static func requiresFramedDelivery(_ text: String) -> Bool {
        text.contains("\n")
    }
}
