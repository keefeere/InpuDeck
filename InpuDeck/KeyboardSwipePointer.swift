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
        /// Movement below which a touch still counts as a press. Past it the touch
        /// is latched, so it can only become a tap on lift or a pointer swipe.
        var tapTolerance: CGFloat = 12
        /// How long a touch must stay still before a held key-down is committed.
        /// A moving touch keeps postponing it, so a drag that begins shortly after
        /// touch-down never reaches the host as a keystroke.
        var holdCommitDelay: TimeInterval = 0.35
        /// Screen points per HID step, matching the trackpad surface.
        var movementSensitivity: CGFloat = 1.5
        /// Largest delta one HID mouse report can carry.
        var maximumStep: Int = 127
    }

    private struct Touch {
        let origin: CGPoint
        var emitted: CGPoint
        var isSwipe = false
        /// Set once the finger has travelled past the tap tolerance. Such a touch
        /// is on its way somewhere, so it must not become a held key press.
        var drifted = false
    }

    private let config: Config
    private var touches: [AnyHashable: Touch] = [:]
    private var activeSwipes = 0

    var onPointerMove: (Int8, Int8) -> Void = { _, _ in }

    init(config: Config = Config()) {
        self.config = config
    }

    var holdCommitDelay: TimeInterval { config.holdCommitDelay }
    var tapTolerance: CGFloat { config.tapTolerance }
    var isPointerActive: Bool { activeSwipes > 0 }

    func begin(_ token: AnyHashable, at point: CGPoint) {
        touches[token] = Touch(origin: point, emitted: point)
    }

    /// Reports one touch position. Returns true once that touch is a pointer
    /// swipe; the emitted pointer deltas are delivered through `onPointerMove`.
    func dragged(_ token: AnyHashable, to point: CGPoint) -> Bool {
        guard var touch = touches[token] else { return false }

        if !touch.isSwipe {
            let travelled = hypot(point.x - touch.origin.x, point.y - touch.origin.y)
            touch.drifted = touch.drifted || travelled > config.tapTolerance
            guard travelled >= config.activationDistance else {
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

    /// True while committing a held key-down for this touch is still legitimate.
    /// A touch that has already travelled past the tap tolerance is latched: the
    /// button then sends the key as a tap on lift (or nothing at all, if it turns
    /// into a swipe) instead of typing a keystroke the host cannot take back.
    func canCommitPress(_ token: AnyHashable) -> Bool {
        guard let touch = touches[token] else { return false }
        return !touch.drifted && !touch.isSwipe
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
