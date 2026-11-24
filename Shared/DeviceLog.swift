import Foundation

/// Temporary device logging for the share handoff. Writes one line per
/// milestone via two sinks so the flow can be observed on the device:
/// NSLog (for the system console) and a small append-only file in the shared
/// Documents folder (for the Files app). Metadata only — never the shared
/// text, which is usually a secret. Remove this file and its call sites
/// before merging the test build.
enum DeviceLog {
    static let prefix = "[InpuDeck][share]"
    private static let maxFileLines = 1_000

    static func info(_ message: String) {
        let line = "\(formattedDate()) \(prefix) \(message)"
        NSLog("%@", line)

        guard let url = logFileURL() else { return }
        var lines = (try? String(contentsOf: url, encoding: .utf8))?.components(separatedBy: "\n") ?? [String]()
        lines.removeAll { $0.isEmpty }
        lines.append(line)
        if lines.count > maxFileLines {
            lines = Array(lines.suffix(maxFileLines))
        }
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private static func logFileURL() -> URL? {
        guard let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        return directory.appendingPathComponent("share-handoff.log")
    }

    private static func formattedDate() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Date())
    }
}
