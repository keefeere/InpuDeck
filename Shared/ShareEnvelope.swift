import Foundation

/// Text handed from the Share Extension to the main app, with the moment it was
/// written. The handoff travels through the URL query string as base64url —
/// only for correct encoding, not as a security mechanism. The lifetime bounds
/// how long abandoned text can wait.
struct ShareEnvelope {
    /// Short enough that abandoned password text is not still waiting on the
    /// next launch, long enough for a share-sheet round trip.
    static let lifetime: TimeInterval = 60

    let text: String
    let writtenAt: Date

    func isFresh(at now: Date) -> Bool {
        now.timeIntervalSince(writtenAt) < Self.lifetime
    }

    /// JSON encoded as base64url — only for correct encoding in a URL query.
    var encoded: String? {
        guard !text.isEmpty else { return nil }
        let payload = Payload(text: text, writtenAt: writtenAt.timeIntervalSince1970)
        guard let data = try? JSONEncoder().encode(payload) else { return nil }
        return data.base64URLEncodedString()
    }

    static func decode(_ raw: String) -> ShareEnvelope? {
        guard !raw.isEmpty,
              let data = Data(base64URLEncoded: raw),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            return nil
        }
        let envelope = ShareEnvelope(
            text: payload.text,
            writtenAt: Date(timeIntervalSince1970: payload.writtenAt)
        )
        return envelope.text.isEmpty ? nil : envelope
    }

    private struct Payload: Codable {
        let text: String
        let writtenAt: TimeInterval
    }
}

/// The URL the Share Extension uses to bring the app forward so the stored text
/// can actually reach the computer. Only the running app owns the Bluetooth
/// route, so the extension cannot transmit HID itself; it hands off instead.
/// The URL carries the envelope as base64url — only for correct encoding.
enum ShareHandoff {
    static let scheme = "inpudeck"
    static let sendHost = "send"

    static func sendURL(envelope: ShareEnvelope) -> URL? {
        guard let encoded = envelope.encoded else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = sendHost
        components.queryItems = [URLQueryItem(name: "d", value: encoded)]
        return components.url
    }

    static func isSendRequest(_ url: URL) -> Bool {
        url.scheme?.lowercased() == scheme && url.host?.lowercased() == sendHost
    }

    /// Extracts and decodes the envelope from a handoff URL.
    static func envelope(from url: URL) -> ShareEnvelope? {
        guard isSendRequest(url),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems,
              let raw = items.first(where: { $0.name == "d" })?.value else { return nil }
        return ShareEnvelope.decode(raw)
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        self.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded string: String) {
        let padded = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = padded.count % 4
        let padded2 = remainder == 0 ? padded : padded + String(repeating: "=", count: 4 - remainder)
        self.init(base64Encoded: padded2)
    }
}
