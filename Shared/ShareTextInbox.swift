import UIKit

/// What the app found in the handoff inbox. `expired` is reported instead of
/// silently dropped, because typed-without-you text is exactly what the
/// lifetime guard exists to prevent.
enum ShareInboxReadout {
    case text(String)
    case expired
    case empty
}

/// A named pasteboard is available to the app and its extension because SideStore
/// signs both with the same Apple team. It avoids an App Group entitlement,
/// which a free signing profile cannot provision.
///
/// Each transfer writes to a uniquely-named pasteboard (`...shared-text.<UUID>`)
/// so a live app never reads a stale or cached fixed pasteboard. The URL the
/// extension passes to the app carries the UUID; the app opens the pasteboard
/// by that name, reads the envelope, and deletes it.
enum ShareTextInbox {
    private static let fixedPasteboardName = UIPasteboard.Name("com.keefeere.InpuDeck.shared-text")

    /// Encodes the text and writes it to a unique pasteboard. Returns the UUID
    /// identifying the pasteboard, or nil on failure.
    static func enqueue(_ text: String) -> String? {
        guard !text.isEmpty,
              let envelope = ShareEnvelope(text: text, writtenAt: Date()).encoded else {
            return nil
        }
        let uuid = UUID().uuidString
        let name = UIPasteboard.Name("com.keefeere.InpuDeck.shared-text.\(uuid)")
        guard let pasteboard = UIPasteboard(name: name, create: true) else {
            return nil
        }
        pasteboard.string = envelope
        return uuid
    }

    /// Reads the text from the unique pasteboard identified by `uuid`. When
    /// `uuid` is nil, falls back to the fixed inbox (legacy handoff).
    static func take(_ uuid: String?, now: Date = Date()) -> ShareInboxReadout {
        let name: UIPasteboard.Name
        if let uuid, !uuid.isEmpty {
            name = UIPasteboard.Name("com.keefeere.InpuDeck.shared-text.\(uuid)")
        } else {
            name = fixedPasteboardName
        }
        guard let pasteboard = UIPasteboard(name: name, create: false),
              let raw = pasteboard.string,
              !raw.isEmpty else {
            return .empty
        }
        // Consumed text leaves the pasteboard so a password cannot outlive
        // the send it was written for.
        pasteboard.items = []
        if uuid != nil {
            UIPasteboard.remove(withName: name)
        }

        guard let envelope = ShareEnvelope.decode(raw) else { return .empty }
        guard envelope.isFresh(at: now) else { return .expired }
        return .text(envelope.text)
    }
}
