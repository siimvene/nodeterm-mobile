import UIKit
import SwiftTerm
import NodetermKit

/// SwiftTerm already has native UIScrollView history scrolling. Leave that path intact when
/// mouse reporting is off. For tmux mouse mode, its pan reports selection drags rather than wheel
/// events, so provide wheel scrolling with bounded frame batches and momentum. Selection and
/// nonvertical gestures still belong to SwiftTerm.
final class ScrollableTerminalView: TerminalView {

    /// Group SwiftTerm's synchronous mouse-event callbacks into one ordered pty:write.
    var batchInput: ((() -> Void) -> Void)?
    private var motion = TerminalScrollMotion()
    private var displayLink: CADisplayLink?
    private var scrollPoint = CGPoint.zero
    private weak var scrollGesture: UIPanGestureRecognizer?

    // CADisplayLink retains its target. A weak proxy avoids retaining a dismissed terminal.
    @MainActor private final class DisplayTarget: NSObject {
        weak var owner: ScrollableTerminalView?
        init(_ owner: ScrollableTerminalView) { self.owner = owner }
        @objc func tick(_ link: CADisplayLink) {
            guard let owner else { link.invalidate(); return }
            owner.scrollFrame(link)
        }
    }

    required init?(coder: NSCoder) { super.init(coder: coder) }

    override init(frame: CGRect) {
        super.init(frame: frame)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(scrollPan(_:)))
        pan.maximumNumberOfTouches = 1
        scrollGesture = pan
        addGestureRecognizer(pan)
        for other in gestureRecognizers ?? [] where other is UIPanGestureRecognizer && other !== pan {
            other.require(toFail: pan)
        }
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
        guard allowMouseReporting, getTerminal().mouseMode != .off else { return false }
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
            motion.begin()
            collectDrag(pan)
        case .changed:
            collectDrag(pan)
        case .ended:
            collectDrag(pan)
            motion.end(velocity: Double(pan.velocity(in: self).y))
            scheduleScroll()
        case .cancelled, .failed:
            cancelScrolling()
        default:
            break
        }
    }

    private func collectDrag(_ pan: UIPanGestureRecognizer) {
        motion.drag(points: Double(pan.translation(in: self).y))
        pan.setTranslation(.zero, in: self)
        scrollPoint = pan.location(in: self)
        scheduleScroll()
    }

    private func scheduleScroll() {
        if displayLink == nil {
            let target = DisplayTarget(self)
            let link = CADisplayLink(target: target, selector: #selector(DisplayTarget.tick(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
        displayLink?.isPaused = false
    }

    private func scrollFrame(_ link: CADisplayLink) {
        guard window != nil, !selectionActive, allowMouseReporting,
              getTerminal().mouseMode != .off else { cancelScrolling(); return }
        let lines = motion.advance(seconds: link.targetTimestamp - link.timestamp,
                                   lineHeight: Double(lineHeight))
        if lines != 0 { deliver(lines: lines, at: scrollPoint) }
        link.isPaused = !motion.needsFrame(lineHeight: Double(lineHeight))
    }

    func cancelScrolling() {
        motion.cancel()
        displayLink?.invalidate()
        displayLink = nil
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { cancelScrolling() }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        cancelScrolling()
        super.touchesBegan(touches, with: event)
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
            let send = {
                for _ in 0..<magnitude { t.sendEvent(buttonFlags: flags, x: col, y: row) }
            }
            if let batchInput { batchInput(send) } else { send() }
        } else {
            if up { scrollUp(lines: magnitude) } else { scrollDown(lines: magnitude) }
        }
    }
}
