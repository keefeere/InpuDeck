import Foundation

@main
struct KeyComboParserTests {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }

    /// Tuples are not Equatable, so compare planned taps element by element.
    static func tapsEqual(
        _ a: [(modifiers: UInt8, keycode: UInt8)],
        _ b: [(UInt8, UInt8)]
    ) -> Bool {
        guard a.count == b.count else { return false }
        return zip(a, b).allSatisfy { $0.0.modifiers == $1.0 && $0.0.keycode == $1.1 }
    }

    static func main() {
        parseTests()
        plannerTests()
    }

    static func parseTests() {
        // Named key with modifiers.
        let combo = KeyComboParser.parseLine("Ctrl+Shift+Esc", lineNumber: 1)
        check(
            combo.outcome == .tap(ParsedKeyTap(modifiers: HID.modLeftCtrl | HID.modLeftShift, key: .special(keycode: 0x29))),
            "Ctrl+Shift+Esc parses to a modifier combo")

        // Case-insensitive tokens and whitespace around "+".
        let spaced = KeyComboParser.parseLine(" win + L ", lineNumber: 2)
        check(
            spaced.outcome == .tap(ParsedKeyTap(modifiers: HID.modLeftGUI, key: .character("L"))),
            "win + L parses case-insensitively with spaces and keeps letter case")

        // Function keys.
        check(
            KeyComboParser.parseLine("F5", lineNumber: 1).outcome
                == .tap(ParsedKeyTap(key: .special(keycode: HID.keyF5))),
            "F5 maps to its HID keycode")
        check(
            KeyComboParser.parseLine("f12", lineNumber: 1).outcome
                == .tap(ParsedKeyTap(key: .special(keycode: HID.keyF12))),
            "f12 maps to its HID keycode")

        // Single character line is a character tap.
        check(
            KeyComboParser.parseLine("a", lineNumber: 1).outcome
                == .tap(ParsedKeyTap(key: .character("a"))),
            "A single letter parses as a character tap")

        // Whole-line modifier becomes a keycode-0 tap with the modifier.
        check(
            KeyComboParser.parseLine("Shift", lineNumber: 1).outcome
                == .tap(ParsedKeyTap(modifiers: HID.modLeftShift, key: .special(keycode: 0))),
            "A bare modifier parses as a keycode-0 tap")

        // Right-side modifiers.
        check(
            KeyComboParser.parseLine("AltGr+E", lineNumber: 1).outcome
                == .tap(ParsedKeyTap(modifiers: HID.modRightAlt, key: .character("e"))),
            "AltGr maps to the right Alt modifier")

        // Arrows and named keys.
        check(
            KeyComboParser.parseLine("→", lineNumber: 1).outcome
                == .tap(ParsedKeyTap(key: .special(keycode: HID.keyRightArrow))),
            "Arrow glyph parses to the right arrow")
        check(
            KeyComboParser.parseLine("Enter", lineNumber: 1).outcome
                == .tap(ParsedKeyTap(key: .special(keycode: HID.keyEnter))),
            "Enter maps to its HID keycode")

        // Plain words are text.
        check(
            KeyComboParser.parseLine("hello world", lineNumber: 1).outcome == .text("hello world"),
            "A plain sentence parses as text")

        // Unknown tokens and malformed combos are errors.
        check(KeyComboParser.parseLine("Ctrl+Bogus", lineNumber: 1).isError,
              "Unknown token in a combo is an error")
        check(KeyComboParser.parseLine("Ctrl++A", lineNumber: 1).isError,
              "An empty segment in a combo is an error")
        check(KeyComboParser.parseLine("Ctrl+A+B", lineNumber: 1).isError,
              "Two keys in one combo is an error")
        check(KeyComboParser.parseLine("+", lineNumber: 1).isError,
              "A bare plus sign is an error")

        // Comments and blank lines are skipped in body parsing.
        let parses = KeyComboParser.parseBody("# comment\n\nCtrl+V\nEnter\n")
        check(parses.count == 2, "Body parsing skips comments and blanks")
        check(parses[0].line == 3, "Body parsing keeps original line numbers")
        check(!KeyComboParser.hasErrors("Ctrl+V\n# ok\n"),
              "A valid body has no errors")
        check(KeyComboParser.hasErrors("Ctrl+Bogus\n"),
              "An invalid token marks the body as having errors")
    }

    static func plannerTests() {
        let shortcut = HostLayoutShortcut.controlSpace

        // A simple combo plans to a single tap.
        let taps = KeyComboPlanner.makePlan(
            for: "Ctrl+Shift+Esc",
            startingLayout: .englishUS,
            layoutShortcut: shortcut
        ).taps
        check(tapsEqual(taps, [(HID.modLeftCtrl | HID.modLeftShift, HID.keyEscape)]),
              "A combo plans to one tap")

        // Characters are typed with layout switching for non-English letters.
        let mixed = KeyComboPlanner.makePlan(
            for: "aі",
            startingLayout: .englishUS,
            layoutShortcut: shortcut
        )
        check(mixed.taps.count >= 3, "Mixed-layout text needs a layout switch")
        check(mixed.finalLayout == .ukrainianEnhanced, "Planning ends in the Ukrainian layout")
        check(
            mixed.taps.last?.keycode == HID.mapCharacterToHID("і", layout: .ukrainianEnhanced)?.keycode,
            "The final Ukrainian letter uses the Ukrainian layout keycode"
        )

        // Text lines type each character.
        let text = KeyComboPlanner.makePlan(
            for: "hi",
            startingLayout: .englishUS,
            layoutShortcut: shortcut
        ).taps
        check(tapsEqual(text, [(0, HID.mapCharacterToHID("h", layout: .englishUS)!.keycode),
                               (0, HID.mapCharacterToHID("i", layout: .englishUS)!.keycode)]),
              "Plain text plans one tap per character")

        // Newlines type Enter; tabs type Tab.
        let tabbed = KeyComboPlanner.makePlan(
            for: "a\tb\nc",
            startingLayout: .englishUS,
            layoutShortcut: shortcut
        ).taps
        check(tabbed.contains(where: { $0.keycode == HID.keyTab }),
              "A tab character plans a Tab tap")
        check(tabbed.contains(where: { $0.keycode == HID.keyEnter }),
              "A newline plans an Enter tap")

        // Error lines are skipped, valid ones still plan.
        let partial = KeyComboPlanner.makePlan(
            for: "Ctrl+Bogus\nEnter",
            startingLayout: .englishUS,
            layoutShortcut: shortcut
        ).taps
        check(tapsEqual(partial, [(0, HID.keyEnter)]), "Invalid lines are skipped in planning")

        // Modifier-only lines plan a keycode-0 tap.
        let modifierOnly = KeyComboPlanner.makePlan(
            for: "Ctrl+Shift",
            startingLayout: .englishUS,
            layoutShortcut: shortcut
        ).taps
        check(tapsEqual(modifierOnly, [(HID.modLeftCtrl | HID.modLeftShift, 0)]),
              "A modifier-only line plans a keycode-0 tap")

        // Characters with modifiers combine the character command modifiers.
        let shiftChar = KeyComboPlanner.makePlan(
            for: "Shift+a",
            startingLayout: .englishUS,
            layoutShortcut: shortcut
        ).taps
        check(tapsEqual(shiftChar, [(HID.modLeftShift, HID.keyA)]),
              "Shift+character adds the modifier to the character tap")
    }
}
