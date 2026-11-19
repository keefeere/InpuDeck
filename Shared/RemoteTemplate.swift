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

/// A slot's action plus the text drawn on it. Rocker halves and the dpad centre
/// need their own labels, because an action cannot say "Гучність +" by itself.
struct RemoteRoleAction: Equatable {
    let action: RemoteAction
    /// Localization key; empty means the renderer falls back to a glyph.
    let label: String
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
    /// Localization key; empty means the renderer shows only the glyph-free label.
    let label: String
    let tone: RemoteTone
    let press: RemotePress
    /// The single action of a `button`/`spacer`.
    let action: RemoteAction
    /// Actions of `dpad` and `rocker`, keyed by role.
    /// Actions and labels of `dpad` and `rocker`, keyed by role.
    let roles: [RemoteRole: RemoteRoleAction]
    /// Rockers split along the longer axis of the cell.
    var rockerIsHorizontal: Bool { colSpan >= rowSpan }
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
        rows: 6,
        cells: [
            // Mirrors the LG remote grouping. The codes here are the ones the
            // maintainer's C1 actually acted on (see docs/tv-remote.md): consumer
            // volume / mute / menu / exit, keyboard arrows and Enter, keyboard
            // Win for Home. Back remains an unsuccessful experiment. Consumer
            // Select, Home, Back and Play-pause were
            // ignored by the TV, so they are not in this template.
            RemoteCell(id: "volume", row: 1, col: 1, rowSpan: 2, colSpan: 1, control: .rocker,
                       label: "Гучність", tone: .plain, press: .hold, action: RemoteAction.none,
                       roles: [
                           .primary: RemoteRoleAction(action: .consumer(RemoteUsageId.volumeUp), label: "Гучність +"),
                           .secondary: RemoteRoleAction(action: .consumer(RemoteUsageId.volumeDown), label: "Гучність −"),
                       ]),
            RemoteCell(id: "guide", row: 1, col: 2, rowSpan: 1, colSpan: 1, control: .button,
                       label: "Гід", tone: .plain, press: .tap, action: .consumer(RemoteUsageId.programGuide), roles: [:]),
            RemoteCell(id: "channel-space", row: 1, col: 3, rowSpan: 2, colSpan: 1, control: .spacer,
                       label: "", tone: .plain, press: .tap, action: RemoteAction.none, roles: [:]),
            RemoteCell(id: "mute", row: 1, col: 4, rowSpan: 1, colSpan: 1, control: .button,
                       label: "Вимкнути звук", tone: .plain, press: .tap, action: .consumer(RemoteUsageId.mute), roles: [:]),
            RemoteCell(id: "exit", row: 2, col: 2, rowSpan: 1, colSpan: 1, control: .button,
                       label: "Вийти", tone: .plain, press: .tap, action: .consumer(RemoteUsageId.exit), roles: [:]),
            RemoteCell(id: "info", row: 2, col: 4, rowSpan: 1, colSpan: 1, control: .button,
                       label: "Інфо", tone: .plain, press: .tap, action: .consumer(RemoteUsageId.info), roles: [:]),
            // The pad's arms carry no label: ▲ ▼ ◀ ▶ read faster than five words
            // inside a narrow tile. Enter is the centre, not consumer Select.
            RemoteCell(id: "pad", row: 3, col: 1, rowSpan: 3, colSpan: 3, control: .dpad,
                       label: "Навігація", tone: .plain, press: .hold, action: RemoteAction.none,
                       roles: [
                           .up: RemoteRoleAction(action: .key(RemoteKeyId.up), label: ""),
                           .down: RemoteRoleAction(action: .key(RemoteKeyId.down), label: ""),
                           .left: RemoteRoleAction(action: .key(RemoteKeyId.left), label: ""),
                           .right: RemoteRoleAction(action: .key(RemoteKeyId.right), label: ""),
                           .center: RemoteRoleAction(action: .key(RemoteKeyId.returnKey), label: ""),
                       ]),
            RemoteCell(id: "menu", row: 3, col: 4, rowSpan: 1, colSpan: 1, control: .button,
                       label: "Меню", tone: .plain, press: .tap, action: .consumer(RemoteUsageId.menu), roles: [:]),
            RemoteCell(id: "gap1", row: 4, col: 4, rowSpan: 1, colSpan: 1, control: .spacer,
                       label: "", tone: .plain, press: .tap, action: RemoteAction.none, roles: [:]),
            RemoteCell(id: "gap2", row: 5, col: 4, rowSpan: 1, colSpan: 1, control: .spacer,
                       label: "", tone: .plain, press: .tap, action: RemoteAction.none, roles: [:]),
            RemoteCell(id: "back", row: 6, col: 1, rowSpan: 1, colSpan: 1, control: .button,
                       label: "Назад", tone: .plain, press: .tap, action: .consumer(RemoteUsageId.backLg), roles: [:]),
            RemoteCell(id: "home", row: 6, col: 2, rowSpan: 1, colSpan: 1, control: .button,
                       label: "Додому", tone: .prominent, press: .tap, action: .key(0, modifiers: HID.modLeftGUI), roles: [:]),
            RemoteCell(id: "input-space", row: 6, col: 3, rowSpan: 1, colSpan: 1, control: .spacer,
                       label: "", tone: .plain, press: .tap, action: RemoteAction.none, roles: [:]),
            RemoteCell(id: "gap3", row: 6, col: 4, rowSpan: 1, colSpan: 1, control: .spacer,
                       label: "", tone: .plain, press: .tap, action: RemoteAction.none, roles: [:]),
        ]
    )
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
    static let programGuide: UInt16 = 0x008D
    static let exit: UInt16 = 0x0094
    static let help: UInt16 = 0x0095
    static let channelUp: UInt16 = 0x009C
    static let channelDown: UInt16 = 0x009D
    static let home: UInt16 = 0x0223
    static let back: UInt16 = 0x0224
    /// Failed experiment: webOS event keycode 461 is NOT a USB HID usage.
    /// 0x01CD is consumer AC Insert, not a verified LG Back mapping.
    static let backLg: UInt16 = 0x01CD
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

private struct RawAction: Codable {
    var kind: String?
    var key: String?
    var modifiers: [String]?
    var usage: String?
    var label: String?
}

private struct RawCell: Codable {
    var id: String
    var row: Int?
    var col: Int?
    var rowSpan: Int?
    var colSpan: Int?
    var control: String?
    var label: String?
    var tone: String?
    var press: String?
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
            let label = rawCell.label ?? ""
            if label.isEmpty && control == .button {
                notes.append("cell \"\(rawCell.id)\" is a button with no label")
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
                                        action: action, roles: [:]))

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
                    resolved[role] = RemoteRoleAction(action: action, label: rawAction.label ?? "")
                }
                if failed { continue }
                if let center = roles["center"] {
                    guard let action = resolveAction(center, id: rawCell.id, notes: &notes) else { continue }
                    resolved[.center] = RemoteRoleAction(action: action, label: center.label ?? "")
                } else {
                    notes.append("cell \"\(rawCell.id)\" dpad has no center action")
                }
                cells.append(RemoteCell(id: rawCell.id, row: row, col: col, rowSpan: rowSpan, colSpan: colSpan,
                                        control: control, label: label, tone: tone, press: press,
                                        action: RemoteAction.none, roles: resolved))

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
                    resolved[role] = RemoteRoleAction(action: action, label: rawAction.label ?? "")
                }
                if failed { continue }
                cells.append(RemoteCell(id: rawCell.id, row: row, col: col, rowSpan: rowSpan, colSpan: colSpan,
                                        control: control, label: label, tone: tone, press: press,
                                        action: RemoteAction.none, roles: resolved))
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
