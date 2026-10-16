import Foundation

@main
struct MixedCommandParserTests {
    static func equal(_ a: [(modifiers: UInt8, keycode: UInt8)], _ b: [(modifiers: UInt8, keycode: UInt8)]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { left, right in left.modifiers == right.modifiers && left.keycode == right.keycode }
    }

    static func plan(_ body: String) -> KeyComboPlanner.Plan {
        guard let result = MixedCommandParser.makePlan(
            for: body, startingLayout: .englishUS, layoutShortcut: .controlSpace
        ) else { preconditionFailure("Unexpected syntax error: \(body)") }
        return result
    }

    static func literal(_ body: String, _ expected: String) {
        let parses = MixedCommandParser.parseBody(body)
        precondition(!parses.contains(where: \.isError), "Literal must not have syntax errors: \(body)")
        let text = parses.map { parse -> String in
            guard case let .text(value) = parse.outcome else {
                preconditionFailure("Literal unexpectedly became a key: \(body)")
            }
            return value
        }.joined()
        precondition(text == expected, "Escaped text mismatch: \(body)")
    }

    static func main() {
        for value in ["Enter", "Entrer", "Ctrl+V", "F5", "# comment", "  Enter  ", "a\n\nb", "<", ">", "a<b", "a>b", "trailing\\", #"C:\Temp\new"#] {
            literal(value, value)
        }
        literal(#"\<Enter>"#, "<Enter>")
        literal(#"\<"#, "<")
        literal(#"\>"#, ">")
        literal(#"\\"#, #"\"#)
        literal(#"a \<Enter> b \> c \\ d C:\Temp"#, #"a <Enter> b > c \ d C:\Temp"#)
        literal("<unclosed\nEnter", "<unclosed\nEnter")
        literal("<a\\>b", "<a>b") // escaped closing bracket does not end a marker
        literal("<tag", "<tag")

        let enter = plan("<Enter>")
        precondition(enter.taps.count == 1 && enter.taps[0].keycode == HID.keyEnter)
        let ctrl = plan("<Ctrl+V>")
        precondition(ctrl.taps.count == 1 && ctrl.taps[0].modifiers == HID.modLeftCtrl && ctrl.taps[0].keycode == HID.keyV)
        for (body, modifiers, keycode): (String, UInt8, UInt8) in [
            ("<Del>", 0, 0x4C),
            ("<Delete>", 0, 0x4C),
            ("<dEl>", 0, 0x4C),
            ("<Ctrl+Alt+Del>", HID.modLeftCtrl | HID.modLeftAlt, 0x4C),
            ("<Shift+Delete>", HID.modLeftShift, 0x4C),
            ("<Backspace>", 0, 0x2A),
            ("<⌫>", 0, 0x2A),
        ] {
            let deletion = plan(body)
            precondition(deletion.taps.count == 1)
            precondition(deletion.taps[0].keycode == keycode
                         && deletion.taps[0].modifiers == modifiers,
                         "\(body) must send the exact deletion usage and modifiers")
        }
        for (name, keycode) in [
            ("Home", HID.keyHome), ("End", HID.keyEnd),
            ("PgUp", HID.keyPageUp), ("PageUp", HID.keyPageUp),
            ("PgDn", HID.keyPageDown), ("PageDown", HID.keyPageDown),
            ("Up", HID.keyUpArrow), ("Down", HID.keyDownArrow),
            ("Left", HID.keyLeftArrow), ("Right", HID.keyRightArrow),
        ] {
            let navigation = plan("<\(name)>")
            precondition(navigation.taps.count == 1 && navigation.taps[0].keycode == keycode)
        }
        for number in 1...12 {
            let function = plan("<F\(number)>")
            precondition(function.taps.count == 1 && function.taps[0].keycode == HID.keyF1 + UInt8(number - 1))
        }
        let cursorCombo = plan("<Ctrl+Shift+Right>")
        precondition(cursorCombo.taps.count == 1
                     && cursorCombo.taps[0].modifiers == HID.modLeftCtrl | HID.modLeftShift
                     && cursorCombo.taps[0].keycode == HID.keyRightArrow)
        literal("Del", "Del")
        let mixed = plan("Enter<Enter>next<Ctrl+V>")
        let plainEnter = TextTypingPlanner.makePlan(for: "Enter", startingLayout: .englishUS, layoutShortcut: .controlSpace)
        precondition(equal(Array(mixed.taps.prefix(5)), plainEnter.taps), "Bare Enter must be literal")
        precondition(mixed.taps[5].keycode == HID.keyEnter)
        precondition(mixed.taps.last?.modifiers == HID.modLeftCtrl)

        let newline = plan("a\r\n<Enter>")
        precondition(newline.taps.filter { $0.keycode == HID.keyEnter }.count == 2)
        let spaces = plan("  x  < Tab > ")
        precondition(spaces.taps.count == 7, "Do not trim ordinary text around tags")
        let symbol = plan(#"<Ctrl+\>>"#)
        precondition(symbol.taps.count == 1 && symbol.taps[0].modifiers & HID.modLeftCtrl != 0)
        let slashThenKey = plan(#"\\<Enter>"#)
        precondition(slashThenKey.taps.count == 2 && slashThenKey.taps.last?.keycode == HID.keyEnter)

        for invalid in ["<Bogus>", "<>", "<Ctrl+Bogus>", "<Ctrl+A+B>", "safe<Invalid>danger", "<<Enter>"] {
            precondition(MixedCommandParser.hasErrors(invalid))
            precondition(MixedCommandParser.makePlan(for: invalid, startingLayout: .englishUS, layoutShortcut: .controlSpace) == nil,
                         "An invalid marker must not produce a partial executable plan")
        }
        let errors = MixedCommandParser.parseBody("a\n<Bad><Wrong>")
        precondition(errors.filter(\.isError).count == 2)
        precondition(errors.filter(\.isError).allSatisfy { $0.line == 2 })

        let ua = plan("і<Enter>a")
        precondition(ua.finalLayout == .englishUS)
        precondition(ua.taps.filter { $0.modifiers == HID.modLeftCtrl && $0.keycode == HID.keySpace }.count == 2)
        precondition(plan("café").unsupportedCharacters == ["é"])

        // Escaping arbitrary printable text must round-trip without any keys.
        let ascii = String((32...126).map { Character(UnicodeScalar($0)!) })
        let escaped = ascii.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "<", with: "\\<")
            .replacingOccurrences(of: ">", with: "\\>")
        literal(escaped, ascii)
        literal(String(repeating: "<", count: 20_000), String(repeating: "<", count: 20_000))

        // Existing line-based bodies keep their historical semantics.
        let legacy = KeyComboPlanner.makePlan(for: "Enter\nCtrl+V", startingLayout: .englishUS, layoutShortcut: .controlSpace)
        precondition(legacy.taps.count == 2 && legacy.taps[0].keycode == HID.keyEnter)
        print("Mixed text/key syntax and escape tests passed.")
    }
}
