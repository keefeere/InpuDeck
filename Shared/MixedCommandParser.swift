import Foundation

/// Explicit mixed input: ordinary text is literal, <Enter>/<Ctrl+V> are taps.
/// Only \<, \> and \\ are escapes. Other backslashes (e.g. C:\Temp) survive.
/// Unpaired brackets are literal. Invalid paired key markers block execution.
enum MixedCommandParser {
    static func parseBody(_ body: String) -> [KeyLineParse] {
        let characters = Array(body)
        var results: [KeyLineParse] = []
        var text = ""
        var textLine = 1
        var token: String?
        var tokenLine = 1
        var line = 1
        var index = 0

        func appendText(_ value: String, startingLine: Int) {
            if text.isEmpty { textLine = startingLine }
            text += value
        }
        func flushText() {
            guard !text.isEmpty else { return }
            results.append(KeyLineParse(line: textLine, outcome: .text(text)))
            text = ""
        }

        // Single pass, including unmatched opening brackets; don't repeatedly
        // search the remainder of the string for each '<'.
        while index < characters.count {
            let character = characters[index]
            if character == "\\", index + 1 < characters.count {
                let next = characters[index + 1]
                if next == "<" || next == ">" || next == "\\" {
                    if token != nil {
                        token?.append(next)
                    } else {
                        appendText(String(next), startingLine: line)
                    }
                    index += 2
                    continue
                }
            }

            if token != nil {
                if character == ">" {
                    let contents = token!
                    token = nil
                    flushText()
                    let parsed = KeyComboParser.parseLine(contents, lineNumber: tokenLine)
                    switch parsed.outcome {
                    case .tap, .unknownToken, .multipleKeys:
                        results.append(parsed)
                    case .text:
                        results.append(KeyLineParse(line: tokenLine, outcome: .unknownToken(contents)))
                    }
                } else if character.isNewline {
                    // A marker cannot span lines. Preserve an unpaired '<'.
                    let contents = token!
                    token = nil
                    appendText("<" + contents + String(character), startingLine: tokenLine)
                    line += 1
                } else {
                    token?.append(character)
                }
            } else if character == "<" {
                token = ""
                tokenLine = line
            } else {
                appendText(String(character), startingLine: line)
                if character.isNewline { line += 1 }
            }
            index += 1
        }
        if let contents = token { appendText("<" + contents, startingLine: tokenLine) }
        flushText()
        return results
    }

    static func hasErrors(_ body: String) -> Bool {
        parseBody(body).contains(where: \.isError)
    }

    /// Unlike the legacy planner, never return a partial plan on a parse error.
    static func makePlan(
        for body: String,
        startingLayout: KeyboardLayout,
        layoutShortcut: HostLayoutShortcut
    ) -> KeyComboPlanner.Plan? {
        let parses = parseBody(body)
        guard !parses.contains(where: \.isError) else { return nil }
        return KeyComboPlanner.makePlan(
            parses: parses, startingLayout: startingLayout, layoutShortcut: layoutShortcut)
    }
}
