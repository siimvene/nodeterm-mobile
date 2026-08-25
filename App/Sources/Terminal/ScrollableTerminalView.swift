import UIKit
import SwiftTerm

/// SwiftTerm's iOS `TerminalView` has NO scroll path: its pan handler reports mouse *drags*
/// (press→motion→release), which tmux interprets as a copy-mode SELECTION — so a swipe never
/// scrolls history (the Mac view's `scrollWheel` override has no iOS equivalent in 1.15.0).
///
/// This subclass adds the missing half: a single-finger, predominantly-VERTICAL pan is turned
/// into wheel events (button 4/5), mirroring `MacTerminalView.scrollWheel` line-for-line:
///   - mouse reporting on (tmux always: `mouse on`) → encodeButton(4|5) + sendEvent per line,
///     which tmux turns into copy-mode history scrolling;
///   - mouse off (plain-shell fallback) → the emulator's own scrollUp/scrollDown.
/// Horizontal/diagonal drags are left to SwiftTerm's own gestures (selection, drag reporting),
/// which are told to wait for this recognizer to fail.
final class ScrollableTerminalView: TerminalView {

    private var scrollAccumulator: CGFloat = 0
    private weak var scrollGesture: UIPanGestureRecognizer?

    required init?(coder: NSCoder) { super.init(coder: coder) }

    override init(frame: CGRect) {
        super.init(frame: frame)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(scrollPan(_:)))
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)
        scrollGesture = pan
        // SwiftTerm's own pans (drag-report + selection) yield to a vertical scroll.
        for g in gestureRecognizers ?? [] where g is UIPanGestureRecognizer && g !== pan {
            g.require(toFail: pan)
        }
    }

    /// Governs EVERY recognizer on this view — scope the vertical-intent test strictly to OUR
    /// pan and defer everything else to the base class, or SwiftTerm's own drags break.
    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        guard g === scrollGesture, let pan = g as? UIPanGestureRecognizer else {
            return super.gestureRecognizerShouldBegin(g)
        }
        let v = pan.velocity(in: self)
        return abs(v.y) > abs(v.x) * 1.5   // vertical intent only; sideways drags stay SwiftTerm's
    }

    private var lineHeight: CGFloat {
        let t = getTerminal()
        let rows = max(t.rows, 1)
        let h = bounds.height / CGFloat(rows)
        return h > 0 ? h : 17
    }

    @objc private func scrollPan(_ pan: UIPanGestureRecognizer) {
        switch pan.state {
        case .began:
            scrollAccumulator = 0
        case .changed:
            let dy = pan.translation(in: self).y
            pan.setTranslation(.zero, in: self)
            scrollAccumulator += dy
            let lines = Int(scrollAccumulator / lineHeight)
            guard lines != 0 else { return }
            scrollAccumulator -= CGFloat(lines) * lineHeight
            deliver(lines: lines, at: pan.location(in: self))
        default:
            break
        }
    }

    /// Finger moves DOWN (+lines) = reveal history above = wheel UP (button 4) — the natural
    /// touch direction, same as every phone scroll surface.
    private func deliver(lines: Int, at point: CGPoint) {
        let t = getTerminal()
        let up = lines > 0
        let magnitude = min(abs(lines), 40)
        if t.mouseMode != .off {
            let button = up ? 4 : 5
            let flags = t.encodeButton(button: button, release: false,
                                       shift: false, meta: false, control: false)
            let col = max(0, min(t.cols - 1, Int(point.x / max(bounds.width / CGFloat(max(t.cols, 1)), 1))))
            let row = max(0, min(t.rows - 1, Int(point.y / lineHeight)))
            for _ in 0..<magnitude {
                t.sendEvent(buttonFlags: flags, x: col, y: row)
            }
        } else {
            if up { scrollUp(lines: magnitude) } else { scrollDown(lines: magnitude) }
        }
    }
}
