import UIKit

/// What the Share Extension reported back to the app. The extension writes a
/// one-shot result to a shared persistent pasteboard right before closing;
/// the app reads, logs and drops it so a failure is visible instead of a
/// silent no-op. The payload carries no secret text — only the outcome.
struct ShareResult {
    let status: Status
    let length: Int?

    enum Status: String {
        case ok
        case noText
        case tooLong
        case enqueueFailed
    }

    static let pasteboardName = UIPasteboard.Name("com.keefeere.InpuDeck.share-result")

    static func write(status: Status, length: Int? = nil) {
        let payload = Payload(status: status.rawValue, length: length)
        guard let data = try? JSONEncoder().encode(payload),
              let raw = String(data: data, encoding: .utf8),
              let pasteboard = UIPasteboard(name: pasteboardName, create: true) else {
            return
        }
        pasteboard.setPersistent(true)
        pasteboard.string = raw
    }

    static func take() -> ShareResult? {
        guard let pasteboard = UIPasteboard(name: pasteboardName, create: false),
              let raw = pasteboard.string,
              !raw.isEmpty,
              let data = raw.data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              let status = Status(rawValue: payload.status) else {
            return nil
        }
        pasteboard.items = []
        pasteboard.setPersistent(false)
        return ShareResult(status: status, length: payload.length)
    }

    private struct Payload: Codable {
        let status: String
        let length: Int?
    }
}
