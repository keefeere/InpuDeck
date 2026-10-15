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
            parses.append(parseLine(line, lineNumber: index + 1))
        }
        return parses
    }

    /// Returns true when the body contains at least one parse error.
    static func hasErrors(_ raw: String) -> Bool {
        parseBody(raw).contains(where: \.isError)
    }

    private static func parseKeyToken(_ token: String) -> ParsedKey? {
        let lower = token.lowercased()
        if let modifier = modifierTokens[lower] {
            return .special(keycode: 0)
        }
        if let keycode = keyTokens[lower] {
            return .special(keycode: keycode)
        }
        if lower.hasPrefix("f") {
            if let number = Int(lower.dropFirst()), (1...12).contains(number) {
                return .special(keycode: UInt8(HID.keyF1 + number - 1))
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

    /// Plans the body starting from `initialLayout` (`.inferred` for fresh
    /// hosts). Lines that fail to parse are skipped.
    static func plan(_ body: String, initialLayout: KeyboardLayout = .inferred) -> [HIDCommand] {
        var commands: [HIDCommand] = []
        var current = initialLayout
        for parse in KeyComboParser.parseBody(body) {
            switch parse.outcome {
            case let .tap(tap):
                appendTap(tap, current: &current, to: &commands)
            case let .text(text):
                typeText(text, current: &current, to: &commands)
            case .unknownToken, .multipleKeys:
                continue
            }
        }
        return commands
    }

    private static func appendTap(_ tap: ParsedKeyTap, current: inout KeyboardLayout, to commands: inout [HIDCommand]) {
        switch tap.key {
        case let .special(keycode):
            guard keycode != 0 || tap.modifiers != 0 else { return }
            commands.append(HIDCommand(modifiers: tap.modifiers, keycode: keycode))
        case let .character(character):
            let layout = KeyboardLayout.inferred(for: character)
            if layout != current {
                appendLayoutSwitch(to: layout, current: &current, to: &commands)
            }
            guard let keycode = HID.mapCharacterToHID(character, layout: current) else { return }
            commands.append(HIDCommand(modifiers: tap.modifiers, keycode: keycode))
        }
    }

    private static func typeText(_ text: String, current: inout KeyboardLayout, to commands: inout [HIDCommand]) {
        for character in text where !character.isNewline {
            let layout = KeyboardLayout.inferred(for: character)
            if layout != current {
                appendLayoutSwitch(to: layout, current: &current, to: &commands)
            }
            if character == "\t" {
                commands.append(HIDCommand(modifiers: 0, keycode: 0x2B))
                continue
            }
            guard let keycode = HID.mapCharacterToHID(character, layout: current) else { continue }
            commands.append(HIDCommand(modifiers: 0, keycode: keycode))
        }
    }

    private static func appendLayoutSwitch(to layout: KeyboardLayout, current: inout KeyboardLayout, to commands: inout [HIDCommand]) {
        guard let shortcut = HID.layoutShortcuts[layout] else { return }
        for tap in shortcut.taps {
            commands.append(HIDCommand(modifiers: tap.modifiers, keycode: tap.keycode))
        }
        current = layout
    }
}
