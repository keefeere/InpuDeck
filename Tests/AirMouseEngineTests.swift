import Foundation

/// One sample step at the rate the phone streams at.
private let step = 1.0 / 60.0
/// The first sample time after `begin(now: 0)`, past the default activation hold.
private let live = 0.36
private let portrait = AirMouseScreenAxes.portrait

@main
struct AirMouseEngineTests {
    static func main() {
        screenAxesFollowGravity()
        pointerFollowsTheScreenPlane()
        restAbsorbsTremorAndHoldsStillness()
        movementSurvivesTheFractionalRemainder()
        movementIsSplitIntoLegalReports()
        smoothingDampsTheFirstStepAndConverges()
        fastTiltsGetExtraGain()
        inversionMirrorsBothAxes()
        activationHoldAndRecentreControlTracking()
        gravityEstimateIgnoresBumpsAndTracksTurns()
        holdingOrientationsGiveUsablePlanes()

        print("PASS: air mouse maps screen-plane rotation to HID deltas without creep")
    }

    // MARK: - Screen plane

    private static func screenAxesFollowGravity() {
        // Portrait, held upright and tilted back 17 degrees: gravity runs along
        // the device's -y and into its back.
        let tilt = 17 * Double.pi / 180
        let upright = AirMouseVector3(y: -cos(tilt), z: -sin(tilt))
        let axes = AirMouseEngine.screenAxes(fromGravity: upright, fallback: portrait)
        expect(near(axes.up.x, 0) && near(axes.up.y, 1), "the screen's up follows the top edge")
        expect(near(axes.right.x, 1) && near(axes.right.y, 0), "the screen's right follows its long edge")

        // The same phone rolled 30 degrees counter-clockwise in its own plane.
        let roll = 30 * Double.pi / 180
        let rolled = AirMouseVector3(
            x: cos(tilt) * sin(roll),
            y: -cos(tilt) * cos(roll),
            z: -sin(tilt)
        )
        let rolledAxes = AirMouseEngine.screenAxes(fromGravity: rolled, fallback: portrait)
        expect(near(rolledAxes.up.x, -sin(roll)) && near(rolledAxes.up.y, cos(roll)),
               "the plane turns with the phone, not with the device frame")
        expect(near(rolledAxes.right.x, cos(roll)) && near(rolledAxes.right.y, sin(roll)),
               "right stays a quarter turn clockwise from up")
        expect(near(rolledAxes.up.x * rolledAxes.right.x + rolledAxes.up.y * rolledAxes.right.y, 0),
               "the plane stays square")

        // The phone lies flat on a desk: no direction in the screen plane wins,
        // so the caller's fallback has to survive.
        let flat = AirMouseVector3(z: -1)
        expect(AirMouseEngine.screenAxes(fromGravity: flat, fallback: rolledAxes) == rolledAxes,
               "a flat phone keeps the last known plane")
        expect(AirMouseEngine.screenAxes(fromGravity: upright, fallback: rolledAxes, minimumInPlaneGravity: 0.99)
                == rolledAxes,
               "a threshold above the real in-plane gravity falls back too")
    }

    private static func pointerFollowsTheScreenPlane() {
        // Turning the screen to the right sweeps the pointer right.
        let yaw = AirMouseEngine.screenRates(of: AirMouseAngularVelocity(y: 0.8), axes: portrait)
        expect(yaw.x > 0 && near(yaw.y, 0), "turning the screen sideways moves the pointer sideways")

        // Pointing the phone at the ceiling sweeps the pointer up; the HID y axis
        // grows downwards, so up is negative.
        let pitch = AirMouseEngine.screenRates(of: AirMouseAngularVelocity(x: -0.8), axes: portrait)
        expect(near(pitch.x, 0) && pitch.y < 0, "tilting the top edge away lifts the pointer")

        // The same tilt in a rolled phone keeps its speed and follows the screen.
        let roll = 30 * Double.pi / 180
        let tilt = 17 * Double.pi / 180
        let axes = AirMouseEngine.screenAxes(
            fromGravity: AirMouseVector3(
                x: cos(tilt) * sin(roll),
                y: -cos(tilt) * cos(roll),
                z: -sin(tilt)
            ),
            fallback: portrait
        )
        let rates = AirMouseEngine.screenRates(of: AirMouseAngularVelocity(y: 0.8), axes: axes)
        expect(near(hypot(rates.x, rates.y), 0.8, 1e-12),
               "rolling the phone never changes how fast the pointer travels")
        expect(rates.x > 0 && rates.y > 0, "and it still travels along the tilted screen")
    }

    // MARK: - Dead zone and rest

    private static func restAbsorbsTremorAndHoldsStillness() {
        // A hand that only shakes stays below the turn threshold: nothing moves.
        let tremor = Sink()
        tremor.engine.begin(now: 0)
        tremor.feed(rate: 0.3, samples: 30)
        expect(tremor.reports.isEmpty, "a tremor larger than the dead zone must not move the cursor")

        // A deliberate turn starts movement, an in-between speed keeps it alive,
        // and dropping below the re-engage threshold returns the axis to rest
        // instead of letting it run on.
        let engine = Sink { config in
            config.smoothing = 0
        }
        engine.engine.begin(now: 0)
        engine.feed(rate: 0.6, samples: 3)
        let started = engine.reports.count
        expect(started > 0, "a turn above the threshold moves the pointer")

        engine.feed(rate: 0.4, samples: 3)
        expect(engine.reports.count > started, "between the two thresholds the pointer keeps going")

        let beforeStop = engine.reports.count
        engine.feed(rate: 0.3, samples: 24)
        expect(engine.reports.count == beforeStop, "slowing below the re-engage threshold returns to rest")
    }

    // MARK: - Accumulation and reports

    private static func movementSurvivesTheFractionalRemainder() {
        // 0.7 rad/s past the dead zone is 52.2 units/s, so 0.87 units per sample:
        // each report carries one unit and the remainder carries on.
        let engine = Sink { config in
            config.smoothing = 0
            config.acceleration = 0
        }
        engine.engine.begin(now: 0)
        engine.feed(rate: 0.7, samples: 10)
        expect(engine.dx == [1, 1, 1, 1, 1, 1, 1], "each live sample contributes a whole unit")
        expect(engine.totals.x == 7, "nine integrating samples at 0.87 units carry seven units, not six")
    }

    private static func movementIsSplitIntoLegalReports() {
        let engine = Sink { config in
            config.smoothing = 0
            config.acceleration = 0
            config.maximumStep = 20
        }
        engine.engine.begin(now: 0)
        engine.feed(rate: 0.62, samples: 1)
        engine.feed(rate: 20, samples: 1)
        expect(engine.totals.x == 29, "one fast sample carries its whole movement across reports")
        expect(engine.dx.allSatisfy { $0 > 0 && $0 <= 20 }, "no report exceeds the configured step or changes sign")

        // A burst longer than the cap drops the remainder instead of flooding the
        // transport queue, which is what a stall in the stream would otherwise do.
        let capped = Sink { config in
            config.smoothing = 0
            config.acceleration = 0
            config.maximumStep = 4
        }
        capped.engine.begin(now: 0)
        capped.feed(rate: 0.62, samples: 1)
        capped.feed(rate: 60, samples: 1)
        expect(capped.reports.count == 16, "the burst is capped at maximumReportsPerSample")
        expect(capped.totals.x == 64, "and only the reports that fit are sent")
    }

    // MARK: - Response curve

    private static func smoothingDampsTheFirstStepAndConverges() {
        let engine = Sink { config in
            config.smoothing = 0.5
            config.acceleration = 0
        }
        engine.engine.begin(now: 0)
        engine.feed(rate: 1, samples: 2)
        expect(engine.totals.x == 0, "the first step after rest is damped below one unit")

        engine.feed(rate: 1, samples: 40)
        expect(engine.totals.x > 48 && engine.totals.x < 58,
               "the filter converges to the steady rate instead of lagging forever")
    }

    private static func fastTiltsGetExtraGain() {
        let slow = Sink { config in
            config.smoothing = 0
            config.acceleration = 0.5
        }
        let fast = Sink { config in
            config.smoothing = 0
            config.acceleration = 0.5
        }
        slow.engine.begin(now: 0)
        fast.engine.begin(now: 0)
        slow.feed(rate: 0.7, samples: 11)
        fast.feed(rate: 4, samples: 11)
        let ratio = Double(slow.totals.x) / Double(fast.totals.x)
        // A linear response would give (0.7 - 0.12) / (4 - 0.12) = 0.15; the gain
        // curve must make the fast tilt travel proportionally further.
        expect(ratio > 0.08 && ratio < 0.12, "fast movement is amplified relative to slow movement")
    }

    private static func inversionMirrorsBothAxes() {
        let normal = Sink()
        let inverted = Sink { config in
            config.invertX = true
            config.invertY = true
        }
        normal.engine.begin(now: 0)
        inverted.engine.begin(now: 0)
        let rate = AirMouseAngularVelocity(x: -0.6, y: 0.6)
        for index in 0..<5 {
            let at = live + Double(index) * step
            normal.engine.update(rotationRate: rate, axes: portrait, at: at)
            inverted.engine.update(rotationRate: rate, axes: portrait, at: at)
        }
        expect(normal.totals.x == -inverted.totals.x && normal.totals.y == -inverted.totals.y,
               "inverting an axis mirrors its deltas exactly")
    }

    // MARK: - Lifecycle

    private static func activationHoldAndRecentreControlTracking() {
        let engine = Sink()
        engine.engine.begin(now: 0)
        expect(engine.engine.isHolding, "activation opens with a hold that absorbs the lift")

        engine.feed(rate: 4, samples: 18, restartingAt: 0)
        expect(engine.reports.isEmpty, "movement during the activation hold sends nothing")

        engine.feed(rate: 4, samples: 1, restartingAt: live)
        expect(!engine.engine.isHolding, "the hold ends once a live sample arrives")
        engine.feed(rate: 4, samples: 1)
        expect(engine.reports.count > 0, "movement begins once the hold has passed")

        // Recentring clears the accumulated movement.
        engine.clear()
        engine.engine.begin(now: engine.clock)
        expect(engine.engine.isHolding, "recentring goes back through the hold")
        engine.feed(rate: 4, samples: 2, restartingAt: engine.clock + 0.4)
        expect(engine.reports.count > 0, "and tracking resumes afterwards")

        // Stopping silences the engine.
        engine.engine.end()
        let frozen = engine.reports.count
        engine.feed(rate: 4, samples: 10)
        expect(engine.reports.count == frozen, "update after end is ignored")

        // A long gap in the stream must not become one enormous step.
        engine.engine.begin(now: 0)
        engine.feed(rate: 4, samples: 2)
        engine.clear()
        engine.clock += 1
        engine.feed(rate: 4, samples: 2)
        expect(engine.reports.count <= 1, "a one second gap does not throw the cursor")
    }

    // MARK: - Gravity estimate

    private static func gravityEstimateIgnoresBumpsAndTracksTurns() {
        var filter = AirMouseGravityEstimator()
        let held = AirMouseVector3(y: -1)
        _ = filter.addSample(held, dt: 0.05)
        let afterBump = filter.addSample(AirMouseVector3(x: 0.3, y: -0.9), dt: 0.05)
        expect(hypot(afterBump.x - held.x, afterBump.y - held.y) < 0.1,
               "a wrist bump must not re-aim the screen plane")

        var turned = filter.value
        for _ in 0..<60 {
            turned = filter.addSample(AirMouseVector3(x: -1), dt: 0.05)
        }
        expect(near(turned.x, -1, 0.05) && near(turned.y, 0, 0.05),
               "a slow change of how the phone is held is tracked")
        expect(AirMouseEngine.screenAxes(fromGravity: turned, fallback: portrait).up.x > 0.9,
               "and the plane follows it")

        filter.reset()
        expect(filter.value == AirMouseVector3(), "reset forgets the estimate")

        // A non-positive interval must not divide by zero or start the estimate.
        var stalled = AirMouseGravityEstimator()
        _ = stalled.addSample(held, dt: 0)
        expect(stalled.value == AirMouseVector3(), "a zero interval cannot start the estimate")
    }

    // MARK: - Holding orientations

    private static func holdingOrientationsGiveUsablePlanes() {
        let expected: [AirMouseHolding: [(Double, Double)]] = [
            .portrait: [(1, 0), (0, 1)],
            .portraitUpsideDown: [(-1, 0), (0, -1)],
            .landscapeLeft: [(0, -1), (1, 0)],
            .landscapeRight: [(0, 1), (-1, 0)],
        ]
        for holding in AirMouseHolding.allCases {
            let axes = holding.screenAxes
            let right = expected[holding]![0]
            let up = expected[holding]![1]
            expect(near(axes.right.x, right.0) && near(axes.right.y, right.1),
                   "\(holding.rawValue) runs the pointer along the long edge")
            expect(near(axes.up.x, up.0) && near(axes.up.y, up.1),
                   "\(holding.rawValue) runs the pointer against the top edge")
            expect(near(axes.right.length, 1) && near(axes.up.length, 1),
                   "\(holding.rawValue) stays a unit basis")
            expect(near(axes.right.x * axes.up.x + axes.right.y * axes.up.y, 0),
                   "\(holding.rawValue) stays square")
        }

        // Landscape with the home button to the right, held with its top edge up:
        // gravity and the fallback must agree about which way is up.
        let axes = AirMouseEngine.screenAxes(
            fromGravity: AirMouseVector3(x: -1),
            fallback: AirMouseHolding.landscapeLeft.screenAxes
        )
        expect(axes == AirMouseHolding.landscapeLeft.screenAxes,
               "the fallback plane matches what gravity reports for the same holding")
    }

    // MARK: - Helpers

    private static func near(_ value: Double, _ expected: Double, _ tolerance: Double = 1e-9) -> Bool {
        abs(value - expected) < tolerance
    }

    private static func hypot(_ x: Double, _ y: Double) -> Double {
        (x * x + y * y).squareRoot()
    }

    private static func expect(_ condition: Bool, _ message: String) {
        precondition(condition, "air mouse engine test failed: \(message)")
    }

    /// An engine plus the reports it produced and the sample clock it was fed.
    private final class Sink {
        private(set) var reports: [(dx: Int8, dy: Int8)] = []
        let engine: AirMouseEngine
        var clock = live

        init(_ configure: (inout AirMouseEngine.Config) -> Void = { _ in }) {
            var config = AirMouseEngine.Config()
            configure(&config)
            engine = AirMouseEngine(config: config)
            engine.onPointerMove = { [weak self] dx, dy in
                self?.reports.append((dx, dy))
            }
        }

        var dx: [Int] { reports.map { Int($0.dx) } }

        var totals: (x: Int, y: Int) {
            reports.reduce((0, 0)) { ($0.x + Int($1.dx), $0.y + Int($1.dy)) }
        }

        func clear() {
            reports.removeAll()
        }

        /// Feed tilt rate around the screen's vertical axis, one sample per step.
        /// The clock keeps running across calls so a paused stream stays honest.
        func feed(rate: Double, samples: Int, restartingAt start: TimeInterval? = nil) {
            if let start { clock = start }
            for _ in 0..<samples {
                engine.update(rotationRate: AirMouseAngularVelocity(y: rate), axes: portrait, at: clock)
                clock += step
            }
        }
    }
}
