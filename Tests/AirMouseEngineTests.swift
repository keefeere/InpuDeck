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
        flatPhonePointsWhereTheTopEdgePoints()
        headingIsGivenUpWhenThePhoneLiesFlat()
        restAbsorbsTremorAndHoldsStillness()
        axesHaveSeparateSensitivity()
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

    private static func flatPhonePointsWhereTheTopEdgePoints() {
        // Screen up on a table: the heading the screen faces is undefined, so the
        // direction the top edge points at stands in for it.
        let frame = AirMouseEngine.pointerFrame(fromGravity: AirMouseVector3(z: -1))
        expect(near(frame.horizontalAxis.z, -1) && near(frame.horizontalAxis.y, 0),
               "the horizontal axis is still the world's vertical")
        expect(near(frame.verticalAxis.x, -1) && near(frame.verticalAxis.dot(deviceUp), 0, 1e-9),
               "the vertical axis tips over the top edge, not over a noise-driven heading")
        expect(near(frame.verticalAxis.length, 1) && near(frame.horizontalAxis.length, 1),
               "the fallback frame stays a unit basis")
    }

    private static func headingIsGivenUpWhenThePhoneLiesFlat() {
        // A phone lying almost flat: the screen normal is almost the world's
        // vertical, so which way it faces is mathematically defined and practically
        // noise, and noise in the heading is noise in the cursor. The threshold
        // gives the heading up early and takes the top edge instead.
        let flatness = 10 * Double.pi / 180
        let gravity = AirMouseVector3(y: -sin(flatness), z: -cos(flatness))
        let guarded = AirMouseEngine.pointerFrame(fromGravity: gravity)
        let trusting = AirMouseEngine.pointerFrame(fromGravity: gravity, minimumHorizontalNormal: 0.05)

        expect(guarded.verticalAxis.dot(deviceUp).magnitude < 0.15,
               "almost flat on a table the tip axis stays across the top edge")
        expect((guarded.verticalAxis - trusting.verticalAxis).length > 0.5,
               "and that is a different, steadier answer than trusting the normal")
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
        for rate in [0.05, 0.12, 0.25] {
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
        sink.feedVertical(0.05, samples: 60)
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
