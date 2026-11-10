import Foundation

/// One sample step at the rate the phone streams at.
private let step = 1.0 / 60.0
/// The first sample time after `begin(now: 0)`, past the default activation hold.
private let live = 0.36
/// A phone held upright and tilted back 17 degrees, in the device frame.
private let tiltAngle = 17 * Double.pi / 180
private let uprightGravity = AirMouseVector3(
    y: -cos(tiltAngle),
    z: -sin(tiltAngle)
)
private let deviceUp = AirMouseVector3(y: 1)
private let deviceRight = AirMouseVector3(x: 1)

@main
struct AirMouseEngineTests {
    static func main() {
        pointerFrameFollowsTheWorld()
        turningSidewaysIsPureHorizontalAtEveryRoll()
        tippingOverTheHeadingLiftsThePointer()
        flatPhonePointsWhereTheScreenFacesDownhill()
        tipAxisStaysAcrossTheFlatThreshold()
        restAbsorbsTremorAndHoldsStillness()
        axesHaveSeparateSensitivity()
        defaultsMatchTheVirtualHalfGain()
        documentedHalfGainWalksTheScreen()
        evenTipMovesThePointerThroughGravity()
        gravityTipCarriesTheGyroSign()
        movementSurvivesTheFractionalRemainder()
        aDemandLargerThanOneReportIsSplit()
        smoothingDampsTheFirstStepAndConverges()
        fastTurnsGetExtraGain()
        inversionMirrorsBothAxes()
        stillPhoneReanchorsItsFilters()
        activationHoldAndRecentreControlTracking()
        gravityEstimateIgnoresBumpsAndTracksTurns()

        print("PASS: air mouse maps world-relative rotation to HID deltas without creep")
    }

    // MARK: - The pointer frame

    private static func pointerFrameFollowsTheWorld() {
        let frame = AirMouseEngine.pointerFrame(fromGravity: uprightGravity)

        // Horizontal pointer motion is rotation about the world's vertical, which
        // is the gravity direction itself: no screen plane, no device axis.
        expect(near(frame.horizontalAxis.y, -cos(tiltAngle), 1e-9)
                && near(frame.horizontalAxis.z, -sin(tiltAngle), 1e-9)
                && near(frame.horizontalAxis.x, 0),
               "the horizontal axis is the world's vertical")
        // Tipping over the heading is rotation about a world-horizontal axis, and
        // for this hold it is the device's own x.
        expect(near(frame.verticalAxis.x, 1, 1e-9)
                && near(frame.verticalAxis.y, 0) && near(frame.verticalAxis.z, 0),
               "the vertical axis is the world-horizontal axis across the heading")
        expect(near(frame.horizontalAxis.length, 1) && near(frame.verticalAxis.length, 1),
               "both axes stay unit")
        expect(near(frame.horizontalAxis.dot(frame.verticalAxis), 0, 1e-9),
               "and they stay square")
    }

    private static func turningSidewaysIsPureHorizontalAtEveryRoll() {
        // One wrist turn about the world's vertical, worth the same cursor travel
        // however the phone is rolled in the hand. Rolling about the screen normal
        // is the only thing that changes between the poses, so it must not change
        // the answer — this is the claim that a phone cradled at an angle still
        // moves sideways at a normal speed.
        for degrees in stride(from: 0.0, through: 330.0, by: 30.0) {
            let roll = degrees * Double.pi / 180
            let gravity = AirMouseVector3(
                x: cos(tiltAngle) * sin(roll),
                y: -cos(tiltAngle) * cos(roll),
                z: -sin(tiltAngle)
            )
            let frame = AirMouseEngine.pointerFrame(fromGravity: gravity)
            let rates = AirMouseEngine.pointerRates(of: AirMouseAngularVelocity(
                x: frame.horizontalAxis.x,
                y: frame.horizontalAxis.y,
                z: frame.horizontalAxis.z
            ), frame: frame)
            expect(near(rates.x, 1, 1e-9) && near(rates.y, 0, 1e-9),
                   "a sideways turn at \(Int(degrees))° of roll is full-speed horizontal")
        }
    }

    private static func tippingOverTheHeadingLiftsThePointer() {
        let frame = AirMouseEngine.pointerFrame(fromGravity: uprightGravity)
        // The HID y axis grows downwards, so a tip that raises the pointer must
        // come out negative.
        let up = AirMouseEngine.pointerRates(of: spin(-frame.verticalAxis), frame: frame)
        expect(near(up.x, 0, 1e-9) && near(up.y, -1, 1e-9),
               "tipping the phone over its heading lifts the pointer")

        let down = AirMouseEngine.pointerRates(of: spin(frame.verticalAxis), frame: frame)
        expect(near(down.x, 0, 1e-9) && near(down.y, 1, 1e-9),
               "and tipping it the other way drops it")

        // Rolling the phone in its own plane must not bleed the tip into sideways
        // travel.
        for degrees in stride(from: 0.0, through: 330.0, by: 30.0) {
            let roll = degrees * Double.pi / 180
            let gravity = AirMouseVector3(
                x: cos(tiltAngle) * sin(roll),
                y: -cos(tiltAngle) * cos(roll),
                z: -sin(tiltAngle)
            )
            let rolled = AirMouseEngine.pointerFrame(fromGravity: gravity)
            let rates = AirMouseEngine.pointerRates(of: spin(-rolled.verticalAxis), frame: rolled)
            expect(near(rates.y, -1, 1e-9) && near(rates.x, 0, 1e-9),
                   "a tip at \(Int(degrees))° of roll stays a tip")
        }
    }

    private static func flatPhonePointsWhereTheScreenFacesDownhill() {
        // Screen up on a table: the screen faces the sky, so the direction it
        // faces is the ground side of the screen, the bottom edge. The tip axis
        // is then the axis across that, which is the screen's own right edge.
        let frame = AirMouseEngine.pointerFrame(fromGravity: AirMouseVector3(z: -1))
        expect(near(frame.horizontalAxis.z, -1) && near(frame.horizontalAxis.y, 0),
               "the horizontal axis is still the world's vertical")
        expect(near(frame.verticalAxis.x, 1) && near(frame.verticalAxis.dot(deviceUp), 0, 1e-9),
               "the vertical axis tips over the downhill side, not over the top edge")
        expect(near(frame.verticalAxis.length, 1) && near(frame.horizontalAxis.length, 1),
               "the fallback frame stays a unit basis")
    }

    private static func tipAxisStaysAcrossTheFlatThreshold() {
        // A phone lying almost flat: the screen normal is almost the world's
        // vertical, so which way it faces is mathematically defined and
        // practically noise, and the frame gives the heading up there. What
        // matters is that giving it up does not move the tip axis: when the
        // heading came from the top edge, the axis jumped 180 degrees at the
        // threshold and the same gesture started arriving as its own opposite.
        var axis: AirMouseVector3? = nil
        for degrees in stride(from: 0.0, through: 40.0, by: 1.0) {
            let flatness = degrees * Double.pi / 180
            let gravity = AirMouseVector3(y: -sin(flatness), z: -cos(flatness))
            let frame = AirMouseEngine.pointerFrame(fromGravity: gravity)
            if let axis, (frame.verticalAxis - axis).length > 0.02 {
                preconditionFailure(
                    "air mouse engine test failed: the tip axis jumps at \(Int(degrees))\u{00B0} of flatness"
                )
            }
            axis = frame.verticalAxis
        }
        // Trusting the heading right through the flat range lands on the same
        // axis, which is the claim the guard exists to keep.
        let flatness = 10 * Double.pi / 180
        let gravity = AirMouseVector3(y: -sin(flatness), z: -cos(flatness))
        let guarded = AirMouseEngine.pointerFrame(fromGravity: gravity)
        let trusting = AirMouseEngine.pointerFrame(fromGravity: gravity, minimumHorizontalNormal: 0.05)
        expect((guarded.verticalAxis - trusting.verticalAxis).length < 0.02,
               "and the guarded answer is the steady answer, not a flipped one")
    }

    // MARK: - Rate to deltas

    private static func restAbsorbsTremorAndHoldsStillness() {
        // The default dead zone is nothing, because a held hand turned out to be
        // quieter than any dead zone needed; the work is done by the threshold an
        // axis at rest has to exceed.
        let sink = Sink { config in
            expect(near(config.deadZone, 0), "the shipped default absorbs nothing by itself")
        }
        sink.begin()
        for rate in [0.02, 0.06, 0.11] {
            sink.feedVertical(rate, samples: 40)
        }
        expect(sink.reports.isEmpty, "tremor below the start threshold never reaches the host")

        // Above it the axis starts, and once started it keeps moving well below the
        // start threshold — that is what keeps a slow deliberate turn slow instead
        // of chopped into start/stop steps.
        sink.clear()
        sink.feedVertical(0.6, samples: 10)
        expect(!sink.reports.isEmpty, "a deliberate turn starts")
        sink.clear()
        sink.feedVertical(0.25, samples: 40)
        expect(!sink.reports.isEmpty, "a moving axis keeps moving below the start threshold")
        sink.clear()
        sink.feedVertical(0.04, samples: 60)
        expect(sink.reports.isEmpty, "and it stops when the phone truly rests")
    }

    private static func axesHaveSeparateSensitivity() {
        // The two axes are separate sliders because the two gestures are not the
        // same movement of the same limb; the engine must not share a gain between
        // them.
        let sink = Sink { config in
            config.horizontalUnitsPerRadianPerSecond = config.verticalUnitsPerRadianPerSecond * 4
        }
        sink.begin()
        sink.feedHorizontal(0.6, samples: 30)
        let sideways = sink.totals.x
        sink.clear()
        sink.feedVertical(0.6, samples: 30)
        let lifted = -sink.totals.y

        expect(sideways > lifted * 3, "the horizontal slider moves the cursor further than the vertical one")
        expect(lifted > 0, "and the vertical axis still moves on its own")
    }

    private static func defaultsMatchTheVirtualHalfGain() {
        // The interface shows 0…100 % of one documented base gain, and the shipped
        // default is the 50 % a hand steers by: 2700 pointer units per radian, the
        // travel the maintainer measured as the usable base.
        expect(AirMouseEngine.Config.basePointerUnitsPerRadianPerSecond == 5400,
               "the base gain is 5400 units per radian at 100 %")
        let defaults = AirMouseEngine.Config()
        expect(near(Double(defaults.horizontalUnitsPerRadianPerSecond), 2700, 0.01)
                && near(Double(defaults.verticalUnitsPerRadianPerSecond), 2700, 0.01),
               "the default 50 % sensitivity is 2700 units per radian on both axes")
        expect(defaults.acceleration == 0.8 && defaults.accelerationReference == 2.0,
               "the acceleration bonus is 1.8x from 2 rad/s")
        expect(defaults.minimumTurn == 0.12 && defaults.reengage == 0.08,
               "a hand leading the phone evenly clears the start threshold")
        expect(defaults.gravityElevation == 1.0,
               "a tip gravity can see counts as movement out of the box")
    }

    private static func documentedHalfGainWalksTheScreen() {
        // The settings sliders are a percentage of one documented base gain, so the
        // shipped defaults must keep the numbers docs/air-mouse.md prints.
        // A steady 1 rad/s turn is one radian a second, so at the default gain it
        // must walk 2700 units in one second of samples. The first sample only sets
        // the clock, so 60 samples carry 59 steps.
        let steady = Sink { config in
            config.smoothing = 0
            config.acceleration = 0
        }
        steady.begin()
        steady.feedHorizontal(1.0, samples: 60)
        expect(steady.totals.x >= 2654 && steady.totals.x <= 2656,
               "a one radian per second turn at the default sensitivity is 2700 units per second")

        // The same turn at the reference speed carries the full bonus, which is
        // what lets a flick cross a screen without the host accelerating for it.
        let flick = Sink { config in config.smoothing = 0 }
        flick.begin()
        flick.feedHorizontal(2.0, samples: 60)
        expect(flick.totals.x >= 9500 && flick.totals.x <= 9560,
               "a 2 rad/s turn gets the 1.8x bonus on the default gain")
    }

    private static func evenTipMovesThePointerThroughGravity() {
        // A hand that leads the phone evenly: 20 degrees of tip in two seconds is
        // 0.17 rad/s, which clears the start threshold on the gravity reading of
        // the angle it has arrived at. The gyroscope, told the same tip travels at
        // the gentle rate a hand at rest reads as, reports nothing at all: with
        // the gravity channel off that same tip must send no reports.
        let tip = {
            (engine: AirMouseEngine) in
            var clock = live
            let start = 5.0 * Double.pi / 180
            let end = 25.0 * Double.pi / 180
            let samples = 120
            for index in 0..<samples {
                let fraction = samples == 1 ? 1.0 : Double(index) / Double(samples - 1)
                let tilt = start + (end - start) * fraction
                let frame = AirMouseEngine.pointerFrame(fromGravity: AirMouseVector3(
                    x: 0,
                    y: -sin(tilt),
                    z: -cos(tilt)
                ))
                // The speed of the same tip, at the quiet end of what a wrist
                // reports: 20 degrees over two seconds, eased in and out.
                let progress = Double(index) / Double(max(1, samples - 1))
                let rate = sin(progress * Double.pi) * 0.1
                engine.update(
                    rotationRate: AirMouseAngularVelocity(x: rate, y: 0, z: 0),
                    frame: frame,
                    at: clock
                )
                clock += step
            }
        }

        var moving: [(dx: Int8, dy: Int8)] = []
        let engine = AirMouseEngine()
        engine.onPointerMove = { dx, dy in moving.append((dx, dy)) }
        engine.begin(now: 0)
        tip(engine)
        let totals = moving.reduce((x: 0, y: 0)) { ($0.x + Int($1.dx), $0.y + Int($1.dy)) }

        // 20 degrees is 0.35 rad, which at the default 2700 units per radian is
        // about 950 units of travel, plus a small bonus for the middle of the tip.
        expect(totals.y >= 800 && totals.y <= 1250,
               "an even 20 degree tip walks about 950 units on the default gain")
        expect(totals.x == 0, "and a tip leaves the sideways axis alone")

        var quiet: [(dx: Int8, dy: Int8)] = []
        var gyroscopeOnly = AirMouseEngine.Config()
        gyroscopeOnly.gravityElevation = 0        let control = AirMouseEngine(config: gyroscopeOnly)
        control.onPointerMove = { dx, dy in quiet.append((dx, dy)) }
        control.begin(now: 0)
        tip(control)
        expect(quiet.isEmpty,
               "the same tip sends nothing at all when only the gyroscope is allowed to speak")
    }

    private static func gravityTipCarriesTheGyroSign() {
        // The gravity reading of a tip has to arrive on the same side as the
        // gyroscope reading of it, or taking whichever sensor saw more would put
        // one of them backwards.
        for degrees in stride(from: 5.0, through: 60.0, by: 5.0) {
            let tilt = degrees * Double.pi / 180
            let lift = 1.0 * Double.pi / 180
            let from = AirMouseEngine.pointerFrame(fromGravity: AirMouseVector3(
                x: 0, y: -sin(tilt), z: -cos(tilt)
            ))
            let to = AirMouseEngine.pointerFrame(fromGravity: AirMouseVector3(
                x: 0, y: -sin(tilt + lift), z: -cos(tilt + lift)
            ))
            let gravity = AirMouseEngine.elevationRate(frame: to, previous: elevationAngle(of: from),
                                                       seconds: 1.0, gain: 1)
            // Lifting the top edge of a phone lying screen-up is rotation about
            // the screen's right edge.
            let gyro = AirMouseEngine.pointerRates(of: spin(deviceRight), frame: to)
            expect(gravity.rate * gyro.y > 0,
                   "a tip at \(Int(degrees))\u{00B0} of tilt arrives on the same side from both sensors")
        }
    }

    private static func elevationAngle(of frame: AirMousePointerFrame) -> Double {
        asin(min(max(-frame.horizontalAxis.normalized.z, -1), 1))
    }

    private static func movementSurvivesTheFractionalRemainder() {
        let sink = Sink { config in
            config.smoothing = 0
            config.acceleration = 0
            config.horizontalUnitsPerRadianPerSecond = 36
        }
        sink.begin()
        sink.feedHorizontal(1.0, samples: 10)
        // Six units a second over ten samples is six units of demand, but only a
        // little over half a unit per sample: a report cannot carry a fraction, so
        // the residue has to be carried from sample to sample rather than dropped.
        expect(sink.totals.x >= 5 && sink.totals.x <= 6,
               "a fraction of a unit per sample still walks the cursor, without drifting")
        expect(sink.reports.allSatisfy { $0.dx == 1 && $0.dy == 0 },
               "and the residue arrives one unit at a time rather than in a burst")
    }

    private static func aDemandLargerThanOneReportIsSplit() {
        let sink = Sink { config in
            config.smoothing = 0
            config.acceleration = 0
            config.horizontalUnitsPerRadianPerSecond = 1_000
        }
        sink.begin()
        // The first sample of a stream only sets the clock, so the demand lands in
        // the second one.
        sink.feedHorizontal(4.0, samples: 2)
        // Four thousand units a second inside one 16 ms sample is 66 units, over
        // the per-report limit, so it has to leave as several legal reports.
        expect(sink.totals.x == 66, "the whole step arrives rather than being clipped")
        expect(sink.reports.allSatisfy { abs(Int($0.dx)) <= 60 && Int($0.dx) != 0 },
               "every report stays inside the signed byte and the configured limit")
        expect(sink.reports.count == 2, "and the step is split across two reports")

        // A limit above what a signed byte carries is clamped to the byte, and a
        // sample cannot queue more reports than the cap allows.
        let runaway = Sink { config in
            config.smoothing = 0
            config.acceleration = 0
            config.horizontalUnitsPerRadianPerSecond = 60_000
            config.maximumStep = 10_000
        }
        runaway.begin()
        runaway.feedHorizontal(4.0, samples: 2)
        expect(runaway.reports.count == 16, "a sample stops at the report cap")
        expect(runaway.reports.allSatisfy { abs(Int($0.dx)) <= Int(Int8.max) },
               "and never asks the wire for more than a signed byte")

        // A stream that stalled must not throw the cursor when it resumes.
        sink.clear()
        sink.feedHorizontal(4.0, samples: 1, restartingAt: sink.clock + 5)
        expect(sink.reports.isEmpty, "a gap in the stream is a fresh start, not one enormous step")
    }

    private static func smoothingDampsTheFirstStepAndConverges() {
        let sink = Sink()
        sink.begin()
        // Two samples: the first sets the clock, the second is the first movement.
        sink.feedVertical(1.0, samples: 2)
        let first = -sink.totals.y
        sink.clear()
        sink.feedVertical(1.0, samples: 120)
        let later = Double(-sink.totals.y) / 120

        expect(first > 0, "the first sample still moves")
        expect(later > Double(first) * 1.5, "and a steady turn reaches its full speed instead of snapping to it")
    }

    private static func fastTurnsGetExtraGain() {
        let slow = Sink { config in config.smoothing = 0 }
        slow.begin()
        slow.feedVertical(0.6, samples: 60)
        let perSecondSlow = Double(-slow.totals.y)

        let fast = Sink { config in config.smoothing = 0 }
        fast.begin()
        fast.feedVertical(6.0, samples: 60)
        let perSecondFast = Double(-fast.totals.y) / 10

        expect(perSecondFast > perSecondSlow * 1.2,
               "a fast flick is worth more than ten times a slow turn, so the host does not have to accelerate for it")
    }

    private static func inversionMirrorsBothAxes() {
        let plain = Sink()
        plain.begin()
        plain.feedHorizontal(0.6, samples: 20)
        plain.feedVertical(0.6, samples: 20)
        let plainTotals = plain.totals

        let inverted = Sink { config in
            config.invertX = true
            config.invertY = true
        }
        inverted.begin()
        inverted.feedHorizontal(0.6, samples: 20)
        inverted.feedVertical(0.6, samples: 20)
        let invertedTotals = inverted.totals

        expect(invertedTotals.x == -plainTotals.x && invertedTotals.y == -plainTotals.y,
               "inverting an axis mirrors exactly that axis")
    }

    private static func stillPhoneReanchorsItsFilters() {
        // Movement comes from rotation rate, so a tilt that is merely being held
        // has never pushed the cursor; what a still phone can leave behind is
        // residue in the filters and in the half-unit the last report could not
        // carry. After a moment of stillness that has all to be gone.
        let sink = Sink { config in
            config.idleReanchor = 0.5
            config.smoothing = 0
        }
        sink.begin()
        sink.feedHorizontal(0.6, samples: 30)
        expect(!sink.engine.isSettled, "a phone under the hand is not settled")
        let whileMoving = sink.totals.x

        sink.feedHorizontal(0.0, samples: 60)
        expect(sink.engine.isSettled, "a phone that has stood still for half a second is")
        expect(sink.totals.x >= whileMoving && sink.totals.x - whileMoving <= 2,
               "and resting leaks at most the fraction the last report left behind")

        // With the re-anchor switched off the state is never declared clean, so
        // whatever the last turn left over is still waiting for the next one.
        let stale = Sink { config in config.idleReanchor = 0 }
        stale.begin()
        stale.feedHorizontal(0.6, samples: 30)
        stale.feedHorizontal(0.0, samples: 120)
        expect(!stale.engine.isSettled, "without a re-anchor a resting phone is never clean")
    }

    private static func activationHoldAndRecentreControlTracking() {
        let sink = Sink()
        sink.begin(now: 0)
        // Fifteen samples from 0.1 s, all of them inside the 0.35 s hold.
        sink.feedVertical(3.0, samples: 15, restartingAt: 0.1)
        expect(sink.reports.isEmpty, "the lift into pointing position sends nothing")

        sink.feedVertical(3.0, samples: 20, restartingAt: live)
        expect(!sink.reports.isEmpty, "tracking starts once the hold is over")

        // A gap in the stream is a pause, not a giant step.
        sink.clear()
        sink.feedVertical(3.0, samples: 1, restartingAt: sink.clock + 2)
        expect(sink.reports.isEmpty, "the first sample after a pause only resets the clock")

        sink.engine.end()
        sink.clear()
        sink.feedVertical(3.0, samples: 30)
        expect(sink.reports.isEmpty, "a stopped engine ignores samples")

        sink.engine.begin(now: sink.clock)
        sink.clear()
        sink.feedVertical(3.0, samples: 10)
        expect(sink.reports.isEmpty, "re-anchoring restarts the hold, so a turn in progress is not carried over")
    }

    private static func gravityEstimateIgnoresBumpsAndTracksTurns() {
        var filter = AirMouseGravityEstimator()
        let held = AirMouseVector3(y: -1)
        _ = filter.addSample(held, dt: 0.05)
        let afterBump = filter.addSample(AirMouseVector3(x: 0.3, y: -0.9), dt: 0.05)
        expect((afterBump - held).length < 0.1, "a wrist bump must not re-aim the pointer frame")

        var turned = filter.value
        for _ in 0..<60 {
            turned = filter.addSample(AirMouseVector3(x: -1), dt: 0.05)
        }
        expect(near(turned.x, -1, 0.05) && near(turned.y, 0, 0.05),
               "a slow change of how the phone is held is tracked")
        expect(AirMouseEngine.pointerFrame(fromGravity: turned).horizontalAxis.x < -0.9,
               "and the frame follows it")

        filter.reset()
        expect(filter.value == AirMouseGravityEstimator.initialGravity, "reset returns to the upright seed")

        // A non-positive interval must not divide by zero or move the estimate.
        var stalled = AirMouseGravityEstimator()
        _ = stalled.addSample(AirMouseVector3(x: 5, y: 0, z: 0), dt: 0)
        expect(stalled.value == AirMouseGravityEstimator.initialGravity,
               "a zero interval cannot move the estimate")
    }

    // MARK: - Helpers

    private static func spin(_ axis: AirMouseVector3) -> AirMouseAngularVelocity {
        AirMouseAngularVelocity(x: axis.x, y: axis.y, z: axis.z)
    }

    private static func near(_ value: Double, _ expected: Double, _ tolerance: Double = 1e-9) -> Bool {
        abs(value - expected) < tolerance
    }

    private static func expect(_ condition: Bool, _ message: String) {
        precondition(condition, "air mouse engine test failed: \(message)")
    }

    /// An engine plus the reports it produced and the sample clock it was fed.
    private final class Sink {
        private(set) var reports: [(dx: Int8, dy: Int8)] = []
        var engine: AirMouseEngine
        let frame: AirMousePointerFrame
        var clock = live

        init(_ configure: (inout AirMouseEngine.Config) -> Void = { _ in }) {
            var config = AirMouseEngine.Config()
            configure(&config)
            engine = AirMouseEngine(config: config)
            frame = AirMouseEngine.pointerFrame(fromGravity: uprightGravity)
            engine.onPointerMove = { [weak self] dx, dy in
                self?.reports.append((dx, dy))
            }
        }

        var totals: (x: Int, y: Int) {
            reports.reduce((0, 0)) { ($0.x + Int($1.dx), $0.y + Int($1.dy)) }
        }

        func begin(now: TimeInterval = 0) {
            engine.begin(now: now)
        }

        func clear() {
            reports.removeAll()
        }

        /// Feed a sideways turn — rotation about the world's vertical — one sample
        /// per step. The clock keeps running across calls so a paused stream stays
        /// honest.
        func feedHorizontal(_ rate: Double, samples: Int, restartingAt start: TimeInterval? = nil) {
            feed(frame.horizontalAxis, rate: rate, samples: samples, restartingAt: start)
        }

        /// Feed a tip over the heading; positive raises the pointer, which is the
        /// direction the HID y axis counts as negative.
        func feedVertical(_ rate: Double, samples: Int, restartingAt start: TimeInterval? = nil) {
            feed(-frame.verticalAxis, rate: rate, samples: samples, restartingAt: start)
        }

        private func feed(_ axis: AirMouseVector3, rate: Double, samples: Int, restartingAt start: TimeInterval?) {
            if let start { clock = start }
            for _ in 0..<samples {
                engine.update(
                    rotationRate: AirMouseAngularVelocity(
                        x: axis.x * rate,
                        y: axis.y * rate,
                        z: axis.z * rate
                    ),
                    frame: frame,
                    at: clock
                )
                clock += step
            }
        }
    }
}
