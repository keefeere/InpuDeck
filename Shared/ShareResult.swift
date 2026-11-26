import UIKit

/// What the Share Extension reported back to the app. The extension writes a
/// one-shot result to a shared persistent pasteboard right before closing;
/// the app reads, logs and drops it so a failure is visible instead of a
/// silent no-op. The payload carries no secret text — only the outcome.
struct ShareResult {
    let status: Status
    let length: Int?
    /// Whether the app was opened via the URL handoff. Only meaningful when
    /// status is .ok — a failure path never reaches the handoff.
    let opened: Bool?
    /// Whether the UIApplication object was found in the responder chain.
    /// When false, the handoff was never attempted and the app must be opened
    /// manually.
    let foundUIApplication: Bool?

    enum Status: String {
        case ok
        case noText
        case tooLong
        case enqueueFailed
    }

    static let pasteboardName = UIPasteboard.Name("com.keefeere.InpuDeck.share-result")

    static func write(status: Status, length: Int? = nil, opened: Bool? = nil, foundUIApplication: Bool? = nil) {
        let payload = Payload(status: status.rawValue, length: length, opened: opened, foundUIApplication: foundUIApplication)
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
        return ShareResult(status: status, length: payload.length, opened: payload.opened, foundUIApplication: payload.foundUIApplication)
    }

    private struct Payload: Codable {
        let status: String
        let length: Int?
        let opened: Bool?
        let foundUIApplication: Bool?
    }
}
