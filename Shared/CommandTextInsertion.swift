import Foundation

/// UIKit selection ranges are UTF-16. Keep insertion/replacement safe for emoji,
/// combining characters and stale selections after text changes.
enum CommandTextInsertion {
    struct Result {
        let text: String
        let selection: NSRange
    }

    static func normalized(_ range: NSRange, in text: String) -> NSRange {
        let source = text as NSString
        let start = range.location == NSNotFound ? source.length : min(max(0, range.location), source.length)
        let length = min(max(0, range.length), source.length - start)
        if length > 0 {
            return source.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: length))
        }
        guard start < source.length else { return NSRange(location: start, length: 0) }
        let cluster = source.rangeOfComposedCharacterSequence(at: start)
        return NSRange(location: start > cluster.location ? NSMaxRange(cluster) : start, length: 0)
    }

    static func insert(
        _ snippet: String,
        into text: String,
        selection: NSRange,
        caretOffset: Int? = nil,
        standaloneLine: Bool = false
    ) -> Result {
        let source = text as NSString
        let range = normalized(selection, in: text)
        func isNewline(_ value: unichar) -> Bool { value == 10 || value == 13 }
        let prefix = standaloneLine && range.location > 0 && !isNewline(source.character(at: range.location - 1)) ? "\n" : ""
        let end = NSMaxRange(range)
        let suffix = standaloneLine && end < source.length && !isNewline(source.character(at: end)) ? "\n" : ""
        let offset = normalized(NSRange(location: caretOffset ?? snippet.utf16.count, length: 0), in: snippet).location
        return Result(
            text: source.replacingCharacters(in: range, with: prefix + snippet + suffix),
            selection: NSRange(location: range.location + prefix.utf16.count + offset, length: 0)
        )
    }
}
