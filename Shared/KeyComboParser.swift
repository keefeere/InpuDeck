import Foundation

/// One parsed key in a commandlet "keys" line. Special keys carry their HID
/// keycode directly; characters are resolved against a keyboard layout when
/// the body is planned into taps.
enum ParsedKey: Equatable, Sendable {
    case special(keycode: UInt8)
    case character(Character)
}

/// A single parsed key tap: modifier mask plus one key.
struct ParsedKeyTap: Equatable, Sendable {
    var modifiers: UInt8 = 0
    var key: ParsedKey
}

/// The result of parsing one line of a commandlet body in "keys" syntax.
enum KeyLineOutcome: Equatable, Sendable {
    case tap(ParsedKeyTap)
    case text(String)
    case unknownToken(String)
    case multipleKeys
}

struct KeyLineParse: Equatable, Sendable {
    var line: Int
    var outcome: KeyLineOutcome

    var isError: Bool {
        switch outcome {
        case .tap, .text: return false
        case .unknownToken, .multipleKeys: return true
        }
    }
}

/// Parses commandlet "keys" bodies. Each non-empty line that is not a `#`
/// comment becomes either a key tap (`Ctrl+Shift+Esc`, `F5`, `a`) or plain
/// text to be typed character by character.
enum KeyComboParser {

    /// Modifier names (case-insensitive) mapped to HID modifier bits.
    private static let modifierTokens: [String: UInt8] = [
        "ctrl": HID.modLeftCtrl, "control": HID.modLeftCtrl, "ктр": HID.modLeftCtrl,
        "rctrl": HID.modRightCtrl, "rightctrl": HID.modRightCtrl,
        "shift": HID.modLeftShift, "⇧": HID.modLeftShift,
        "rshift": HID.modRightShift, "rightshift": HID.modRightShift,
        "alt": HID.modLeftAlt, "option": HID.modLeftAlt,
        "ralt": HID.modRightAlt, "rightalt": HID.modRightAlt, "altgr": HID.modRightAlt,
        "win": HID.modLeftGUI, "cmd": HID.modLeftGUI, "command": HID.modLeftGUI,
        "super": HID.modLeftGUI, "meta": HID.modLeftGUI, "⌘": HID.modLeftGUI,
        "rwin": HID.modRightGUI, "rightwin": HID.modRightGUI,
    ]

    /// Named keys (case-insensitive) mapped to the project's HID keycodes.
    private static let keyTokens: [String: UInt8] = [
        "tab": HID.keyTab,
        "enter": HID.keyEnter, "return": HID.keyEnter,
        "esc": HID.keyEscape, "escape": HID.keyEscape,
        "space": HID.keySpace,
        "backspace": HID.keyBackspace, "del": HID.keyBackspace, "⌫": HID.keyBackspace,
        "delete": HID.keyDelete, "fwdel": HID.keyDelete, "forwarddelete": HID.keyDelete,
        "home": HID.keyHome,
        "end": HID.keyEnd,
        "pageup": HID.keyPageUp, "pgup": HID.keyPageUp,
        "pagedown": HID.keyPageDown, "pgdn": HID.keyPageDown,
        "insert": HID.keyInsert, "ins": HID.keyInsert,
        "printscreen": HID.keyPrintScreen, "prtscn": HID.keyPrintScreen, "prtsc": HID.keyPrintScreen,
        "pause": HID.keyPause,
        "scrolllock": HID.keyScrollLock,
        "left": HID.keyLeftArrow, "←": HID.keyLeftArrow,
        "right": HID.keyRightArrow, "→": HID.keyRightArrow,
        "up": HID.keyUpArrow, "↑": HID.keyUpArrow,
        "down": HID.keyDownArrow, "↓": HID.keyDownArrow,
    ]

    /// Parses one line. `lineNumber` is 1-based and used in results.
    static func parseLine(_ raw: String, lineNumber: Int) -> KeyLineParse {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else {
            return KeyLineParse(line: lineNumber, outcome: .text(""))
        }

        // A combo is made of "+"-separated tokens; allow spaces around "+".
        if line.contains("+") {
            let segments = line.split(separator: "+", omittingEmptySubsequences: false).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard !segments.contains(where: { $0.isEmpty }) else {
                return KeyLineParse(line: lineNumber, outcome: .unknownToken(line))
            }
            var modifiers: UInt8 = 0
            var key: ParsedKey?
            for segment in segments {
                let token = segment.lowercased()
                if let modifier = modifierTokens[token] {
                    modifiers |= modifier
                } else if let parsed = parseKeyToken(segment) {
                    guard key == nil else {
                        return KeyLineParse(line: lineNumber, outcome: .multipleKeys)
                    }
                    key = parsed
                } else {
                    return KeyLineParse(line: lineNumber, outcome: .unknownToken(segment))
                }
            }
            if let key {
                return KeyLineParse(line: lineNumber, outcome: .tap(ParsedKeyTap(modifiers: modifiers, key: key)))
            }
            // Modifier-only combo (e.g. "Ctrl+Shift") is a valid tap with
            // keycode 0, the same shape HostLayoutShortcut uses.
            return KeyLineParse(line: lineNumber, outcome: .tap(ParsedKeyTap(modifiers: modifiers, key: .special(keycode: 0))))
        }

        // A single whole-line token may be a named key or one character.
        if !line.contains(where: { $0.isWhitespace }) {
            let token = line.lowercased()
            if let modifier = modifierTokens[token] {
                return KeyLineParse(line: lineNumber, outcome: .tap(ParsedKeyTap(modifiers: modifier, key: .special(keycode: 0))))
            }
            if let parsed = parseKeyToken(line) {
                return KeyLineParse(line: lineNumber, outcome: .tap(ParsedKeyTap(key: parsed)))
            }
        }

        // Anything else is typed as plain text.
        return KeyLineParse(line: lineNumber, outcome: .text(line))
    }

    /// Parses a whole body into per-line results, skipping blanks and `#`
    /// comments.
    static func parseBody(_ raw: String) -> [KeyLineParse] {
        var parses: [KeyLineParse] = []
        for (index, line) in raw.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            parses.append(parseLine(String(line), lineNumber: index + 1))
        }
        return parses
    }

    /// Returns true when the body contains at least one parse error.
    static func hasErrors(_ raw: String) -> Bool {
        parseBody(raw).contains(where: \.isError)
    }

    private static func parseKeyToken(_ token: String) -> ParsedKey? {
        let lower = token.lowercased()
        if modifierTokens[lower] != nil {
            return .special(keycode: 0)
        }
        if let keycode = keyTokens[lower] {
            return .special(keycode: keycode)
        }
        if lower.hasPrefix("f") {
            if let number = Int(lower.dropFirst()), (1...12).contains(number) {
                return .special(keycode: HID.keyF1 + UInt8(number - 1))
            }
        }
        if token.count == 1, let character = token.first {
            return .character(character)
        }
        return nil
    }
}

/// Plans a parsed "keys" body into the HID taps that
/// `RemoteInputController.sendKeyTaps` consumes. Characters are typed with
/// automatic layout switching, mirroring `TextTypingPlanner`.
enum KeyComboPlanner {

    /// The planned taps plus the layout left active after planning and the
    /// characters that have no HID key on either layout.
    struct Plan {
        var taps: [(modifiers: UInt8, keycode: UInt8)]
        var finalLayout: KeyboardLayout
        var unsupportedCharacters: [Character]
    }

    /// Plans the body starting from `startingLayout`. Layout switches use
    /// `layoutShortcut`, the same setting the text input tab uses. Lines that
    /// fail to parse are skipped.
    static func makePlan(
        for body: String,
        startingLayout: KeyboardLayout,
        layoutShortcut: HostLayoutShortcut
    ) -> Plan {
        var taps: [(modifiers: UInt8, keycode: UInt8)] = []
        var unsupported: [Character] = []
        var current = startingLayout
        let shortcut = layoutShortcut.command

        for parse in KeyComboParser.parseBody(body) {
            switch parse.outcome {
            case let .tap(tap):
                appendTap(tap, current: &current, to: &taps, shortcut: shortcut, unsupported: &unsupported)
            case let .text(text):
                typeText(text, current: &current, to: &taps, shortcut: shortcut, unsupported: &unsupported)
            case .unknownToken, .multipleKeys:
                continue
            }
        }
        return Plan(taps: taps, finalLayout: current, unsupportedCharacters: unsupported)
    }

    private static func appendTap(
        _ tap: ParsedKeyTap,
        current: inout KeyboardLayout,
        to taps: inout [(modifiers: UInt8, keycode: UInt8)],
        shortcut: HIDCommand,
        unsupported: inout [Character]
    ) {
        switch tap.key {
        case let .special(keycode):
            guard keycode != 0 || tap.modifiers != 0 else { return }
            taps.append((tap.modifiers, keycode))
        case let .character(character):
            if let layout = KeyboardLayout.inferred(from: character), layout != current {
                appendLayoutSwitch(shortcut: shortcut, to: layout, current: &current, to: &taps)
            }
            guard let command = HID.mapCharacterToHID(character, layout: current) else {
                unsupported.append(character)
                return
            }
            taps.append((tap.modifiers | command.modifiers, command.keycode))
        }
    }

    private static func typeText(
        _ text: String,
        current: inout KeyboardLayout,
        to taps: inout [(modifiers: UInt8, keycode: UInt8)],
        shortcut: HIDCommand,
        unsupported: inout [Character]
    ) {
        for character in text {
            if character.isNewline {
                taps.append((0, HID.keyEnter))
                continue
            }
            if character == "\t" {
                taps.append((0, HID.keyTab))
                continue
            }
            if let layout = KeyboardLayout.inferred(from: character), layout != current {
                appendLayoutSwitch(shortcut: shortcut, to: layout, current: &current, to: &taps)
            }
            guard let command = HID.mapCharacterToHID(character, layout: current) else {
                unsupported.append(character)
                continue
            }
            taps.append((command.modifiers, command.keycode))
        }
    }

    private static func appendLayoutSwitch(
        shortcut: HIDCommand,
        to layout: KeyboardLayout,
        current: inout KeyboardLayout,
        to taps: inout [(modifiers: UInt8, keycode: UInt8)]
    ) {
        taps.append((shortcut.modifiers, shortcut.keycode))
        current = layout
    }
}
