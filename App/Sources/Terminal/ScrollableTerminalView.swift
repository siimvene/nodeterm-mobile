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
        scrollGesture = pan
        addGestureRecognizer(pan)
    }

    /// SwiftTerm attaches its drag pans LAZILY — `panMouseGesture` only appears when the app
    /// turns mouse mode on, long after init — so a one-time require(toFail:) sweep at init sees
    /// an empty list and the drag recognizer then outcompetes the scroll. Route EVERY future
    /// pan through the subordination instead: any pan that is not ours yields to the scroll
    /// (which fails fast for non-vertical drags and while a selection is active, so selection
    /// drags still win exactly where they should).
    override func addGestureRecognizer(_ g: UIGestureRecognizer) {
        super.addGestureRecognizer(g)
        if let mine = scrollGesture, g is UIPanGestureRecognizer, g !== mine {
            g.require(toFail: mine)
        }
    }

    /// Governs EVERY recognizer on this view — scope the vertical-intent test strictly to OUR
    /// pan and defer everything else to the base class, or SwiftTerm's own drags break.
    ///
    /// Split rule: an ACTIVE selection always wins (a vertical drag then extends it — scroll
    /// resumes when it is dismissed); otherwise any predominantly-vertical drag scrolls. Both
    /// velocity and accumulated translation vote, because a thumb drag often starts slow and
    /// slightly diagonal — the launch velocity alone misclassified those as selection drags.
    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        guard g === scrollGesture, let pan = g as? UIPanGestureRecognizer else {
            return super.gestureRecognizerShouldBegin(g)
        }
        if selectionActive { return false }
        let v = pan.velocity(in: self)
        let t = pan.translation(in: self)
        return abs(v.y) > abs(v.x) || abs(t.y) > abs(t.x)
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
