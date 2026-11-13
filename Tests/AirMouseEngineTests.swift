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
        theTipAxisLiesInsideTheScreensPlane()
        aRolledPhoneNearFlatCarriesTheWholeTip()
        aPhoneLyingPerfectlyFlatGivesNoTipAxis()
        restAbsorbsTremorAndHoldsStillness()
        axesHaveSeparateSensitivity()
        defaultsMatchTheVirtualHalfGain()
        documentedHalfGainWalksTheScreen()
        evenTipMovesThePointerThroughGravity()
        gravityTipCarriesTheGyroSign()
        settlingTailAfterAStopDoesNotWalkThePointerBack()
        withoutDampingTheSettlingTailWalksBack()
        deliberateReverseTurnIsNotTreatedAsTheTail()
        steadyTurnBackArrivesOnceTheWindowIsBehindIt()
        aTurnBuiltUpOutOfNothingIsNotATail()
        sidewaysTravelDoesNotKeepAVerticalTurnBackBlocked()
        aPhoneThatHasNotMovedYetKeepsItsFilters()
        movementSurvivesTheFractionalRemainder()
        aDemandLargerThanOneReportIsSplit()
        smoothingDampsTheFirstStepAndConverges()
        smoothingLagsTheSameTimeAtAnySampleRate()
        fastTurnsGetExtraGain()
        inversionMirrorsBothAxes()
        stillPhoneReanchorsItsFilters()
        activationHoldAndRecentreControlTracking()
        gravityEstimateIgnoresBumpsAndTracksTurns()

        print("PASS: air mouse maps world-relative rotation to HID deltas without creep")
    }

    // MARK: - The pointer frame

    private static func pointerFrameFollowsTheWorld() {
        let frame = frame(for: uprightGravity)

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
            let frame = frame(for: gravity)
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
        let frame = frame(for: uprightGravity)
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
            let rolled = frame(for: gravity)
            let rates = AirMouseEngine.pointerRates(of: spin(-rolled.verticalAxis), frame: rolled)
            expect(near(rates.y, -1, 1e-9) && near(rates.x, 0, 1e-9),
                   "a tip at \(Int(degrees))° of roll stays a tip")
        }
    }

    private static func theTipAxisLiesInsideTheScreensPlane() {
        // The pointer's vertical axis is the world-horizontal direction that lies
        // inside the plane of the screen, because a tip over the heading is a turn
        // about exactly that. Both halves of that claim are checked at every roll
        // and every flatness: square to gravity, so the pointer moves along the
        // world's horizontal; square to the screen normal, so the turn the axis
        // measures is the tip the hand actually made.
        let screenNormal = AirMouseVector3(z: 1)
        for degrees in stride(from: 0.0, through: 330.0, by: 30.0) {
            let roll = degrees * Double.pi / 180
            for flatness in stride(from: 3.0, through: 80.0, by: 7.0) {
                let flat = flatness * Double.pi / 180
                let gravity = rolled(AirMouseVector3(y: -sin(flat), z: -cos(flat)), by: roll)
                let frame = frame(for: gravity)
                expect(near(frame.verticalAxis.dot(gravity.normalized), 0, 1e-9)
                        && near(frame.verticalAxis.dot(screenNormal), 0, 1e-9),
                       "the tip axis at \(Int(degrees))\u{00B0} of roll and \(Int(flatness))\u{00B0} off a table is world-horizontal and inside the screen")
                expect(near(frame.verticalAxis.length, 1) && near(frame.horizontalAxis.length, 1),
                       "and the frame stays a unit basis there")
            }
        }
    }

    private static func aRolledPhoneNearFlatCarriesTheWholeTip() {
        // The claim the shape of the axis exists to keep: a turn that changes the
        // screen's elevation moves the pointer at full rate, whatever way the phone
        // is rolled. Near flat this is where the old frame, which built the axis
        // out of which way the screen faces, threw the gesture away — a phone
        // cradled at 30\u{00B0} lost 13% of the tip, at 60\u{00B0} half of it, and
        // held in landscape it lost all of it: the cursor sat still while the
        // screen swung through twenty degrees.
        for degrees in stride(from: 0.0, through: 330.0, by: 30.0) {
            let roll = degrees * Double.pi / 180
            for flatness in stride(from: 3.0, through: 40.0, by: 3.0) {
                let flat = flatness * Double.pi / 180
                let gravity = rolled(AirMouseVector3(y: -sin(flat), z: -cos(flat)), by: roll)
                // The turn that raises or lowers the screen, carried round into the
                // same rolled pose gravity was carried into.
                let turn = rolled(deviceRight, by: roll)
                let rates = AirMouseEngine.pointerRates(of: AirMouseAngularVelocity(
                    x: turn.x,
                    y: turn.y,
                    z: turn.z
                ), frame: frame(for: gravity))
                expect(near(abs(rates.y), 1, 1e-6) && near(rates.x, 0, 1e-6),
                       "a tip \(Int(flatness))\u{00B0} off a table at \(Int(degrees))\u{00B0} of roll arrives whole and sideways-free")
            }
        }

        // The landscape case on its own, spelled out: a phone 10 degrees off a
        // table with its top edge pointing right, swung up over the edge it rests
        // on. This is the pose that used to report nothing at all.
        let flat = 10 * Double.pi / 180
        let gravity = AirMouseVector3(
            x: sin(flat),
            y: 0,
            z: -cos(flat)
        )
        let rates = AirMouseEngine.pointerRates(of: AirMouseAngularVelocity(y: -1),
                                               frame: frame(for: gravity))
        expect(near(rates.y, -1, 1e-6) && near(rates.x, 0, 1e-6),
               "a phone lying in landscape still sends the whole tip, and it lifts the pointer")
    }

    private static func aPhoneLyingPerfectlyFlatGivesNoTipAxis() {
        // Exactly on a table there is no horizontal direction inside the screen to
        // prefer over any other, so the frame says so rather than inventing one.
        expect(AirMouseEngine.pointerFrame(fromGravity: AirMouseVector3(z: -1)) == nil,
               "a phone lying screen-up has no tip axis to be found")
        expect(AirMouseEngine.pointerFrame(fromGravity: AirMouseVector3(z: 1)) == nil,
               "nor does one lying screen-down")
        // The sideways axis is unaffected: rotation about the world's vertical is
        // still readable with the phone flat, so a table phone still steers left
        // and right while it waits to be lifted.
        let edge = frame(for: AirMouseVector3(x: 0.2, y: 0, z: -sqrt(1 - 0.04)))
        expect(near(edge!.horizontalAxis.length, 1) && near(edge!.verticalAxis.length, 1),
               "and one just off flat has both axes")
        expect(near(frame(for: uprightGravity).verticalAxis.dot(deviceRight), 1, 1e-9),
               "the upright seed the adapter starts from is the screen's own right edge")
    }

    /// Gravity or an axis, carried round the screen normal by `roll` radians.
    private static func rolled(_ value: AirMouseVector3, by roll: Double) -> AirMouseVector3 {
        AirMouseVector3(
            x: value.x * cos(roll) - value.y * sin(roll),
            y: value.x * sin(roll) + value.y * cos(roll),
            z: value.z
        )
    }

    /// The frame for a pose, failing the test rather than unwrapping in place.
    private static func frame(for gravity: AirMouseVector3) -> AirMousePointerFrame {
        guard let frame = AirMouseEngine.pointerFrame(fromGravity: gravity) else {
            preconditionFailure(
                "air mouse engine test failed: no tip axis for gravity (\(gravity.x), \(gravity.y), \(gravity.z))"
            )
        }
        return frame
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
        sink.feedVertical(0.04, samples: 4)
        // The smoother is still carrying the turn for a sample or two, so the axis
        // stops with a short, bounded tail rather than crawling on.
        let stopping = sink.totals.y
        expect(abs(stopping) <= 20, "the stopping tail is bounded: \(stopping)")
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
                let frame = frame(for: AirMouseVector3(
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
        gyroscopeOnly.gravityElevation = 0
        let control = AirMouseEngine(config: gyroscopeOnly)
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
            let from = frame(for: AirMouseVector3(
                x: 0, y: -sin(tilt), z: -cos(tilt)
            ))
            let to = frame(for: AirMouseVector3(
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

    /// A tip the hand stops: the pointer has to stay where the gesture left it.
    private static func settlingTailSink() -> Sink {
        let sink = Sink { config in
            config.acceleration = 0
            config.gravityElevation = 0
        }
        sink.begin()
        // Half a second of tip at 1 rad/s: 29 samples of 45 units at the default
        // half gain.
        sink.feedVertical(1.0, samples: 30)
        return sink
    }

    private static func settlingTailAfterAStopDoesNotWalkThePointerBack() {
        // The field report: tip the phone up, hold it there, and the pointer
        // walked back on its own, without the phone moving. Fused rotation does
        // not stop dead at zero; it tails off through zero and keeps a shrinking
        // opposite reading for a few tenths of a second, and integrating that tail
        // is what walked the pointer back.
        let sink = settlingTailSink()
        let travelled = sink.totals.y
        expect(travelled < -1000, "half a second of tip has to walk the pointer: \(travelled)")
        sink.clear()
        for index in 0 ..< 24 {
            sink.feedVertical(-0.3 * pow(0.85, Double(index)), samples: 1)
        }
        expect(Double(abs(sink.totals.y)) <= Double(abs(travelled)) * 0.05,
               "the settling tail walked the pointer back: \(sink.totals.y) of \(travelled)")
    }

    private static func withoutDampingTheSettlingTailWalksBack() {
        // The same feed with the damping off is the behaviour that was reported,
        // so the guard has to be what changes it.
        let sink = Sink { config in
            config.acceleration = 0
            config.gravityElevation = 0
            config.stopDamping = 0
        }
        sink.begin()
        sink.feedVertical(1.0, samples: 30)
        let travelled = sink.totals.y
        sink.clear()
        for index in 0 ..< 24 {
            sink.feedVertical(-0.3 * pow(0.85, Double(index)), samples: 1)
        }
        expect(sink.totals.y > 20,
               "with the damping off the same tail walks the pointer back: \(sink.totals.y) of \(travelled)")
    }

    private static func deliberateReverseTurnIsNotTreatedAsTheTail() {
        let sink = settlingTailSink()
        sink.clear()
        sink.feedVertical(-1.2, samples: 12)
        // The tip walked the pointer up (negative HID y), so a turn back has to
        // arrive as a large positive movement on the very next samples.
        expect(sink.totals.y > 300,
               "a turn back at 1.2 rad/s has to move the pointer, not be damped: \(sink.totals.y)")
    }

    private static func steadyTurnBackArrivesOnceTheWindowIsBehindIt() {
        // A hand that turns back at one steady speed reads like a tail while the
        // window covers it, so it arrives late rather than never: a quarter second
        // of the turn is given up, and the rest walks the pointer.
        let sink = settlingTailSink()
        sink.clear()
        sink.feedVertical(-0.2, samples: 30)
        expect(sink.totals.y > 80,
               "a slow steady turn back walks the pointer once the window is behind it: \(sink.totals.y)")
    }

    private static func aTurnBuiltUpOutOfNothingIsNotATail() {
        // A hand builds a turn up out of nothing, so the reading grows sample by
        // sample and the guard has to let it through from the start.
        let sink = settlingTailSink()
        sink.clear()
        for index in 0 ..< 12 {
            sink.feedVertical(-0.05 * Double(index + 1), samples: 1)
        }
        expect(sink.totals.y > 100,
               "a turn the hand builds up moves out of the gate: \(sink.totals.y)")
    }

    private static func sidewaysTravelDoesNotKeepAVerticalTurnBackBlocked() {
        // The damping window belongs to the axis that turned, so a hand that keeps
        // travelling sideways cannot hold a vertical turn back down.
        let sink = settlingTailSink()
        sink.clear()
        sink.feedHorizontal(1.0, samples: 30)
        sink.clear()
        sink.feedVertical(-0.2, samples: 10)
        expect(sink.totals.y > 40,
               "sideways travel must not keep a vertical turn back blocked: \(sink.totals.y)")
    }

    private static func aPhoneThatHasNotMovedYetKeepsItsFilters() {
        // The point of the gravity channel is a tip the hand leads evenly, and it
        // only works if the smoother is allowed to ramp up out of a resting start.
        // Clearing the filters on every resting sample, before the phone has ever
        // moved, wiped that ramp, so a 20 degree tip in two seconds sent nothing.
        let sink = Sink()
        sink.begin()
        sink.feedVertical(0.0, samples: 120)
        expect(!sink.engine.isSettled,
               "a phone that has never moved has no residue to clear, so the slow tip keeps its ramp")
        sink.clear()
        sink.feedVertical(1.0, samples: 30)
        expect(sink.totals.y != 0, "and the next deliberate turn still moves")
        sink.clear()
        sink.feedVertical(0.0, samples: 120)
        expect(sink.engine.isSettled, "while a phone that moved and then rests does clean up")
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

    private static func smoothingLagsTheSameTimeAtAnySampleRate() {
        // The stream is sampled faster than it used to be, and the smoothing slider
        // is a promise about time, not about samples: the same turn of the wrist,
        // lasting the same quarter of a second at the same speed, has to land the
        // pointer in the same place whatever rate the phone reported it at. A
        // slider that damps per sample breaks that as soon as the rate moves, and
        // measured eight fold apart it lands the pointer 15% of the tip away;
        // measured as time it is under 4%.
        var slow: [(dx: Int8, dy: Int8)] = []
        var fast: [(dx: Int8, dy: Int8)] = []
        for (interval, bucket) in [(1.0 / 30.0, "slow"), (1.0 / 240.0, "fast")] {
            let sink = Sink()
            sink.begin()
            var clock = live
            let samples = Int(0.25 / interval)
            for index in 0..<samples {
                // A tip eased in and out over a quarter of a second, worth the same
                // degrees either way round.
                let progress = Double(index) / Double(max(1, samples - 1))
                let rate = sin(progress * Double.pi) * 0.8
                let axis = sink.frame.verticalAxis
                sink.engine.update(
                    rotationRate: AirMouseAngularVelocity(
                        x: -axis.x * rate,
                        y: -axis.y * rate,
                        z: -axis.z * rate
                    ),
                    frame: sink.frame,
                    at: clock
                )
                clock += interval
            }
            if bucket == "slow" { slow = sink.reports } else { fast = sink.reports }
        }
        let travelled = { (reports: [(dx: Int8, dy: Int8)]) in
            Double(reports.reduce(0) { $0 + Int($1.dy) })
        }
        let atThirty = travelled(slow), atTwoHundredAndForty = travelled(fast)
        expect(atThirty < 0 && atTwoHundredAndForty < 0, "the quarter second tip moves the pointer up at either rate")
        expect(abs(atThirty - atTwoHundredAndForty) < abs(atThirty) * 0.10,
               "and the same tip travels the same distance whatever the sample rate: \(atThirty) against \(atTwoHundredAndForty)")
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
        expect(frame(for: turned).horizontalAxis.x < -0.9,
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
            frame = AirMouseEngineTests.frame(for: uprightGravity)
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
        func feedVertical(_ rate: Double, samples: Int, restartingAt start: TimeInterval? = nil,
                          every interval: TimeInterval = step) {
            feed(-frame.verticalAxis, rate: rate, samples: samples, restartingAt: start, every: interval)
        }

        private func feed(_ axis: AirMouseVector3, rate: Double, samples: Int, restartingAt start: TimeInterval?,
                          every interval: TimeInterval = step) {
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
                clock += interval
            }
        }
    }
}
