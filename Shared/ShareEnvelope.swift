import Foundation

/// Text handed from the Share Extension to the main app, with the moment it was
/// written. The handoff travels through a persistent named pasteboard, so a
/// password would otherwise wait there indefinitely and could be typed into
/// whatever is focused hours later. The lifetime bounds that.
struct ShareEnvelope {
    /// Long enough for a share-sheet round trip and for the app to come back to
    /// the foreground, short enough that abandoned password text is not still
    /// waiting on the next launch.
    static let lifetime: TimeInterval = 15 * 60

    let text: String
    let writtenAt: Date

    func isFresh(at now: Date) -> Bool {
        now.timeIntervalSince(writtenAt) < Self.lifetime
    }

    /// JSON instead of a bare string, because the write time has to travel with
    /// the text through a pasteboard that only carries items.
    var encoded: String? {
        guard !text.isEmpty else { return nil }
        let payload = Payload(text: text, writtenAt: writtenAt.timeIntervalSince1970)
        guard let data = try? JSONEncoder().encode(payload) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decode(_ raw: String) -> ShareEnvelope? {
        guard !raw.isEmpty else { return nil }
        if let data = raw.data(using: .utf8),
           let payload = try? JSONDecoder().decode(Payload.self, from: data) {
            let envelope = ShareEnvelope(
                text: payload.text,
                writtenAt: Date(timeIntervalSince1970: payload.writtenAt)
            )
            return envelope.text.isEmpty ? nil : envelope
        }
        // Text left by an older Share Extension carries no timestamp. It was
        // written moments ago, which is the only reading that keeps it typeable.
        return ShareEnvelope(text: raw, writtenAt: Date())
    }

    private struct Payload: Codable {
        let text: String
        let writtenAt: TimeInterval
    }
}

/// The URL the Share Extension uses to bring the app forward so the stored text
/// can actually reach the computer. Only the running app owns the Bluetooth
/// route, so the extension cannot transmit HID itself; it hands off instead.
/// The URL carries no text — the secret stays in the pasteboard.
enum ShareHandoff {
    static let scheme = "inpudeck"
    static let sendHost = "send"

    static var sendURL: URL? { URL(string: "\(scheme)://\(sendHost)") }

    static func isSendRequest(_ url: URL) -> Bool {
        url.scheme?.lowercased() == scheme && url.host?.lowercased() == sendHost
    }
}
