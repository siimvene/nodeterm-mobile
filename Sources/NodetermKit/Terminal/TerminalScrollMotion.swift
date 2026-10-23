import Foundation

/// Touch distance and momentum in points; wheel events are emitted in bounded display-frame
/// batches. This retains excess distance instead of dropping it on a fast swipe.
public struct TerminalScrollMotion: Sendable {
    private var distance = 0.0
    private var velocity = 0.0
    private static let decay = 10.0
    private static let stopVelocity = 25.0

    public init() {}

    public mutating func begin() { distance = 0; velocity = 0 }
    public mutating func drag(points: Double) {
        guard points.isFinite else { return }
        distance += points
    }
    public mutating func end(velocity: Double) {
        guard velocity.isFinite else { self.velocity = 0; return }
        self.velocity = min(4000, max(-4000, velocity))
        if abs(self.velocity) < Self.stopVelocity { self.velocity = 0 }
    }
    public mutating func cancel() { begin() }

    public func needsFrame(lineHeight: Double) -> Bool {
        velocity != 0 || abs(distance) >= max(1, lineHeight)
    }

    public mutating func advance(seconds: Double, lineHeight: Double) -> Int {
        guard seconds.isFinite, lineHeight.isFinite, lineHeight > 0 else { return 0 }
        // A delayed frame (or app suspension) must not turn into a giant scroll jump.
        let dt = min(0.05, max(0, seconds))
        if velocity != 0 {
            let factor = exp(-Self.decay * dt)
            distance += velocity * (1 - factor) / Self.decay
            velocity *= factor
            if abs(velocity) < Self.stopVelocity { velocity = 0 }
        }
        let lines = min(8, max(-8, distance / lineHeight))
        let emitted = Int(lines)
        distance -= Double(emitted) * lineHeight
        return emitted
    }
}
