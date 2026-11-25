import Foundation

/// The template format for the TV remote screen. Design: docs/tv-remote.md.
///
/// This file is pure data: no SwiftUI, no Bluetooth, no UserDefaults. The
/// bundled template is parsed by the same `decode` the app uses, so a format
/// bug is caught by a unit test instead of on the maintainer's sofa.
enum RemoteControl: String, Codable, CaseIterable {
    /// One labelled key.
    case button
    /// Four directions plus a centre, drawn as one cell.
    case dpad
    /// Two halves along the cell's longer axis.
    case rocker
    /// A labelled gap that sends nothing.
    case spacer
}

/// v1 sends keys and Consumer usages only. Text is deliberately absent: typing
/// needs the host-layout state the Input tab owns (`TextTypingPlanner`), and a
/// kind added later is additive, so carrying an unusable one now buys nothing.
enum RemoteActionKind: String, Codable, CaseIterable {
    case key
    case consumer
    case none
}

enum RemoteTone: String, Codable {
    case plain
    case prominent
}

/// Whether releasing the control ends the report. `tap` sends down-then-up;
/// `hold` keeps the report down until release and relies on the host's own
/// autorepeat (there is no app-side repeat timer, by design).
enum RemotePress: String, Codable {
    case tap
    case hold
}

/// A named slot inside a multi-action control.
enum RemoteRole: String, Codable {
    case up, down, left, right, center, primary, secondary
}

/// A label for a cell or a role slot. Two forms:
/// - plain string: the localization key (Ukrainian source text, translated
///   by the app's localization table), or
/// - an object `{"uk": "...", "en": "..."}`: explicit per-language values,
///   resolved by the renderer against the current app locale.
struct RemoteLabel: Equatable {
    /// Plain-string form: the localization key.
    let key: String
    /// Explicit per-language form from an imported template.
    let byLanguage: [String: String]?

    init(_ text: String) {
        self.key = text
        self.byLanguage = nil
    }

    init(byLanguage: [String: String]) {
        self.key = ""
        self.byLanguage = byLanguage
    }

    var isEmpty: Bool {
        if let byLanguage { return byLanguage.values.allSatisfy { $0.isEmpty } }
        return key.isEmpty
    }

    /// The text to draw for the app locale identified by `localeIdentifier`
    /// (e.g. "uk", "en_US", "uk_UA"). Exact match, then the language prefix,
    /// then English, then Ukrainian; a plain key falls back to the app's
    /// localization table.
    func resolvedText(for localeIdentifier: String) -> String {
        guard let byLanguage else { return localized(key) }
        let id = localeIdentifier.lowercased()
        let short = String(id.prefix(2))
        return byLanguage[id] ?? byLanguage[short] ?? byLanguage["en"] ?? byLanguage["uk"] ?? ""
    }
}

/// A slot's action plus the text drawn on it. Rocker halves and the dpad centre
/// need their own labels, because an action cannot say "Гучність +" by itself.
struct RemoteRoleAction: Equatable {
    let action: RemoteAction
    /// Resolved at render time; empty means the renderer falls back to a glyph.
    let label: RemoteLabel
}

/// A validated action. Every field is resolved, so the renderer never has to
/// guess a usage or keycode.
struct RemoteAction: Equatable {
    let kind: RemoteActionKind
    /// Resolved HID keycode for `.key`.
    let keycode: UInt8?
    let modifiers: UInt8
    /// Resolved Consumer usage for `.consumer`.
    let usage: UInt16?
    /// Reserved: no v1 action carries text (see `RemoteActionKind`).
    let text: String

    static let none = RemoteAction(kind: .none, keycode: nil, modifiers: 0, usage: nil, text: "")

    static func key(_ keycode: UInt8, modifiers: UInt8 = 0) -> RemoteAction {
        RemoteAction(kind: .key, keycode: keycode, modifiers: modifiers, usage: nil, text: "")
    }

    static func consumer(_ usage: UInt16) -> RemoteAction {
        RemoteAction(kind: .consumer, keycode: nil, modifiers: 0, usage: usage, text: "")
    }
}

/// A validated control on the remote grid.
struct RemoteCell: Equatable {
    let id: String
    /// 1-based grid coordinates.
    let row: Int
    let col: Int
    let rowSpan: Int
    let colSpan: Int
    let control: RemoteControl
    /// Empty means the key button renders nothing but its action glyph.
    let label: RemoteLabel
    let tone: RemoteTone
    let press: RemotePress
    /// The single action of a `button`/`spacer`.
    let action: RemoteAction
    /// Actions of `dpad` and `rocker`, keyed by role.
    /// Actions and labels of `dpad` and `rocker`, keyed by role.
    let roles: [RemoteRole: RemoteRoleAction]
    /// Rockers split along the longer axis of the cell.
    var rockerIsHorizontal: Bool { colSpan >= rowSpan }
    /// Visual scale of the control inside its cell. 1.0 fills the cell.
    let scale: Double
    /// Multiplier applied to the label font size. 1.0 leaves the default.
    let fontScale: Double

    init(id: String, row: Int, col: Int, rowSpan: Int, colSpan: Int, control: RemoteControl,
         label: RemoteLabel, tone: RemoteTone, press: RemotePress, action: RemoteAction,
         roles: [RemoteRole: RemoteRoleAction], scale: Double = 1.0, fontScale: Double = 1.0) {
        self.id = id
        self.row = row
        self.col = col
        self.rowSpan = rowSpan
        self.colSpan = colSpan
        self.control = control
        self.label = label
        self.tone = tone
        self.press = press
        self.action = action
        self.roles = roles
        self.scale = scale
        self.fontScale = fontScale
    }
}

struct RemoteTemplate: Equatable {
    static let currentFormatVersion = 1
    /// Matches the shipped resource; see `RemoteTemplate.defaultTemplate`.
    static let defaultId = "tv-default"

    let formatVersion: Int
    let id: String
    let name: String
    let columns: Int
    let rows: Int
    let cells: [RemoteCell]

    /// The one shipped template. Its labels are localization keys
    /// (`Shared/Localization.swift`), so Ukrainian text is the key and English
    /// comes from `en.lproj`.
    static let defaultTemplate = RemoteTemplate(
        formatVersion: 1,
        id: defaultId,
        name: "TV",
        columns: 4,
        rows: 5,
        cells: [
            // Mirrors the maintainer's requests and the codes the C1 actually
            // acted on (docs/tv-remote.md): consumer volume / mute / menu / exit,
            // keyboard arrows and Enter, keyboard Win for Home, consumer 0x01A4
            // for Back. Guide is dropped because the maintainer does not use it;
            // Consumer Select, Home, Back and Play-pause were ignored by the TV,
            // so they are not in this template.
            RemoteCell(id: "mute", row: 1, col: 1, rowSpan: 1, colSpan: 1, control: .button,
                       label: RemoteLabel("Тиша"), tone: .plain, press: .tap, action: .consumer(RemoteUsageId.mute), roles: [:]),
            RemoteCell(id: "home", row: 1, col: 2, rowSpan: 1, colSpan: 1, control: .button,
                       label: RemoteLabel("Додому"), tone: .prominent, press: .tap, action: .key(0, modifiers: HID.modLeftGUI), roles: [:]),
            RemoteCell(id: "menu", row: 1, col: 3, rowSpan: 1, colSpan: 1, control: .button,
                       label: RemoteLabel("Меню"), tone: .plain, press: .tap, action: .consumer(RemoteUsageId.menu), roles: [:]),
            // Verified on the C1 with 3.6.13: consumer 0x0082 is what Linux
            // turns into KEY_VIDEO_NEXT, listed as TV_VIDEO (241) in the LG
            // input-hook table, and it opens the input list. Consumer tv 0x0089
            // only switches to the TV input.
            RemoteCell(id: "input", row: 1, col: 4, rowSpan: 1, colSpan: 1, control: .button,
                       label: RemoteLabel("Вхід"), tone: .plain, press: .tap, action: .consumer(RemoteUsageId.videoNext), roles: [:]),
            RemoteCell(id: "exit", row: 2, col: 1, rowSpan: 1, colSpan: 1, control: .button,
                       label: RemoteLabel("Вийти"), tone: .plain, press: .tap, action: .consumer(RemoteUsageId.exit), roles: [:]),
            RemoteCell(id: "info", row: 2, col: 2, rowSpan: 1, colSpan: 1, control: .button,
                       label: RemoteLabel("Інфо"), tone: .plain, press: .tap, action: .consumer(RemoteUsageId.info), roles: [:]),
            RemoteCell(id: "gap-mid", row: 2, col: 3, rowSpan: 1, colSpan: 1, control: .spacer,
                       label: RemoteLabel(""), tone: .plain, press: .tap, action: RemoteAction.none, roles: [:]),
            // Back belongs on the outer right edge, where the maintainer's thumb
            // reaches it without crossing the pad.
            RemoteCell(id: "back", row: 2, col: 4, rowSpan: 1, colSpan: 1, control: .button,
                       label: RemoteLabel("Назад"), tone: .plain, press: .tap, action: .consumer(RemoteUsageId.backLg), roles: [:]),
            // The rocker takes the column left of the pad, so volume sits beside
            // the cross rather than stacked above its left arm.
            RemoteCell(id: "volume", row: 3, col: 1, rowSpan: 2, colSpan: 1, control: .rocker,
                       label: RemoteLabel("Гучність"), tone: .plain, press: .hold, action: RemoteAction.none,
                       roles: [
                           .primary: RemoteRoleAction(action: .consumer(RemoteUsageId.volumeUp), label: RemoteLabel("Гучн. +")),
                           .secondary: RemoteRoleAction(action: .consumer(RemoteUsageId.volumeDown), label: RemoteLabel("Гучн. −")),
                       ]),
            // The pad's arms carry no label: ▲ ▼ ◀ ▶ read faster than five words
            // inside a narrow tile. Enter is the centre, not consumer Select.
            RemoteCell(id: "pad", row: 3, col: 2, rowSpan: 3, colSpan: 3, control: .dpad,
                       label: RemoteLabel("Навігація"), tone: .plain, press: .hold, action: RemoteAction.none,
                       roles: [
                           .up: RemoteRoleAction(action: .key(RemoteKeyId.up), label: RemoteLabel("")),
                           .down: RemoteRoleAction(action: .key(RemoteKeyId.down), label: RemoteLabel("")),
                           .left: RemoteRoleAction(action: .key(RemoteKeyId.left), label: RemoteLabel("")),
                           .right: RemoteRoleAction(action: .key(RemoteKeyId.right), label: RemoteLabel("")),
                           .center: RemoteRoleAction(action: .key(RemoteKeyId.returnKey), label: RemoteLabel("")),
                       ]),
            RemoteCell(id: "gap-bottom", row: 5, col: 1, rowSpan: 1, colSpan: 1, control: .spacer,
                       label: RemoteLabel(""), tone: .plain, press: .tap, action: RemoteAction.none, roles: [:]),
        ]
    )
}

extension RemoteTemplateDecoder {
    /// Turns the raw label form into a RemoteLabel. An empty object keeps the
    /// value (isEmpty drives the unlabelled-button note).
    static func remoteLabel(from raw: RawLabel?) -> RemoteLabel {
        guard let raw else { return RemoteLabel("") }
        if let s = raw.string { return RemoteLabel(s) }
        return RemoteLabel(byLanguage: raw.byLanguage ?? [:])
    }
}

/// A cell's resolved rectangle in an arbitrary coordinate space. Layout lives
/// here so the renderer can stay dumb and the math can be tested.
struct RemoteCellFrame: Equatable {
    let id: String
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

/// Consumer Control usages the remote can name. The existing media usages come
/// from `HIDConsumerUsage` (`Shared/HIDReports.swift`) rather than being
/// re-typed here; the TV usages are the Consumer-page mapping used by the Linux
/// kernel's `drivers/hid/hid-input.c` (see docs/tv-remote.md).
enum RemoteUsageId {
    static let power: UInt16 = HIDConsumerUsage.power
    static let sleep: UInt16 = HIDConsumerUsage.sleep
    static let brightnessUp: UInt16 = HIDConsumerUsage.brightnessIncrement
    static let brightnessDown: UInt16 = HIDConsumerUsage.brightnessDecrement
    static let fastForward: UInt16 = HIDConsumerUsage.fastForward
    static let rewind: UInt16 = HIDConsumerUsage.rewind
    static let next: UInt16 = HIDConsumerUsage.nextTrack
    static let previous: UInt16 = HIDConsumerUsage.previousTrack
    static let shuffle: UInt16 = HIDConsumerUsage.randomPlay
    static let repeatTrack: UInt16 = HIDConsumerUsage.repeatTrack
    static let playPause: UInt16 = HIDConsumerUsage.playPause
    static let mute: UInt16 = HIDConsumerUsage.mute
    static let volumeUp: UInt16 = HIDConsumerUsage.volumeIncrement
    static let volumeDown: UInt16 = HIDConsumerUsage.volumeDecrement

    static let menu: UInt16 = 0x0040
    static let menuPick: UInt16 = 0x0041
    static let menuEscape: UInt16 = 0x0046
    static let info: UInt16 = 0x0060
    static let closedCaption: UInt16 = 0x0061
    static let tv: UInt16 = 0x0089
    /// Consumer usage Linux maps to KEY_VIDEO_NEXT, which Simon34545's LG table
    /// lists as TV_VIDEO (241). Verified on the C1: this opens the input list.
    static let videoNext: UInt16 = 0x0082
    static let programGuide: UInt16 = 0x008D
    static let exit: UInt16 = 0x0094
    static let help: UInt16 = 0x0095
    static let channelUp: UInt16 = 0x009C
    static let channelDown: UInt16 = 0x009D
    static let home: UInt16 = 0x0223
    static let back: UInt16 = 0x0224
    /// Verified on the maintainer's C1 with 3.6.12: this is the Back button.
    /// Simon34545's LG input-hook table reports Back as Linux KEY_PREVIOUS
    /// (412), and Linux maps consumer AL Previous Task (0x01A4) to that key.
    /// Consumer `back` (0x0224) and the keyboard Escape/Backspace keys are
    /// ignored by the TV, so do not swap them back.
    static let backLg: UInt16 = 0x01A4
    static let forward: UInt16 = 0x0225
    static let stop: UInt16 = 0x0226
    static let refresh: UInt16 = 0x0227

    /// Names only: raw numbers are rejected in v1, because the bundled file is
    /// the only template source and a plausible number no host acts on is the
    /// worst silent failure.
    static let names: [String: UInt16] = [
        "power": power, "sleep": sleep,
        "brightnessUp": brightnessUp, "brightnessDown": brightnessDown,
        "fastForward": fastForward, "rewind": rewind, "next": next, "previous": previous,
        "shuffle": shuffle, "repeat": repeatTrack, "playPause": playPause, "mute": mute,
        "volumeUp": volumeUp, "volumeDown": volumeDown,
        "menu": menu, "menuPick": menuPick, "menuEscape": menuEscape,
        "info": info, "closedCaption": closedCaption, "tv": tv, "guide": programGuide,
        "videoNext": videoNext,
        "exit": exit, "help": help, "channelUp": channelUp, "channelDown": channelDown,
        "home": home, "back": back, "backLg": backLg, "forward": forward, "stop": stop, "refresh": refresh,
    ]

    static func resolve(_ name: String) -> UInt16? { names[name] }
}

/// Keyboard keys the remote can name, resolved through the existing HID table.
enum RemoteKeyId {
    static let up = HID.keyUpArrow
    static let down = HID.keyDownArrow
    static let left = HID.keyLeftArrow
    static let right = HID.keyRightArrow
    static let returnKey = HID.keyEnter
    static let escape = HID.keyEscape
    static let backspace = HID.keyBackspace
    static let tab = HID.keyTab
    static let space = HID.keySpace
    static let delete = HID.keyDelete
    static let home = HID.keyHome
    static let end = HID.keyEnd
    static let pageUp = HID.keyPageUp
    static let pageDown = HID.keyPageDown

    /// `"return"` is the name templates use; `RemoteKeyId.return` is not a legal
    /// Swift member name, so the constant is spelled `returnKey`.
    static let names: [String: UInt8] = [
        "win": 0, // Modifier-only key; resolveAction adds the GUI bit.
        "up": up, "down": down, "left": left, "right": right,
        "return": returnKey, "escape": escape, "backspace": backspace, "tab": tab,
        "space": space, "delete": delete, "home": home, "end": end,
        "pageUp": pageUp, "pageDown": pageDown,
    ]

    static func resolve(_ name: String) -> UInt8? { names[name] }
}

/// Modifier names accepted by a `.key` action.
enum RemoteModifierName {
    static let names: [String: UInt8] = [
        "shift": HID.modLeftShift,
        "ctrl": HID.modLeftCtrl,
        "alt": HID.modLeftAlt,
        "gui": HID.modLeftGUI,
    ]

    /// nil means an unknown modifier name, which must not be silently dropped.
    static func mask(_ names: [String]) -> UInt8? {
        var mask = UInt8(0)
        for name in names {
            guard let bit = RemoteModifierName.names[name] else { return nil }
            mask |= bit
        }
        return mask
    }
}

enum RemoteTemplateLoad: Equatable {
    /// A usable template plus non-fatal notes about what was dropped.
    case loaded(RemoteTemplate, [String])
    /// A template that cannot be shown without guessing.
    case rejected(String)
}

/// A label in its raw form: either a plain string (legacy) or an object of
/// per-language values, e.g. `{"uk": "Тиша", "en": "Mute"}`.
private struct RawLabel: Decodable {
    let string: String?
    let byLanguage: [String: String]?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self) {
            self.string = s
            self.byLanguage = nil
            return
        }
        let map = try container.decode([String: String].self)
        self.string = nil
        self.byLanguage = map
    }
}

private struct RawAction: Codable {
    var kind: String?
    var key: String?
    var modifiers: [String]?
    var usage: String?
    var label: RawLabel?
}

private struct RawCell: Codable {
    var id: String
    var row: Int?
    var col: Int?
    var rowSpan: Int?
    var colSpan: Int?
    var control: String?
    var label: RawLabel?
    var tone: String?
    var press: String?
    var scale: Double?
    var fontScale: Double?
    var action: RawAction?
    var actions: [String: RawAction]?
}

private struct RawTemplate: Codable {
    var formatVersion: Int?
    var id: String?
    var name: String?
    var columns: Int?
    var rows: Int?
    var cells: [RawCell]?
}

enum RemoteTemplateDecoder {
    /// Cell bounds outside which a template is refused rather than guessed.
    static let columnRange = 3...6
    static let rowRange = 3...10
    /// Visual scale of a control inside its cell; the bundled template uses 1.0.
    static let scaleRange = 0.3...1.5
    /// Multiplier on the label font size; 1.0 is the default 16 pt (10 pt compact).
    static let fontScaleRange = 0.5...2.0

    static func decode(_ data: Data) -> RemoteTemplateLoad {
        guard let raw = try? JSONDecoder().decode(RawTemplate.self, from: data) else {
            return .rejected("not readable as a remote template")
        }
        return load(raw)
    }

    static func decode(text: String) -> RemoteTemplateLoad {
        decode(Data(text.utf8))
    }

    /// RawTemplate is private, so this entry point is fileprivate; `decode` is
    /// the public one.
    fileprivate static func load(_ raw: RawTemplate) -> RemoteTemplateLoad {
        guard let version = raw.formatVersion else {
            return .rejected("formatVersion is missing")
        }
        guard version == RemoteTemplate.currentFormatVersion else {
            return .rejected("format version \(version) is not supported")
        }
        guard let id = raw.id, !id.isEmpty else { return .rejected("id is missing") }
        guard let name = raw.name, !name.isEmpty else { return .rejected("name is missing") }
        guard let columns = raw.columns, columnRange.contains(columns) else {
            return .rejected("columns must be in \(columnRange)")
        }
        guard let rows = raw.rows, rowRange.contains(rows) else {
            return .rejected("rows must be in \(rowRange)")
        }

        var seen = Set<String>()
        var cells: [RemoteCell] = []
        var occupied = Set<String>()
        var notes: [String] = []

        for rawCell in raw.cells ?? [] {
            if !seen.insert(rawCell.id).inserted {
                return .rejected("duplicate cell id \"\(rawCell.id)\"")
            }
            guard let row = rawCell.row, let col = rawCell.col else {
                notes.append("cell \"\(rawCell.id)\" has no grid position, dropped")
                continue
            }
            let rowSpan = rawCell.rowSpan ?? 1
            let colSpan = rawCell.colSpan ?? 1
            if rowSpan < 1 || colSpan < 1 || row < 1 || col < 1
                || row + rowSpan - 1 > rows || col + colSpan - 1 > columns {
                notes.append("cell \"\(rawCell.id)\" sits outside the \(columns)x\(rows) grid, dropped")
                continue
            }
            let covered = (row..<row + rowSpan).flatMap { r in (col..<col + colSpan).map { c in "\(r),\(c)" } }
            if covered.contains(where: { occupied.contains($0) }) {
                return .rejected("cell \"\(rawCell.id)\" overlaps another cell")
            }
            occupied.formUnion(covered)

            guard let controlName = rawCell.control, let control = RemoteControl(rawValue: controlName) else {
                notes.append("cell \"\(rawCell.id)\" has an unknown control \(rawCell.control ?? "nil"), dropped")
                continue
            }
            let tone = RemoteTone(rawValue: rawCell.tone ?? "plain") ?? .plain
            let press = RemotePress(rawValue: rawCell.press ?? "tap") ?? .tap
            let label = Self.remoteLabel(from: rawCell.label)
            if label.isEmpty && control == .button {
                notes.append("cell \"\(rawCell.id)\" is a button with no label")
            }
            let scale = rawCell.scale ?? 1.0
            let fontScale = rawCell.fontScale ?? 1.0
            if !(RemoteTemplateDecoder.scaleRange.contains(scale) && RemoteTemplateDecoder.fontScaleRange.contains(fontScale)) {
                notes.append("cell \"\(rawCell.id)\" has an out-of-range scale/fontScale, dropped")
                continue
            }

            switch control {
            case .button, .spacer:
                if rawCell.actions != nil {
                    notes.append("cell \"\(rawCell.id)\" is a \(control.rawValue) but lists role actions, dropped")
                    continue
                }
                let action = resolveAction(rawCell.action ?? RawAction(kind: "none"), id: rawCell.id, notes: &notes)
                guard let action else { continue }
                cells.append(RemoteCell(id: rawCell.id, row: row, col: col, rowSpan: rowSpan, colSpan: colSpan,
                                        control: control, label: label, tone: tone, press: press,
                                        action: action, roles: [:], scale: scale, fontScale: fontScale))

            case .dpad:
                if rawCell.action != nil {
                    notes.append("cell \"\(rawCell.id)\" is a dpad but lists a single action, dropped")
                    continue
                }
                let roles = rawCell.actions ?? [:]
                var resolved: [RemoteRole: RemoteRoleAction] = [:]
                var failed = false
                for name in ["up", "down", "left", "right"] {
                    guard let role = RemoteRole(rawValue: name), let rawAction = roles[name] else {
                        notes.append("cell \"\(rawCell.id)\" is missing the \(name) action, dropped")
                        failed = true
                        break
                    }
                    guard let action = resolveAction(rawAction, id: rawCell.id, notes: &notes) else {
                        failed = true
                        break
                    }
                    resolved[role] = RemoteRoleAction(action: action, label: Self.remoteLabel(from: rawAction.label))
                }
                if failed { continue }
                if let center = roles["center"] {
                    guard let action = resolveAction(center, id: rawCell.id, notes: &notes) else { continue }
                    resolved[.center] = RemoteRoleAction(action: action, label: Self.remoteLabel(from: center.label))
                } else {
                    notes.append("cell \"\(rawCell.id)\" dpad has no center action")
                }
                cells.append(RemoteCell(id: rawCell.id, row: row, col: col, rowSpan: rowSpan, colSpan: colSpan,
                                        control: control, label: label, tone: tone, press: press,
                                        action: RemoteAction.none, roles: resolved, scale: scale, fontScale: fontScale))

            case .rocker:
                if rawCell.action != nil {
                    notes.append("cell \"\(rawCell.id)\" is a rocker but lists a single action, dropped")
                    continue
                }
                let roles = rawCell.actions ?? [:]
                var resolved: [RemoteRole: RemoteRoleAction] = [:]
                var failed = false
                for name in ["primary", "secondary"] {
                    guard let role = RemoteRole(rawValue: name), let rawAction = roles[name] else {
                        notes.append("cell \"\(rawCell.id)\" is missing the \(name) action, dropped")
                        failed = true
                        break
                    }
                    guard let action = resolveAction(rawAction, id: rawCell.id, notes: &notes) else {
                        failed = true
                        break
                    }
                    resolved[role] = RemoteRoleAction(action: action, label: Self.remoteLabel(from: rawAction.label))
                }
                if failed { continue }
                cells.append(RemoteCell(id: rawCell.id, row: row, col: col, rowSpan: rowSpan, colSpan: colSpan,
                                        control: control, label: label, tone: tone, press: press,
                                        action: RemoteAction.none, roles: resolved, scale: scale, fontScale: fontScale))
            }
        }

        return .loaded(RemoteTemplate(formatVersion: version, id: id, name: name,
                                      columns: columns, rows: rows, cells: cells), notes)
    }

    /// nil means the action asked for something the transports cannot send.
    private static func resolveAction(_ raw: RawAction, id: String, notes: inout [String]) -> RemoteAction? {
        guard let kindName = raw.kind, let kind = RemoteActionKind(rawValue: kindName) else {
            notes.append("cell \"\(id)\" has an unknown action kind \(raw.kind ?? "nil"), dropped")
            return nil
        }
        switch kind {
        case .none:
            return RemoteAction.none
        case .key:
            guard let keyName = raw.key, let keycode = RemoteKeyId.resolve(keyName) else {
                notes.append("cell \"\(id)\" names an unknown key \(raw.key ?? "nil"), dropped")
                return nil
            }
            let modifiers = RemoteModifierName.mask(raw.modifiers ?? [])
            guard let mask = modifiers else {
                notes.append("cell \"\(id)\" names an unknown modifier, dropped")
                return nil
            }
            return .key(keycode, modifiers: keyName == "win" ? mask | HID.modLeftGUI : mask)
        case .consumer:
            guard let usageName = raw.usage, let usage = RemoteUsageId.resolve(usageName) else {
                notes.append("cell \"\(id)\" names an unknown consumer usage \(raw.usage ?? "nil"), dropped")
                return nil
            }
            return .consumer(usage)
        }
    }
}

/// Unit rectangles of a `columns` x `rows` grid inside `size`, row-major, with
/// `gap` between neighbours. Pure so both the remote grid and the sub-controls
/// inside a cell (a dpad is a 3x3 grid) share one tested layout function.
enum RemoteGrid {
    static func unitFrames(columns: Int, rows: Int,
                           size: (width: Double, height: Double), gap: Double) -> [RemoteCellFrame] {
        guard columns > 0, rows > 0 else { return [] }
        let spacing = max(0, gap)
        let unitWidth = (size.width - spacing * Double(columns - 1)) / Double(columns)
        let unitHeight = (size.height - spacing * Double(rows - 1)) / Double(rows)
        var frames: [RemoteCellFrame] = []
        for row in 1...rows {
            for col in 1...columns {
                frames.append(RemoteCellFrame(
                    id: "\(row),\(col)",
                    x: (unitWidth + spacing) * Double(col - 1),
                    y: (unitHeight + spacing) * Double(row - 1),
                    width: unitWidth,
                    height: unitHeight
                ))
            }
        }
        return frames
    }
}

extension RemoteTemplate {
    /// Rectangles for every cell in a coordinate space of `size`, with `gap`
    /// between adjacent cells. Cells never overlap by construction: the decoder
    /// already refused templates that do.
    func frames(size: (width: Double, height: Double), gap: Double) -> [RemoteCellFrame] {
        let units = RemoteGrid.unitFrames(columns: columns, rows: rows, size: size, gap: gap)
        let unitWidth = units.first?.width ?? 0
        let unitHeight = units.first?.height ?? 0
        let spacing = max(0, gap)
        return cells.map { cell in
            let unit = units[(cell.row - 1) * columns + (cell.col - 1)]
            return RemoteCellFrame(
                id: cell.id,
                x: unit.x,
                y: unit.y,
                width: unitWidth * Double(cell.colSpan) + spacing * Double(cell.colSpan - 1),
                height: unitHeight * Double(cell.rowSpan) + spacing * Double(cell.rowSpan - 1)
            )
        }
    }
}
