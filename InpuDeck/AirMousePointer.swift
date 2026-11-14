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

/// Streams CoreMotion's fused device motion and turns it into HID pointer
/// reports.
///
/// Movement comes from the gyroscope only, read along the world's own axes: the
/// accelerometer is consulted solely to learn which way is down and where the
/// screen faces, so translation of the phone never reaches the host and the
/// pointer does not care what angle the phone is cradled at. Nothing is sent
/// while the activation hold absorbs the lift into pointing position.
///
/// One `CMDeviceMotion` stream is used on purpose: its `gravity` is already
/// fused from the accelerometer and the gyroscope by the system, and it arrives
/// with the same timestamp as the rotation rate, so the axis pair and the spin
/// being measured belong to one instant instead of two streams drifting apart.
@MainActor
final class AirMousePointer: ObservableObject {
    enum Status: Equatable {
        case off
        /// Streaming, waiting for the first gyro sample.
        case waiting
        case tracking
        /// This device has no fused motion (gyroscope plus accelerometer).
        case unavailable
        /// Streaming was started but no sample arrived, which is what a refused
        /// Motion & Fitness permission looks like.
        case blocked
    }

    @Published private(set) var status: Status = .off

    private static let motionInterval: TimeInterval = 1.0 / 120.0

    private let manager = CMMotionManager()
    private let engine = AirMouseEngine()
    private var frame = AirMousePointerFrame.flatOnTable
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

        guard manager.isDeviceMotionAvailable else {
            stopStreaming()
            status = .unavailable
            return
        }

        seedFrame()
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
        seedFrame()
        engine.begin(now: Self.now())
    }

    /// The frame the phone has before the first fused sample arrives: the
    /// upright seed gravity, not the last known frame, so a fresh activation
    /// cannot inherit an angle from a previous session.
    private func seedFrame() {
        frame = AirMouseEngine.pointerFrame(
            fromGravity: AirMouseGravityEstimator.initialGravity
        ) ?? .flatOnTable
    }

    func deactivate() {
        stopStreaming()
        engine.onPointerMove = { _, _ in }
        engine.end()
        status = .off
    }

    private func startStreaming() {
        isStreaming = true
        manager.deviceMotionUpdateInterval = Self.motionInterval
        manager.startDeviceMotionUpdates(to: .main) { [weak self] sample, _ in
            Task { @MainActor in self?.receiveMotion(sample) }
        }
    }

    private func stopStreaming() {
        guard isStreaming else { return }
        isStreaming = false
        manager.stopDeviceMotionUpdates()
    }

    private func receiveMotion(_ sample: CMDeviceMotion?) {
        guard isStreaming, let sample else { return }
        let gravity = AirMouseVector3(
            x: sample.gravity.x,
            y: sample.gravity.y,
            z: sample.gravity.z
        )
        // Gravity is handed on live even where it can name no axis. The engine
        // measures a tip as the swing between one reading and the next, so stalling
        // the reading for the samples a phone spends nearest to flat would hide the
        // very turn being made there. Only the axis is kept: a phone passing through
        // flat has no tip axis to be found in that one sample, and the pointer keeps
        // the one it last had rather than a fresh guess.
        if let found = AirMouseEngine.pointerFrame(fromGravity: gravity) {
            frame = found
        } else {
            frame = AirMousePointerFrame(
                horizontalAxis: gravity.normalized,
                verticalAxis: frame.verticalAxis
            )
        }
        guard status == .waiting || status == .tracking else { return }
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

    private static func now() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }
}
