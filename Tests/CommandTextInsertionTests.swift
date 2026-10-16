import Foundation

@main
struct CommandTextInsertionTests {
    static func main() {
        let middle = CommandTextInsertion.insert("<Enter>", into: "abcd", selection: NSRange(location: 2, length: 0))
        precondition(middle.text == "ab<Enter>cd")
        precondition(middle.selection == NSRange(location: 9, length: 0))
        let replaced = CommandTextInsertion.insert("<Ctrl+V>", into: "abcdef", selection: NSRange(location: 2, length: 2))
        precondition(replaced.text == "ab<Ctrl+V>ef")
        let repeated = CommandTextInsertion.insert("<Tab>", into: middle.text, selection: middle.selection)
        precondition(repeated.text == "ab<Enter><Tab>cd")

        let unicode = CommandTextInsertion.insert("X", into: "A😀B", selection: NSRange(location: 3, length: 0))
        precondition(unicode.text == "A😀XB")
        let insideEmoji = CommandTextInsertion.insert("X", into: "A😀B", selection: NSRange(location: 2, length: 0))
        precondition(insideEmoji.text == "A😀XB", "Do not split a UTF-16 surrogate pair")
        let replaceEmoji = CommandTextInsertion.insert("X", into: "A😀B", selection: NSRange(location: 2, length: 1))
        precondition(replaceEmoji.text == "AXB")
        let combining = CommandTextInsertion.insert("X", into: "e\u{301}x", selection: NSRange(location: 1, length: 0))
        precondition(combining.text == "e\u{301}Xx")
        let replaceCombining = CommandTextInsertion.insert("X", into: "e\u{301}x", selection: NSRange(location: 1, length: 1))
        precondition(replaceCombining.text == "Xx")
        let emoji = "👩🏽‍💻"
        let cluster = CommandTextInsertion.insert("X", into: emoji, selection: NSRange(location: 2, length: 2))
        precondition(cluster.text == "X")

        let stale = CommandTextInsertion.insert("X", into: "a", selection: NSRange(location: 100, length: Int.max))
        precondition(stale.text == "aX")
        let notFound = CommandTextInsertion.insert("X", into: "a", selection: NSRange(location: NSNotFound, length: 0))
        precondition(notFound.text == "aX")
        let negative = CommandTextInsertion.insert("X", into: "a", selection: NSRange(location: -1, length: -1))
        precondition(negative.text == "Xa")

        let template = CommandTextInsertion.insert("<Ctrl+>", into: "ab", selection: NSRange(location: 1, length: 0), caretOffset: 6)
        let completed = CommandTextInsertion.insert("V", into: template.text, selection: template.selection)
        precondition(completed.text == "a<Ctrl+V>b", "Modifier caret belongs before closing bracket")
        let ctrl = CommandTextInsertion.insert("<Ctrl+>", into: "ab", selection: NSRange(location: 1, length: 0),
                                               caretOffset: 6, mergeIntoMarker: true)
        let shifted = CommandTextInsertion.insert("<Shift+>", into: ctrl.text, selection: ctrl.selection,
                                                  caretOffset: 7, mergeIntoMarker: true)
        precondition(shifted.text == "a<Ctrl+Shift+>b")
        precondition(shifted.selection.location == "a<Ctrl+Shift+".utf16.count)
        let key = CommandTextInsertion.insert("<Enter>", into: shifted.text, selection: shifted.selection,
                                              mergeIntoMarker: true)
        precondition(key.text == "a<Ctrl+Shift+Enter>b", "Don't nest brackets inside an existing marker")
        let continuation = CommandTextInsertion.insert("!", into: key.text, selection: key.selection)
        precondition(continuation.text == "a<Ctrl+Shift+Enter>!b", "Completed key should leave the marker")
        let beforeKey = CommandTextInsertion.insert("<Alt+>", into: "<Ctrl+V>", selection: NSRange(location: 6, length: 0),
                                                    caretOffset: 5, mergeIntoMarker: true)
        precondition(beforeKey.text == "<Ctrl+Alt+V>")
        let replaceInner = CommandTextInsertion.insert("<Tab>", into: "<Enter>", selection: NSRange(location: 1, length: 5),
                                                       mergeIntoMarker: true)
        precondition(replaceInner.text == "<Tab>" && replaceInner.selection.location == 5)
        let replaceWhole = CommandTextInsertion.insert("<Tab>", into: "<Enter>", selection: NSRange(location: 0, length: 7),
                                                       mergeIntoMarker: true)
        precondition(replaceWhole.text == "<Tab>")
        let escaped = CommandTextInsertion.insert("<Shift+>", into: #"\<Ctrl+>"#,
            selection: NSRange(location: 7, length: 0), caretOffset: 7, mergeIntoMarker: true)
        precondition(escaped.text == #"\<Ctrl+<Shift+>>"#, "Escaped opening brackets are literal, not context")
        let unpaired = CommandTextInsertion.insert("<Shift+>", into: "<Ctrl+",
            selection: NSRange(location: 6, length: 0), caretOffset: 7, mergeIntoMarker: true)
        precondition(unpaired.text == "<Ctrl+<Shift+>", "Unpaired brackets remain literal")
        let unicodeMarker = "😀<Ctrl+>"
        let unicodeMerge = CommandTextInsertion.insert("<Alt+>", into: unicodeMarker,
            selection: NSRange(location: unicodeMarker.utf16.count - 1, length: 0),
            caretOffset: 5, mergeIntoMarker: true)
        precondition(unicodeMerge.text == "😀<Ctrl+Alt+>")
        let literalMode = CommandTextInsertion.insert("<Shift+>", into: "<Ctrl+>",
            selection: NSRange(location: 6, length: 0), caretOffset: 7)
        precondition(literalMode.text == "<Ctrl+<Shift+>>", "Text mode must not infer a marker context")

        let legacy = CommandTextInsertion.insert("Ctrl+V", into: "beforeafter", selection: NSRange(location: 6, length: 0), standaloneLine: true)
        precondition(legacy.text == "before\nCtrl+V\nafter")
        precondition(legacy.selection.location == 13)
        let alreadyLine = CommandTextInsertion.insert("Enter", into: "a\nb", selection: NSRange(location: 2, length: 0), standaloneLine: true)
        precondition(alreadyLine.text == "a\nEnter\nb")
        let all = CommandTextInsertion.insert("Enter", into: "abc", selection: NSRange(location: 0, length: 3), standaloneLine: true)
        precondition(all.text == "Enter")
        print("Cursor insertion, replacement, Unicode and legacy line tests passed.")
    }
}
