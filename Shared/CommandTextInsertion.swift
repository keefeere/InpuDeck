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
        standaloneLine: Bool = false,
        mergeIntoMarker: Bool = false
    ) -> Result {
        let source = text as NSString
        let range = normalized(selection, in: text)
        var inserted = snippet
        var requestedOffset = caretOffset
        var closingMarker: Int?
        let inner = String(snippet.dropFirst().dropLast())
        if mergeIntoMarker, !standaloneLine, snippet.hasPrefix("<"), snippet.hasSuffix(">"),
           !inner.contains("<"), !inner.contains(">"),
           let closing = enclosingMarkerEnd(range, in: text) {
            inserted = inner
            requestedOffset = caretOffset.map { max(0, $0 - 1) }
            closingMarker = closing
        }
        func isNewline(_ value: unichar) -> Bool { value == 10 || value == 13 }
        let prefix = standaloneLine && range.location > 0 && !isNewline(source.character(at: range.location - 1)) ? "\n" : ""
        let end = NSMaxRange(range)
        let suffix = standaloneLine && end < source.length && !isNewline(source.character(at: end)) ? "\n" : ""
        let offset = normalized(NSRange(location: requestedOffset ?? inserted.utf16.count, length: 0), in: inserted).location
        // A completed key at the marker's end leaves the caret after '>'.
        // Modifier templates keep it inside for the next modifier/key.
        let afterClosing = closingMarker == NSMaxRange(range) && closingMarker != nil && caretOffset == nil ? 1 : 0
        return Result(
            text: source.replacingCharacters(in: range, with: prefix + inserted + suffix),
            selection: NSRange(location: range.location + prefix.utf16.count + offset + afterClosing, length: 0)
        )
    }

    /// Find a paired, unescaped, single-line marker containing the whole
    /// selection. Escaped brackets and malformed nested markers aren't syntax.
    private static func enclosingMarkerEnd(_ range: NSRange, in text: String) -> Int? {
        let characters = Array(text)
        var opening: Int?
        var nested = false
        var index = 0
        var offset = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\\", index + 1 < characters.count {
                let next = characters[index + 1]
                if next == "<" || next == ">" || next == "\\" {
                    offset += 2
                    index += 2
                    continue
                }
            }
            if character.isNewline {
                opening = nil
                nested = false
            } else if character == "<" {
                if opening == nil { opening = offset } else { nested = true }
            } else if character == ">" {
                if let start = opening, !nested, range.location > start, NSMaxRange(range) <= offset {
                    return offset
                }
                opening = nil
                nested = false
            }
            offset += String(character).utf16.count
            index += 1
        }
        return nil
    }
}
