import Foundation

/// Temporary device logging for the share handoff. Writes one line per
/// milestone via NSLog so the flow can be observed on the device from the
/// console. Metadata only — never the shared text, which is usually a secret.
/// Remove this file and its call sites before merging the test build.
enum DeviceLog {
    static let prefix = "[InpuDeck][share]"

    static func info(_ message: String) {
        NSLog("%@ %@", prefix, message)
    }
}
