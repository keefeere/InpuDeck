import Foundation

@main
struct ShareHandoffTests {
    static func main() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        // The text and its write time must survive the pasteboard round trip.
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

        // An older Share Extension wrote bare text with no timestamp.
        guard let legacy = ShareEnvelope.decode("s3cret") else {
            preconditionFailure("Legacy plain text must decode")
        }
        precondition(legacy.text == "s3cret" && legacy.isFresh(at: Date()),
                     "Legacy text was written moments ago, so it stays typeable")

        precondition(ShareEnvelope.decode("").map { _ in true } == nil,
                     "An empty inbox item carries nothing")
        precondition(ShareEnvelope(text: "", writtenAt: now).encoded == nil,
                     "Nothing is stored for empty text")
        precondition(ShareEnvelope(text: "Від", writtenAt: now).isFresh(at: now),
                     "Fresh text is typeable regardless of alphabet")
        precondition(ShareEnvelope(text: "{}", writtenAt: now).encoded != nil,
                     "Text that looks like JSON must still round trip as text")
        guard let braces = ShareEnvelope.decode(ShareEnvelope(text: "{}", writtenAt: now).encoded ?? "") else {
            preconditionFailure("Text shaped like JSON must decode")
        }
        precondition(braces.text == "{}" && braces.writtenAt == now,
                     "Text shaped like JSON keeps its own content, not the envelope's")

        // The handoff URL carries no text; only the route request travels it.
        guard let url = ShareHandoff.sendURL() else {
            preconditionFailure("The handoff URL must be buildable")
        }
        precondition(ShareHandoff.isSendRequest(url), "The built URL is a send request")
        // The UUID is carried as a query item, never the text.
        let pb = "test-uuid-1234"
        guard let urlWithPB = ShareHandoff.sendURL(pb: pb) else {
            preconditionFailure("The handoff URL with UUID must be buildable")
        }
        precondition(ShareHandoff.isSendRequest(urlWithPB), "The built URL is a send request")
        precondition(ShareHandoff.pasteboardUUID(from: urlWithPB) == pb,
                     "The UUID must survive the URL round trip")
        precondition(ShareHandoff.pasteboardUUID(from: url) == nil,
                     "A URL without UUID has no pasteboard UUID")
        precondition(ShareHandoff.pasteboardUUID(from: URL(string: "https://example.com/send")!) == nil,
                     "A non-send URL has no pasteboard UUID")
        precondition(ShareHandoff.isSendRequest(URL(string: "InpuDeck://SEND?x=1")!),
                     "Scheme and host are matched case-insensitively")
        precondition(!ShareHandoff.isSendRequest(URL(string: "https://example.com/send")!),
                     "Another app's URL is not a send request")
        precondition(!ShareHandoff.isSendRequest(URL(string: "inpudeck://settings")!),
                     "Only the send route consumes the inbox")
        precondition(!ShareHandoff.isSendRequest(URL(string: "inpudeck:///send")!),
                     "A missing host is not a send request")

        print("Share handoff envelope and URL checks passed.")
    }
}
