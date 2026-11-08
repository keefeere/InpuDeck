import Combine
import CoreMotion
import Foundation

/// Pointer surface shown on the input screen.
enum PointerSurface: String, CaseIterable, Identifiable {
    case trackpad
    case airMouse

    var id: String { rawValue }

    var title: String {
        localized(self == .trackpad ? "Тачпад" : "Air mouse")
    }
}

/// Streams the gyroscope and the accelerometer and turns them into HID pointer
/// reports.
///
/// Movement comes from the gyroscope only, read along the world's own axes: the
/// accelerometer is consulted solely to learn which way is down and where the
/// screen faces, so translation of the phone never reaches the host and the
/// pointer does not care what angle the phone is cradled at. Nothing is sent
/// while the activation hold absorbs the lift into pointing position.
@MainActor
final class AirMousePointer: ObservableObject {
    enum Status: Equatable {
        case off
        /// Streaming, waiting for the first gyro sample.
        case waiting
        case tracking
        /// This device has no gyroscope.
        case unavailable
        /// Streaming was started but no sample arrived, which is what a refused
        /// Motion & Fitness permission looks like.
        case blocked
    }

    @Published private(set) var status: Status = .off

    private static let gyroInterval: TimeInterval = 1.0 / 60.0
    /// Gravity changes slowly, so the accelerometer is sampled far below the
    /// gyroscope rate and still tracks a deliberate turn.
    private static let accelerometerInterval: TimeInterval = 1.0 / 20.0

    private let manager = CMMotionManager()
    private let engine = AirMouseEngine()
    private var gravity = AirMouseGravityEstimator()
    private var frame = AirMousePointerFrame.flatOnTable
    private var lastAccelerometerAt: TimeInterval?
    private var isStreaming = false
    /// Invalidated by every activation, so an older wait cannot overwrite a newer
    /// state or stop a stream that has already produced samples.
    private var waitingToken = 0

    var isTracking: Bool { status == .tracking }

    /// Start pointing. Calling it again with a new configuration keeps the stream
    /// and only restarts the activation hold, so switching surfaces recentres.
    func activate(
        config: AirMouseEngine.Config,
        sendingReportsTo report: @escaping (Int8, Int8) -> Void
    ) {
        // The engine delivers on the queue its samples arrive on, so the reports
        // leave on the sample's own path rather than a queued hop behind it.
        engine.onPointerMove = { dx, dy in report(dx, dy) }
        engine.config = config

        guard manager.isGyroAvailable else {
            stopStreaming()
            status = .unavailable
            return
        }

        gravity.reset()
        lastAccelerometerAt = nil
        engine.begin(now: Self.now())

        if !isStreaming {
            startStreaming()
        }
        status = .waiting
        scheduleBlockedCheck()
    }

    /// iOS shows the Motion & Fitness prompt on first use and never asks again, so
    /// a refused permission is only visible as a stream that stays silent. Say so
    /// instead of leaving the pad waiting forever.
    private func scheduleBlockedCheck() {
        waitingToken += 1
        let token = waitingToken
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, self.waitingToken == token, self.status == .waiting else { return }
            self.stopStreaming()
            self.engine.end()
            self.status = .blocked
        }
    }

    /// Apply sensitivity, dead zone or inversion while pointing.
    func updateConfig(_ config: AirMouseEngine.Config) {
        engine.config = config
    }

    /// Drop whatever the filters are holding on to, so the pointer starts from
    /// nothing where the phone currently is.
    func recentre() {
        guard status == .tracking || status == .waiting else { return }
        gravity.reset()
        lastAccelerometerAt = nil
        engine.begin(now: Self.now())
    }

    func deactivate() {
        stopStreaming()
        engine.onPointerMove = { _, _ in }
        engine.end()
        status = .off
    }

    private func startStreaming() {
        isStreaming = true
        manager.gyroUpdateInterval = Self.gyroInterval
        manager.accelerometerUpdateInterval = Self.accelerometerInterval

        manager.startGyroUpdates(to: .main) { [weak self] sample, _ in
            Task { @MainActor in self?.receiveGyro(sample) }
        }
        manager.startAccelerometerUpdates(to: .main) { [weak self] sample, _ in
            Task { @MainActor in self?.receiveAccelerometer(sample) }
        }
    }

    private func stopStreaming() {
        guard isStreaming else { return }
        isStreaming = false
        manager.stopGyroUpdates()
        manager.stopAccelerometerUpdates()
    }

    private func receiveGyro(_ sample: CMGyroData?) {
        guard isStreaming else { return }
        guard status == .waiting || status == .tracking else { return }
        guard let sample else { return }
        if status == .waiting {
            status = .tracking
            waitingToken += 1
        }
        engine.update(
            rotationRate: AirMouseAngularVelocity(
                x: sample.rotationRate.x,
                y: sample.rotationRate.y,
                z: sample.rotationRate.z
            ),
            frame: frame,
            at: Self.now()
        )
    }

    private func receiveAccelerometer(_ sample: CMAccelerometerData?) {
        guard isStreaming, let sample else { return }
        let now = Self.now()
        // The first sample of a stream has no previous one to measure against;
        // assume the configured rate rather than zero, which the estimator would
        // simply drop.
        let dt = lastAccelerometerAt.map { now - $0 } ?? Self.accelerometerInterval
        lastAccelerometerAt = now

        let estimate = gravity.addSample(
            AirMouseVector3(x: sample.acceleration.x, y: sample.acceleration.y, z: sample.acceleration.z),
            dt: dt
        )
        frame = AirMouseEngine.pointerFrame(
            fromGravity: estimate,
            minimumHorizontalNormal: engine.config.minimumHorizontalNormal
        )
    }

    private static func now() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }
}
