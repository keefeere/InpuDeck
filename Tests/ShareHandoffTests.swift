import Foundation

@main
struct ShareHandoffTests {
    static func main() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        // The text and its write time must survive the envelope round trip.
        let envelope = ShareEnvelope(text: "Від 1Password \nwith\rnewline", writtenAt: now)
        guard let encoded = envelope.encoded else {
            preconditionFailure("Handed text must encode")
        }
        guard let decoded = ShareEnvelope.decode(encoded) else {
            preconditionFailure("Encoded text must decode")
        }
        precondition(decoded.text == "Від 1Password \nwith\rnewline",
                     "Newlines and the alphabet must survive the envelope")
        precondition(abs(decoded.writtenAt.timeIntervalSince(now)) < 0.001,
                     "The write time must survive the envelope")
        precondition(decoded.isFresh(at: now), "Freshly handed text is typeable")

        // Expired text is dropped instead of typed into whatever is focused.
        let late = now.addingTimeInterval(ShareEnvelope.lifetime + 1)
        precondition(!decoded.isFresh(at: late), "Handed text expires with its lifetime")
        precondition(decoded.isFresh(at: now.addingTimeInterval(ShareEnvelope.lifetime - 1)),
                     "A lifetime boundary must not drop text written moments ago")

        precondition(ShareEnvelope.decode("") == nil,
                     "An empty payload carries nothing")
        precondition(ShareEnvelope(text: "", writtenAt: now).encoded == nil,
                     "Nothing is stored for empty text")
        precondition(ShareEnvelope(text: "Від", writtenAt: now).isFresh(at: now),
                     "Fresh text is typeable regardless of alphabet")

        // The URL carries the envelope as base64url — only for correct encoding.
        guard let url = ShareHandoff.sendURL(envelope: envelope) else {
            preconditionFailure("The handoff URL must be buildable")
        }
        precondition(ShareHandoff.isSendRequest(url), "The built URL is a send request")
        guard let decodedFromURL = ShareHandoff.envelope(from: url) else {
            preconditionFailure("The envelope must decode from the URL")
        }
        precondition(decodedFromURL.text == envelope.text,
                     "The text must survive the URL round trip")
        precondition(abs(decodedFromURL.writtenAt.timeIntervalSince(now)) < 0.001,
                     "The write time must survive the URL round trip")

        // Cyrillic and special characters must round trip through the URL.
        let special = ShareEnvelope(text: "пароль!@#$%^&*()_+{}|:\"<>?~`\\/", writtenAt: now)
        guard let specialURL = ShareHandoff.sendURL(envelope: special),
              let specialDecoded = ShareHandoff.envelope(from: specialURL) else {
            preconditionFailure("Special characters must round trip through the URL")
        }
        precondition(specialDecoded.text == special.text,
                     "Special characters must survive the URL round trip")

        // A URL without a payload carries no envelope.
        precondition(!ShareHandoff.isSendRequest(URL(string: "https://example.com/send")!),
                     "Another app's URL is not a send request")
        precondition(!ShareHandoff.isSendRequest(URL(string: "inpudeck://settings")!),
                     "Only the send route consumes the inbox")
        precondition(!ShareHandoff.isSendRequest(URL(string: "inpudeck:///send")!),
                     "A missing host is not a send request")
        precondition(ShareHandoff.envelope(from: URL(string: "inpudeck://send")!) == nil,
                     "A send URL without payload carries no envelope")
        precondition(ShareHandoff.envelope(from: URL(string: "inpudeck://send?d=invalid")!) == nil,
                     "An invalid payload carries no envelope")

        print("Share handoff envelope and URL checks passed.")
    }
}
