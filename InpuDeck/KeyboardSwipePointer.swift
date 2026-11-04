import CoreGraphics
import Foundation

/// Gesture rules that turn a drag starting on an ordinary keyboard key into
/// relative pointer movement, while taps and stationary holds stay key presses.
///
/// The rules are deliberately free of UIKit and HID types: the key button feeds
/// touch locations in and the keyboard view receives HID deltas. That keeps the
/// threshold logic testable without a simulator or a paired host.
final class KeyboardSwipePointer {
    struct Config {
        /// Screen distance a touch must travel before it becomes a pointer drag.
        var activationDistance: CGFloat = 24
        /// Movement still considered a press. Used to postpone the HID key-down
        /// so a swipe that starts immediately never types a character.
        var tapTolerance: CGFloat = 12
        /// How long to wait before committing a key-down for a stationary touch.
        var pressGrace: TimeInterval = 0.05
        /// Screen points per HID step, matching the trackpad surface.
        var movementSensitivity: CGFloat = 1.5
        /// Largest delta one HID mouse report can carry.
        var maximumStep: Int = 127
    }

    private struct Touch {
        let origin: CGPoint
        var last: CGPoint
        var emitted: CGPoint
        var isSwipe = false
    }

    private let config: Config
    private var touches: [AnyHashable: Touch] = [:]
    private var activeSwipes = 0

    var onPointerMove: (Int8, Int8) -> Void = { _, _ in }

    init(config: Config = Config()) {
        self.config = config
    }

    var tapTolerance: CGFloat { config.tapTolerance }
    var pressGrace: TimeInterval { config.pressGrace }
    var isPointerActive: Bool { activeSwipes > 0 }

    func begin(_ token: AnyHashable, at point: CGPoint) {
        touches[token] = Touch(origin: point, last: point, emitted: point)
    }

    /// Reports one touch position. Returns true once that touch is a pointer
    /// swipe; the emitted pointer deltas are delivered through `onPointerMove`.
    func dragged(_ token: AnyHashable, to point: CGPoint) -> Bool {
        guard var touch = touches[token] else { return false }

        if !touch.isSwipe {
            let travelled = hypot(point.x - touch.origin.x, point.y - touch.origin.y)
            guard travelled >= config.activationDistance else {
                touch.last = point
                touches[token] = touch
                return false
            }
            touch.isSwipe = true
            activeSwipes += 1
        }

        emitSteps(from: &touch, to: point)
        touches[token] = touch
        return true
    }

    /// True when the touch has moved far enough that a key press is no longer
    /// the right interpretation. The button uses this to postpone key-down.
    func looksLikeDrag(_ token: AnyHashable) -> Bool {
        guard let touch = touches[token] else { return false }
        return hypot(touch.last.x - touch.origin.x, touch.last.y - touch.origin.y) > config.tapTolerance
    }

    /// Ends one touch and reports whether it was a pointer swipe.
    func end(_ token: AnyHashable) -> Bool {
        guard let touch = touches.removeValue(forKey: token) else { return false }
        if touch.isSwipe {
            activeSwipes = max(0, activeSwipes - 1)
        }
        return touch.isSwipe
    }

    /// Called when the keyboard route changes or the page disappears.
    func reset() {
        touches.removeAll()
        activeSwipes = 0
    }

    private func emitSteps(from touch: inout Touch, to point: CGPoint) {
        var remainingX = Int(((point.x - touch.emitted.x) * config.movementSensitivity).rounded())
        var remainingY = Int(((point.y - touch.emitted.y) * config.movementSensitivity).rounded())

        while remainingX != 0 || remainingY != 0 {
            let stepX = clamp(remainingX, limit: config.maximumStep)
            let stepY = clamp(remainingY, limit: config.maximumStep)
            remainingX -= stepX
            remainingY -= stepY
            onPointerMove(Int8(clamping: stepX), Int8(clamping: stepY))
        }

        touch.emitted = point
    }

    private func clamp(_ value: Int, limit: Int) -> Int {
        if limit <= 0 { return 0 }
        return min(max(value, -limit), limit)
    }
}
