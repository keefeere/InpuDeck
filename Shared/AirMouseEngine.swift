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

/// A direction or a magnitude expressed in the device frame the rotation rate
/// arrives in, which is the only frame the sensors speak.
struct AirMouseVector3: Equatable {
    var x: Double
    var y: Double
    var z: Double

    init(x: Double = 0, y: Double = 0, z: Double = 0) {
        self.x = x
        self.y = y
        self.z = z
    }

    var length: Double {
        (x * x + y * y + z * z).squareRoot()
    }

    var normalized: AirMouseVector3 {
        let scale = length
        guard scale > 1e-9 else { return AirMouseVector3() }
        return AirMouseVector3(x: x / scale, y: y / scale, z: z / scale)
    }

    func dot(_ other: AirMouseVector3) -> Double {
        x * other.x + y * other.y + z * other.z
    }

    func cross(_ other: AirMouseVector3) -> AirMouseVector3 {
        AirMouseVector3(
            x: y * other.z - z * other.y,
            y: z * other.x - x * other.z,
            z: x * other.y - y * other.x
        )
    }

    static func - (left: AirMouseVector3, right: AirMouseVector3) -> AirMouseVector3 {
        AirMouseVector3(x: left.x - right.x, y: left.y - right.y, z: left.z - right.z)
    }

    static func + (left: AirMouseVector3, right: AirMouseVector3) -> AirMouseVector3 {
        AirMouseVector3(x: left.x + right.x, y: left.y + right.y, z: left.z + right.z)
    }

    static func * (left: AirMouseVector3, scale: Double) -> AirMouseVector3 {
        AirMouseVector3(x: left.x * scale, y: left.y * scale, z: left.z * scale)
    }

    static prefix func - (value: AirMouseVector3) -> AirMouseVector3 {
        AirMouseVector3(x: -value.x, y: -value.y, z: -value.z)
    }
}

/// The two directions the host pointer can travel in, as axes of the device
/// frame: the pointer moves along the host screen, and the host screen is fixed
/// to the world, not to the phone. Gravity gives the world's vertical, and the
/// plane of the screen gives the other: the one level direction the screen
/// contains. From those two the pair follows, with no heading — which way the
/// screen faces — needed anywhere.
///
/// `horizontalAxis` is read as "how fast is the phone turning sideways" and
/// `verticalAxis` as "how fast is it being tipped over the level line drawn
/// across it", so a deliberate wrist movement is worth the same amount of cursor
/// whatever angle the phone happens to be held at. Deriving the pair from the
/// plane of the screen alone makes that worth fall off with the hold, which is
/// what makes a phone cradled against the chest feel sluggish on one axis.
struct AirMousePointerFrame: Equatable {
    var horizontalAxis: AirMouseVector3
    var verticalAxis: AirMouseVector3

    /// The frame before gravity has been read at all: the upright seed, which is
    /// also the frame a phone held upright is answered with, so the first real
    /// sample only has to nudge it. A phone lying flat has no tip axis to be
    /// found and the adapter keeps whatever axis it last had instead.
    static let flatOnTable = AirMousePointerFrame(
        horizontalAxis: AirMouseVector3(x: 0, y: -1, z: 0),
        verticalAxis: AirMouseVector3(x: 1, y: 0, z: 0)
    )
}

/// Turns gyroscope rotation rate into relative HID pointer deltas.
///
/// The pointer follows the phone's rotation about the world's own axes: turn the
/// phone to the right and the cursor goes right, tip it up and the cursor goes
/// up, whatever way the phone is rolled or tilted in the hand. Only the fused
/// gravity vector is consulted to know which way is up and where the screen
/// faces, so the raw accelerometer is never integrated into movement and walking
/// across the room with the phone sends nothing at all.
///
/// Kept free of CoreMotion, UIKit and HID types so the rules are testable
/// without a device, a simulator or a paired host.
final class AirMouseEngine {

    // Settings arrive from @AppStorage and are compared on every change, so the
    // interface only needs equality between the values two sliders and two
    // toggles can produce.
    struct Config: Equatable {
        /// Pointer units per radian per second of steady turn at the sensitivity
        /// the interface shows as 100 %. Movement integrates rotation rate over
        /// time, so this is also the cursor travel per radian of a deliberate
        /// turn: 5400 units per radian is about 94 units per degree, so the 50 %
        /// default (2700 units per radian, about 47 per degree) crosses a 2560 px
        /// screen with a little over half a turn of the wrist.
        static let basePointerUnitsPerRadianPerSecond = 5400.0
        /// The widest dead zone the interface can ask for.
        static let maximumDeadZone = 0.3
        /// The widest acceleration bonus the interface can ask for.
        static let maximumAcceleration = 2.0
        /// The widest start threshold the interface can ask for, in rad/s.
        static let maximumStartThreshold = 0.5

        /// The two axes are separate because the gestures that drive them are not
        /// the same movement: a sideways turn comes from the wrist and the whole
        /// forearm, a tip comes from the wrist alone, and a hand does one of them
        /// far more generously than the other.
        var horizontalUnitsPerRadianPerSecond = Config.basePointerUnitsPerRadianPerSecond * 0.5
        var verticalUnitsPerRadianPerSecond = Config.basePointerUnitsPerRadianPerSecond * 0.5
        /// Rotation rate absorbed before the pointer moves at all. A held hand
        /// turned out to be quieter than a single threshold needs, so this starts
        /// at nothing and is there for a hand that says otherwise.
        var deadZone = 0.0
        /// Rotation rate a still axis has to exceed to start moving. This is the
        /// threshold that does the tremor work, and it is deliberately above the
        /// dead zone rather than merged into it. A hand leading the phone slowly
        /// sits around 0.15 rad/s, so this sits below it and lets that movement
        /// through; what stays out is the tremor of a held hand, near 0.05 rad/s.
        var minimumTurn = 0.12
        /// Rotation rate a moving axis has to stay above to keep moving.
        var reengage = 0.08
        var smoothing = 0.45
        /// Extra travel for a fast swing, on top of the axis gain. A turn at
        /// `accelerationReference` rad/s already carries the full bonus, so a
        /// deliberate flick crosses a screen instead of walking across it.
        var acceleration = 0.8
        var accelerationReference = 2.0
        /// How much of the tip measured from the gravity direction counts as
        /// movement. The gyroscope only reports the *speed* of a tip, so a slow,
        /// even tip under the start threshold travels nothing at all; the angle
        /// the screen has risen to is visible in gravity, so it carries the tip
        /// that the gyroscope cannot see. At 0 the axis is gyroscope-only.
        var gravityElevation = 1.0
        var invertX = false
        var invertY = false
        var maximumStep: Int = 60
        var maximumReportsPerSample: Int = 16
        /// Movement is ignored for this long after activation or re-anchoring, so
        /// lifting the phone into pointing position cannot throw the cursor.
        var activationHold: TimeInterval = 0.35
        /// How long the phone may sit still before the filters are quietly
        /// cleared, so the next deliberate turn starts from nothing.
        var idleReanchor: TimeInterval = 0.8
        /// How long a movement's undershoot is absorbed after it stops. Fused
        /// motion reports a movement, and when the hand stops the report tails off
        /// through zero, often past it: that negative tail is the sensor settling,
        /// not the hand going back, and integrating it walked the cursor back to
        /// where it started without the phone moving. A turn the hand is building
        /// up reports a reading that grows from sample to sample, so it is never
        /// taken for a tail; a turn that holds one steady speed arrives as soon as
        /// this window is behind it.
        var stopDamping: TimeInterval = 0.25
        /// Rotation rate an opposite-sign reading has to stay under to count as
        /// that settling tail rather than a reverse turn. A deliberate turn back
        /// is far above it and moves the pointer on the next sample.
        var undershootLimit = 0.35
        /// How much of the turn it follows an opposite-sign reading also has to
        /// stay under, so a tail left by a wide turn cannot swallow a correction
        /// that is wide compared with a small one.
        var undershootShareOfTurn = 0.35
    }

    /// Longest gap accepted as a real sample; a longer one resets the clock.
    static let maximumSampleInterval: TimeInterval = 0.1

    /// How close to lying perfectly flat still gives a tip axis. Gravity carries
    /// no word about which way the screen faces once it runs along the screen
    /// normal, and within this much of that there is no horizontal direction in
    /// the screen's plane to prefer over any other.
    static let flatAxisLimit = 0.02

    var config: Config
    var onPointerMove: (Int8, Int8) -> Void = { _, _ in }

    /// True while the post-activation hold still absorbs movement.
    private(set) var isHolding = true
    /// True once the phone has been still long enough for the filters to be
    /// cleared and nothing to be left pending. A status readout or a test can ask
    /// this instead of poking at the filters.
    private(set) var isSettled = false

    private var smoothedX = 0.0
    private var smoothedY = 0.0
    private var pendingX = 0.0
    private var pendingY = 0.0
    private var isMovingX = false
    private var isMovingY = false
    private var lastSampleAt: TimeInterval?
    private var lastMotionAt: TimeInterval?
    private var holdUntil: TimeInterval?
    private var isRunning = false

    /// The screen-facing component of gravity on the previous sample, which is
    /// what turns a tip into the angle it has reached.
    private var lastElevation: Double?
    /// The direction of each axis's last movement, so the tail a stopped
    /// movement leaves behind can be told from a hand that turns back.
    private var lastSignX = 0.0
    private var lastSignY = 0.0
    /// When each axis last moved, and how wide that turn was. The damping window
    /// belongs to the axis that moved, so a hand still travelling sideways cannot
    /// keep a vertical turn-back blocked, and the size of the turn is what says how
    /// big a settling tail that axis may be.
    private var axisMotionAtX: TimeInterval?
    private var axisMotionAtY: TimeInterval?
    private var turnPeakX = 0.0
    private var turnPeakY = 0.0
    /// The raw reading each axis reported on the previous sample. A hand builds a
    /// turn up out of nothing; a sensor settling out of a movement only shrinks.
    private var lastRawMagnitudeX = 0.0
    private var lastRawMagnitudeY = 0.0

    init(config: Config = Config()) {
        self.config = config
    }

    /// Start tracking. Also the re-anchor entry point: it clears the filters, so
    /// a turn that was already in progress cannot be carried into the new start.
    func begin(now: TimeInterval) {
        smoothedX = 0
        smoothedY = 0
        pendingX = 0
        pendingY = 0
        isMovingX = false
        isMovingY = false
        lastSampleAt = nil
        lastMotionAt = nil
        lastElevation = nil
        lastSignX = 0
        lastSignY = 0
        axisMotionAtX = nil
        axisMotionAtY = nil
        turnPeakX = 0
        turnPeakY = 0
        lastRawMagnitudeX = 0
        lastRawMagnitudeY = 0
        let hold = max(0, config.activationHold)
        holdUntil = hold > 0 ? now + hold : nil
        isHolding = hold > 0
        isSettled = false
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
        lastMotionAt = nil
        lastElevation = nil
        lastSignX = 0
        lastSignY = 0
        axisMotionAtX = nil
        axisMotionAtY = nil
        turnPeakX = 0
        turnPeakY = 0
        lastRawMagnitudeX = 0
        lastRawMagnitudeY = 0
        holdUntil = nil
    }

    func update(
        rotationRate rate: AirMouseAngularVelocity,
        frame: AirMousePointerFrame,
        at now: TimeInterval
    ) {
        guard isRunning else { return }

        if let holdUntil, now < holdUntil {
            lastSampleAt = nil
            lastElevation = nil
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
        guard dt > 0 else {
            lastElevation = nil
            return
        }
        guard dt <= Self.maximumSampleInterval else {
            pendingX = 0
            pendingY = 0
            // A pause is not a step, so the angle the tip is measured against has
            // to be the one from the resumed stream. Leaving it behind would divide
            // every degree the phone moved while suspended by one sample interval
            // and throw the cursor across the screen at the first sample back.
            lastElevation = nil
            return
        }

        let (rawX, gyroY) = Self.pointerRates(of: rate, frame: frame)
        let elevation = Self.elevationRate(
            frame: frame,
            previous: lastElevation,
            seconds: dt,
            gain: max(0, config.gravityElevation)
        )
        lastElevation = elevation.angle
        // A tip reaches both sensors: the gyroscope sees its speed, gravity sees
        // the angle it has arrived at. Whichever of the two saw more is the one
        // that steers the axis, so a fast tip is not counted twice and a slow,
        // even tip still moves the cursor.
        let rawY = abs(elevation.rate) > abs(gyroY) ? elevation.rate : gyroY
        // The slider is the share of the previous sample kept per sixtieth of a
        // second, so the same setting lags the same length of time whatever rate
        // the motion stream happens to run at.
        let retention = pow(min(max(config.smoothing, 0), 0.95), max(dt, 0) * 60)
        let alpha = 1 - retention
        smoothedX += alpha * (rawX - smoothedX)
        smoothedY += alpha * (rawY - smoothedY)

        let (thresholdX, nextX) = Self.absorbed(
            smoothedX,
            wasMoving: isMovingX,
            deadZone: config.deadZone,
            minimumTurn: config.minimumTurn,
            reengage: config.reengage,
            lastSign: lastSignX,
            secondsSinceAxisMotion: axisMotionAtX.map { now - $0 } ?? .infinity,
            turnPeak: turnPeakX,
            rawMagnitude: abs(rawX),
            previousRawMagnitude: lastRawMagnitudeX,
            stopDamping: config.stopDamping,
            undershootLimit: config.undershootLimit,
            undershootShareOfTurn: config.undershootShareOfTurn
        )
        let (thresholdY, nextY) = Self.absorbed(
            smoothedY,
            wasMoving: isMovingY,
            deadZone: config.deadZone,
            minimumTurn: config.minimumTurn,
            reengage: config.reengage,
            lastSign: lastSignY,
            secondsSinceAxisMotion: axisMotionAtY.map { now - $0 } ?? .infinity,
            turnPeak: turnPeakY,
            rawMagnitude: abs(rawY),
            previousRawMagnitude: lastRawMagnitudeY,
            stopDamping: config.stopDamping,
            undershootLimit: config.undershootLimit,
            undershootShareOfTurn: config.undershootShareOfTurn
        )
        isMovingX = nextX
        isMovingY = nextY
        lastRawMagnitudeX = abs(rawX)
        lastRawMagnitudeY = abs(rawY)
        if thresholdX != 0 {
            lastSignX = thresholdX
            axisMotionAtX = now
            turnPeakX = max(turnPeakX, abs(thresholdX))
        }
        if thresholdY != 0 {
            lastSignY = thresholdY
            axisMotionAtY = now
            turnPeakY = max(turnPeakY, abs(thresholdY))
        }

        if thresholdX == 0, thresholdY == 0 {
            reanchorIfIdle(now: now)
        } else {
            lastMotionAt = now
            isSettled = false
        }

        let gain = 1 + max(0, config.acceleration) * min(
            Self.speed(ofX: thresholdX, y: thresholdY) / max(config.accelerationReference, 0.01),
            1
        )

        var unitsPerSecondX = thresholdX * config.horizontalUnitsPerRadianPerSecond * gain
        var unitsPerSecondY = thresholdY * config.verticalUnitsPerRadianPerSecond * gain
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

    /// Clear the filters once the phone has been still for a while, so nothing is
    /// left over in them when the next deliberate turn begins. This is not
    /// forgetting a tilt — movement comes from rotation rate, so a tilt that is
    /// merely being held has never contributed anything.
    private func reanchorIfIdle(now: TimeInterval) {
        guard config.idleReanchor > 0 else { return }
        // Only a phone that moved and then came to rest has residue to clear. A
        // phone that has not moved since it started has nothing in the filters,
        // and clearing them on every resting sample also wiped the ramp a slow
        // tip builds up sample by sample, so that tip never reached the start
        // threshold and the gravity channel never moved the pointer at all.
        guard let lastMotionAt else { return }
        guard now - lastMotionAt >= config.idleReanchor else { return }
        smoothedX = 0
        smoothedY = 0
        pendingX = 0
        pendingY = 0
        isSettled = true
    }

    /// The rate a tip is moving at, in the same sign the gyroscope axis gives for
    /// it. `-horizontalAxis.z` is how much the screen faces upward, and that angle
    /// *falling* is the pointer dropping on the HID axis, which is exactly the
    /// sign `pointerRates` returns for `spin.dot(verticalAxis)`. Gravity is the
    /// one sensor that sees a tip the hand leads evenly, below the rate the
    /// gyroscope reports.
    static func elevationRate(
        frame: AirMousePointerFrame,
        previous angle: Double?,
        seconds dt: TimeInterval,
        gain: Double
    ) -> (angle: Double, rate: Double) {
        let facing = min(max(-frame.horizontalAxis.normalized.z, -1), 1)
        let current = asin(facing)
        guard let angle, dt > 0 else { return (current, 0) }
        return (current, (angle - current) / dt * gain)
    }

    /// Read the rotation rate along the two directions the pointer travels in.
    /// The HID y axis points downwards, and the vertical axis is defined so that
    /// tipping the phone over the heading upwards already comes out negative.
    static func pointerRates(
        of rate: AirMouseAngularVelocity,
        frame: AirMousePointerFrame
    ) -> (x: Double, y: Double) {
        let spin = AirMouseVector3(x: rate.x, y: rate.y, z: rate.z)
        return (spin.dot(frame.horizontalAxis), spin.dot(frame.verticalAxis))
    }

    /// Build the pointer frame from gravity. The horizontal axis is the gravity
    /// direction itself: turning the phone sideways is rotation about the
    /// world's vertical, whatever way the phone is held. The vertical axis is the
    /// one world-horizontal direction that lies in the plane of the screen,
    /// because a tip that changes the screen's elevation is a turn about exactly
    /// that.
    ///
    /// It is `(-gravity.y, gravity.x, 0)` normalised: square to gravity, so
    /// world-horizontal, and square to the screen normal, so inside the screen.
    /// It asks nothing of which way the screen faces, and that is the whole
    /// point. A heading guessed from the facing is only knowable while the screen
    /// is upright-ish, and near flat it has to be invented; an invented heading
    /// points the tip axis away from the tip, and the further the phone is rolled
    /// in the hand the more of the gesture is thrown away — `cos(roll)` of it
    /// reaches the pointer, which is nothing at all with the phone held in
    /// landscape. Measured against the true rate a screen elevation change moves
    /// the pointer at, this axis is exact at every pitch and every roll. Only
    /// gravity running exactly along the screen normal is given up, where no
    /// direction inside the screen is horizontal rather than another.
    static func pointerFrame(
        fromGravity gravity: AirMouseVector3
    ) -> AirMousePointerFrame? {
        let down = gravity.normalized
        let axis = AirMouseVector3(x: -down.y, y: down.x, z: 0)
        guard axis.length >= flatAxisLimit else { return nil }
        return AirMousePointerFrame(horizontalAxis: down, verticalAxis: axis.normalized)
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
        reengage: Double,
        lastSign: Double,
        secondsSinceAxisMotion: TimeInterval,
        turnPeak: Double,
        rawMagnitude: Double,
        previousRawMagnitude: Double,
        stopDamping: TimeInterval,
        undershootLimit: Double,
        undershootShareOfTurn: Double
    ) -> (movement: Double, isMoving: Bool) {
        let magnitude = abs(value)
        // A movement's own undershoot: opposite in sign, small next to the turn it
        // follows, and shrinking rather than building up. Fused rotation does not
        // stop dead at zero, it tails off through it and often past it, and
        // integrating that tail walked the pointer back to where it started with
        // the phone held still. A hand's turn arrives as a reading that grows out
        // of nothing, so it is not caught here; a turn that holds one steady speed
        // is taken for a tail only inside the window, and moves as soon as the
        // window is behind it.
        if stopDamping > 0, lastSign != 0, value * lastSign < 0,
            magnitude <= undershootLimit,
            magnitude <= max(0, undershootShareOfTurn) * turnPeak,
            rawMagnitude <= previousRawMagnitude * 1.05,
            secondsSinceAxisMotion < stopDamping {
            return (0, false)
        }
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
/// which way is down and where the screen faces: acceleration is never
/// integrated into movement.
struct AirMouseGravityEstimator {
    /// How quickly the estimate follows a new holding angle, in seconds.
    var timeConstant: TimeInterval = 0.5

    /// Gravity as it would be read by a device held upright at rest. Seeds the
    /// estimate so the pointer frame is sensible before the first accelerometer
    /// sample arrives.
    static let initialGravity = AirMouseVector3(x: 0, y: -1, z: 0)

    /// Seeded with `initialGravity`, written out so a default-value expression
    /// does not have to reach for a static member of its own type.
    private(set) var value = AirMouseVector3(x: 0, y: -1, z: 0)
    private var isStarted = false

    mutating func reset() {
        isStarted = false
        value = Self.initialGravity
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
