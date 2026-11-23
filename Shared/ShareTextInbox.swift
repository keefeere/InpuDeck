import UIKit

/// What the app found in the handoff inbox. `expired` is reported instead of
/// silently dropped, because typed-without-you text is exactly what the
/// lifetime guard exists to prevent.
enum ShareInboxReadout {
    case text(String)
    case expired
    case empty
}

/// A persistent named pasteboard is available to the app and its extension
/// because SideStore signs both with the same Apple team. It avoids an App
/// Group entitlement, which a free signing profile cannot provision.
enum ShareTextInbox {
    private static let pasteboardName = UIPasteboard.Name("com.keefeere.InpuDeck.shared-text")

    static func enqueue(_ text: String) -> Bool {
        guard !text.isEmpty,
              let envelope = ShareEnvelope(text: text, writtenAt: Date()).encoded,
              let pasteboard = UIPasteboard(name: pasteboardName, create: true) else {
            return false
        }
        pasteboard.setPersistent(true)
        pasteboard.string = envelope
        return true
    }

    static func take(now: Date = Date()) -> ShareInboxReadout {
        guard let pasteboard = UIPasteboard(name: pasteboardName, create: false),
              let raw = pasteboard.string,
              !raw.isEmpty else {
            return .empty
        }
        // Consumed text leaves the pasteboard and stops being persistent, so a
        // password cannot outlive the send it was written for.
        pasteboard.items = []
        pasteboard.setPersistent(false)

        guard let envelope = ShareEnvelope.decode(raw) else { return .empty }
        guard envelope.isFresh(at: now) else { return .expired }
        return .text(envelope.text)
    }
}
