import Foundation

/// Angular velocity around the device's own axes, in radians per second.
struct AirMouseAngularVelocity: Equatable {
    var x: Double
    var y: Double
    var z: Double

    init(x: Double = 0, y: Double = 0, z: Double = 0) {
        self.x = x
        self.y = y
        self.z = z
    }
}

struct AirMouseVector3: Equatable {
    var x: Double
    var y: Double
    var z: Double

    init(x: Double = 0, y: Double = 0, z: Double = 0) {
        self.x = x
        self.y = y
        self.z = z
    }
}

/// A direction inside the plane of the screen, expressed in the same frame as the
/// rotation rate. The third component is always zero for an in-plane direction.
struct AirMouseVector2: Equatable {
    var x: Double
    var y: Double

    init(x: Double = 0, y: Double = 0) {
        self.x = x
        self.y = y
    }

    var length: Double {
        (x * x + y * y).squareRoot()
    }

    var normalized: AirMouseVector2 {
        let scale = length
        guard scale > 1e-9 else { return AirMouseVector2() }
        return AirMouseVector2(x: x / scale, y: y / scale)
    }
}

/// Which way the pointer surface is held: the two directions a pointer can move
/// on it, in the device-motion frame the rotation rate arrives in. Deriving the
/// pair from gravity instead of from a reported interface orientation keeps the
/// pointer attached to the screen while the phone is tilted or rotated, and
/// needs no UIKit types.
struct AirMouseScreenAxes: Equatable {
    var right: AirMouseVector2
    var up: AirMouseVector2

    /// Portrait, phone held upright: device x is the screen's right, device y is
    /// the screen's up. Used as a fallback when gravity gives no screen plane.
    static let portrait = AirMouseScreenAxes(
        right: AirMouseVector2(x: 1, y: 0),
        up: AirMouseVector2(x: 0, y: 1)
    )
}

/// Turns gyroscope rotation rate into relative HID pointer deltas.
///
/// The pointer follows the direction the screen normal sweeps: tilting the phone
/// up moves the cursor up, and no translation of the phone in space matters.
/// Only the fused gravity vector is used to know how the screen is held, so the
/// raw accelerometer is never integrated into movement.
///
/// Kept free of CoreMotion, UIKit and HID types so the rules are testable
/// without a device, a simulator or a paired host.
final class AirMouseEngine {
    // Settings arrive from @AppStorage and are compared on every change, so the
    // interface only needs equality between the values a slider and two toggles
    // can produce.
    struct Config: Equatable {
        /// Pointer units per radian per second of steady tilt at the sensitivity
        /// the interface shows as 100 %.
        static let basePointerUnitsPerRadianPerSecond = 90.0
        /// Dead zone the interface shows as 100 %.
        static let maximumDeadZone = 0.3

        var pointerUnitsPerRadianPerSecond: Double = Config.basePointerUnitsPerRadianPerSecond
        /// Angular speed that is absorbed before anything moves.
        var deadZone: Double = 0.12
        /// Deliberate turn, in rad/s, that has to be reached before a phone that
        /// was at rest starts moving again.
        var minimumTurn: Double = 0.5
        /// Angular speed, in rad/s, that keeps an already moving pointer moving.
        /// Sitting between this and the dead zone is what makes a hand that is
        /// only shaking its tremor ignored, so the cursor never creeps.
        var reengage: Double = 0.35
        /// Share of the previous reading kept when smoothing: 0 is off,
        /// 0.9 keeps almost everything and feels heavy.
        var smoothing: Double = 0.45
        /// Extra gain while tilting fast: 0 stays linear, 1 doubles the gain at
        /// `accelerationReference`.
        var acceleration: Double = 0.4
        /// Angular speed where that extra gain reaches its maximum.
        var accelerationReference: Double = 3
        var invertX = false
        var invertY = false
        /// Largest delta a single HID mouse report may carry.
        var maximumStep: Int = 60
        /// Largest burst of reports produced for one sensor sample. Movement that
        /// does not fit is dropped rather than flooding the transport queue after
        /// a pause in the stream.
        var maximumReportsPerSample: Int = 16
        /// Movement is ignored for this long after activation or recentring, so
        /// lifting the phone into pointing position cannot throw the cursor.
        var activationHold: TimeInterval = 0.35
        /// Gravity magnitude inside the screen plane below which that plane is
        /// unknown, for example when the phone lies flat on a table.
        var minimumInPlaneGravity: Double = 0.15
    }

    /// Longest gap accepted as a real sample; a longer one resets the clock.
    static let maximumSampleInterval: TimeInterval = 0.1

    var config: Config
    var onPointerMove: (Int8, Int8) -> Void = { _, _ in }

    /// True while the post-activation hold still absorbs movement.
    private(set) var isHolding = true

    private var smoothedX = 0.0
    private var smoothedY = 0.0
    private var pendingX = 0.0
    private var pendingY = 0.0
    private var isMovingX = false
    private var isMovingY = false
    private var lastSampleAt: TimeInterval?
    private var holdUntil: TimeInterval?
    private var isRunning = false

    init(config: Config = Config()) {
        self.config = config
    }

    /// Start tracking. Also the recentre entry point: it clears the filters, so a
    /// tilt that was already in progress cannot be carried into the new position.
    func begin(now: TimeInterval) {
        smoothedX = 0
        smoothedY = 0
        pendingX = 0
        pendingY = 0
        isMovingX = false
        isMovingY = false
        lastSampleAt = nil
        let hold = max(0, config.activationHold)
        holdUntil = hold > 0 ? now + hold : nil
        isHolding = hold > 0
        isRunning = true
    }

    /// Stop tracking. Samples are ignored until the next `begin(now:)`.
    func end() {
        isRunning = false
        isHolding = true
        smoothedX = 0
        smoothedY = 0
        pendingX = 0
        pendingY = 0
        isMovingX = false
        isMovingY = false
        lastSampleAt = nil
        holdUntil = nil
    }

    func update(
        rotationRate rate: AirMouseAngularVelocity,
        axes: AirMouseScreenAxes,
        at now: TimeInterval
    ) {
        guard isRunning else { return }

        if let holdUntil, now < holdUntil {
            lastSampleAt = nil
            return
        }
        holdUntil = nil
        isHolding = false

        guard let previous = lastSampleAt else {
            lastSampleAt = now
            return
        }
        // A gap longer than a sample means the stream stopped or the app was
        // suspended; treat it as a fresh start rather than one huge step.
        let dt = now - previous
        lastSampleAt = now
        guard dt > 0 else { return }
        guard dt <= Self.maximumSampleInterval else {
            pendingX = 0
            pendingY = 0
            return
        }

        let (rawX, rawY) = Self.screenRates(of: rate, axes: axes)
        let alpha = 1 - min(max(config.smoothing, 0), 0.95)
        smoothedX += alpha * (rawX - smoothedX)
        smoothedY += alpha * (rawY - smoothedY)

        let (thresholdX, nextX) = Self.absorbed(
            smoothedX,
            wasMoving: isMovingX,
            deadZone: config.deadZone,
            minimumTurn: config.minimumTurn,
            reengage: config.reengage
        )
        let (thresholdY, nextY) = Self.absorbed(
            smoothedY,
            wasMoving: isMovingY,
            deadZone: config.deadZone,
            minimumTurn: config.minimumTurn,
            reengage: config.reengage
        )
        isMovingX = nextX
        isMovingY = nextY

        let gain = 1 + max(0, config.acceleration) * min(
            Self.speed(ofX: thresholdX, y: thresholdY) / max(config.accelerationReference, 0.01),
            1
        )

        var unitsPerSecondX = thresholdX * config.pointerUnitsPerRadianPerSecond * gain
        var unitsPerSecondY = thresholdY * config.pointerUnitsPerRadianPerSecond * gain
        if config.invertX { unitsPerSecondX = -unitsPerSecondX }
        if config.invertY { unitsPerSecondY = -unitsPerSecondY }

        pendingX += unitsPerSecondX * dt
        pendingY += unitsPerSecondY * dt

        let stepX = Int(pendingX.rounded(.towardZero))
        let stepY = Int(pendingY.rounded(.towardZero))
        pendingX -= Double(stepX)
        pendingY -= Double(stepY)
        emit(stepX: stepX, stepY: stepY)
    }

    /// Rotate the angular velocity into the two directions a pointer can travel on
    /// the screen. The pointer follows the screen normal, whose velocity is
    /// `rotationRate × normal`, and the HID y axis points downwards.
    static func screenRates(
        of rate: AirMouseAngularVelocity,
        axes: AirMouseScreenAxes
    ) -> (x: Double, y: Double) {
        let normalVelocityX = rate.y
        let normalVelocityY = -rate.x
        let alongRight = normalVelocityX * axes.right.x + normalVelocityY * axes.right.y
        let alongUp = normalVelocityX * axes.up.x + normalVelocityY * axes.up.y
        return (alongRight, -alongUp)
    }

    /// Build the screen basis from gravity. The screen's up is the component of
    /// "away from the ground" that lies in the screen plane; `right` is that
    /// direction turned a quarter turn clockwise as seen by the user.
    static func screenAxes(
        fromGravity gravity: AirMouseVector3,
        fallback: AirMouseScreenAxes,
        minimumInPlaneGravity: Double = 0.15
    ) -> AirMouseScreenAxes {
        let inPlane = AirMouseVector2(x: -gravity.x, y: -gravity.y)
        guard inPlane.length >= max(0, minimumInPlaneGravity) else { return fallback }
        let up = inPlane.normalized
        return AirMouseScreenAxes(right: AirMouseVector2(x: up.y, y: -up.x), up: up)
    }

    /// Subtract the dead zone, or hold the axis at zero.
    ///
    /// An axis at rest needs `minimumTurn` to start; an axis that is already
    /// moving only needs to stay above `reengage`. Without that second threshold a
    /// tremor larger than the dead zone would keep producing movement, and the
    /// cursor would creep while the phone is merely being held.
    private static func absorbed(
        _ value: Double,
        wasMoving: Bool,
        deadZone: Double,
        minimumTurn: Double,
        reengage: Double
    ) -> (movement: Double, isMoving: Bool) {
        let magnitude = abs(value)
        let reengageThreshold = max(reengage, deadZone)
        let turnThreshold = max(minimumTurn, reengageThreshold)
        if wasMoving {
            guard magnitude > reengageThreshold else { return (0, false) }
        } else {
            guard magnitude > turnThreshold else { return (0, false) }
        }
        let base = value > 0 ? deadZone : -deadZone
        return (value - base, true)
    }

    private static func speed(ofX x: Double, y: Double) -> Double {
        (x * x + y * y).squareRoot()
    }

    /// HID mouse deltas are signed 8-bit, so a fast swing becomes several reports.
    private func emit(stepX: Int, stepY: Int) {
        let limit = max(1, min(config.maximumStep, Int(Int8.max)))
        let maximumReports = max(1, config.maximumReportsPerSample)
        var remainingX = stepX
        var remainingY = stepY
        var reports = 0

        while (remainingX != 0 || remainingY != 0), reports < maximumReports {
            let dx = Int8(clamping: Self.chunk(remainingX, limit: limit))
            let dy = Int8(clamping: Self.chunk(remainingY, limit: limit))
            remainingX -= Int(dx)
            remainingY -= Int(dy)
            reports += 1
            onPointerMove(dx, dy)
        }
    }

    private static func chunk(_ value: Int, limit: Int) -> Int {
        value > limit ? limit : (value < -limit ? -limit : value)
    }
}

/// Splits gravity out of the raw accelerometer reading with an exponential
/// low-pass filter, so wrist movement and the slow change of how the phone is
/// held stay separate. Only this estimate is ever consulted, and only to learn
/// how the screen is held: acceleration is never integrated into movement.
struct AirMouseGravityEstimator {
    /// How quickly the estimate follows a new holding angle, in seconds.
    var timeConstant: TimeInterval = 0.5

    private(set) var value = AirMouseVector3()
    private var isStarted = false

    mutating func reset() {
        isStarted = false
        value = AirMouseVector3()
    }

    @discardableResult
    mutating func addSample(_ sample: AirMouseVector3, dt: TimeInterval) -> AirMouseVector3 {
        guard dt > 0 else { return value }
        guard isStarted else {
            value = sample
            isStarted = true
            return value
        }
        let alpha = 1 - exp(-dt / max(timeConstant, 0.01))
        value = AirMouseVector3(
            x: value.x + alpha * (sample.x - value.x),
            y: value.y + alpha * (sample.y - value.y),
            z: value.z + alpha * (sample.z - value.z)
        )
        return value
    }
}

/// How the phone is held, used as the screen plane when the accelerometer gives
/// no usable gravity direction, for example with the phone lying flat on a desk.
/// The landscape cases follow the physical device, matching
/// `UIDeviceOrientation`: the device held upright with its home button on the
/// right and on the left.
enum AirMouseHolding: String, CaseIterable, Identifiable {
    case portrait
    case portraitUpsideDown
    case landscapeLeft
    case landscapeRight

    var id: String { rawValue }

    /// Device x points to the right of the device, device y to its top edge.
    var screenAxes: AirMouseScreenAxes {
        switch self {
        case .portrait:
            return .portrait
        case .portraitUpsideDown:
            return AirMouseScreenAxes(
                right: AirMouseVector2(x: -1, y: 0),
                up: AirMouseVector2(x: 0, y: -1)
            )
        case .landscapeLeft:
            // Home button to the right: the top edge is to the left, so the
            // screen's right runs along the device's negative y and its up along
            // the device's x.
            return AirMouseScreenAxes(
                right: AirMouseVector2(x: 0, y: -1),
                up: AirMouseVector2(x: 1, y: 0)
            )
        case .landscapeRight:
            return AirMouseScreenAxes(
                right: AirMouseVector2(x: 0, y: 1),
                up: AirMouseVector2(x: -1, y: 0)
            )
        }
    }
}
