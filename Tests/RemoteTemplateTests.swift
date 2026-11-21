import Foundation

@main
struct RemoteTemplateTests {
    /// The shipped resource, resolved from this file's location so the test
    /// checks the file the app actually bundles instead of a copy.
    static let bundledTemplateURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("../InpuDeck/RemoteTemplate.tv-default.json")

    static func main() {
        let shipped = bundledTemplateLoad()
        precondition(shipped.template == RemoteTemplate.defaultTemplate,
                     "the bundled template must equal RemoteTemplate.defaultTemplate, got \(shipped.notes)")
        precondition(shipped.notes.isEmpty,
                     "the bundled template must load with no dropped cells: \(shipped.notes)")

        structuralRejections()
        degradedCells()
        layoutMath()
        usageTables()
        print("Remote template decoding, layout and usage-table tests passed.")
    }

    struct Shipped {
        let template: RemoteTemplate
        let notes: [String]
    }

    static func bundledTemplateLoad() -> Shipped {
        let data = try! Data(contentsOf: bundledTemplateURL)
        guard case let .loaded(template, notes) = RemoteTemplateDecoder.decode(data) else {
            preconditionFailure("the bundled template was rejected")
        }
        return Shipped(template: template, notes: notes)
    }

    static func load(_ text: String) -> RemoteTemplateLoad {
        RemoteTemplateDecoder.decode(text: text)
    }

    static func cellJSON(_ extra: String) -> String {
        #"{"formatVersion":1,"id":"t","name":"T","columns":4,"rows":4,"cells":[\#(extra)]}"#
    }

    static func structuralRejections() {
        guard case .rejected = load("not json at all") else {
            preconditionFailure("unparseable data must be rejected")
        }
        guard case .rejected(let reason) = load(
            #"{"id":"t","name":"T","columns":4,"rows":4,"cells":[]}"#
        ) else {
            // A guard's bindings are not visible in its else block, so this must
            // not quote the reason.
            preconditionFailure("a template without formatVersion must be rejected")
        }
        precondition(reason.contains("formatVersion"), "rejection must name the field: \(reason)")

        guard case .rejected(let reason) = load(
            #"{"formatVersion":2,"id":"t","name":"T","columns":4,"rows":4,"cells":[]}"#
        ) else {
            preconditionFailure("a newer format version must be rejected, not guessed")
        }
        precondition(reason.contains("2"), "rejection must name the version: \(reason)")

        for json in [
            #"{"formatVersion":1,"id":"","name":"T","columns":4,"rows":4,"cells":[]}"#,
            #"{"formatVersion":1,"id":"t","name":"","columns":4,"rows":4,"cells":[]}"#,
            #"{"formatVersion":1,"id":"t","name":"T","columns":2,"rows":4,"cells":[]}"#,
            #"{"formatVersion":1,"id":"t","name":"T","columns":4,"rows":12,"cells":[]}"#,
        ] {
            guard case .rejected = load(json) else {
                preconditionFailure("must be rejected: \(json)")
            }
        }

        let duplicate = cellJSON(
            #"{"id":"a","row":1,"col":1,"control":"button","label":"A","action":{"kind":"none"}},{"id":"a","row":2,"col":1,"control":"button","label":"B","action":{"kind":"none"}}"#
        )
        guard case .rejected(let reason) = load(duplicate) else {
            preconditionFailure("duplicate cell ids must be rejected")
        }
        precondition(reason.contains("duplicate"), "rejection must say duplicate: \(reason)")

        let overlap = cellJSON(
            #"{"id":"a","row":1,"col":1,"rowSpan":2,"colSpan":2,"control":"dpad","actions":{"up":{"kind":"key","key":"up"},"down":{"kind":"key","key":"down"},"left":{"kind":"key","key":"left"},"right":{"kind":"key","key":"right"}}},{"id":"b","row":2,"col":2,"control":"button","label":"B","action":{"kind":"none"}}"#
        )
        guard case .rejected(let reason) = load(overlap) else {
            preconditionFailure("overlapping cells must be rejected: two controls on one cell cannot both be shown")
        }
        precondition(reason.contains("overlap"), "rejection must say overlap: \(reason)")

        // A known field with the wrong type is a malformed file, not a guess.
        guard case .rejected = load(cellJSON(
            #"{"id":"a","row":1,"col":1,"control":"button","label":"A","action":{"kind":"consumer","usage":547}}"#
        )) else {
            preconditionFailure("a numeric usage must not be accepted in v1")
        }
    }

    static func degradedCells() {
        let unknownControl = cellJSON(
            #"{"id":"a","row":1,"col":1,"control":"dial","label":"A","action":{"kind":"none"}}"#
        )
        guard case let .loaded(template, notes) = load(unknownControl) else {
            preconditionFailure("an unknown control should drop one cell, not the template")
        }
        precondition(template.cells.isEmpty, "the bad cell must be dropped")
        precondition(notes.contains(where: { $0.contains("a") && $0.contains("dial") }),
                     "the note must name the cell and the control: \(notes)")

        let unknownUsage = cellJSON(
            #"{"id":"a","row":1,"col":1,"control":"button","label":"A","action":{"kind":"consumer","usage":"homeButton"}}"#
        )
        guard case let .loaded(_, notes) = load(unknownUsage) else {
            preconditionFailure("an unknown usage should drop one cell")
        }
        precondition(notes.contains(where: { $0.contains("homeButton") }),
                     "the note must name the bad usage: \(notes)")

        let unknownKey = cellJSON(
            #"{"id":"a","row":1,"col":1,"control":"button","label":"A","action":{"kind":"key","key":"f13"}}"#
        )
        guard case let .loaded(_, notes) = load(unknownKey) else {
            preconditionFailure("an unknown key name should drop one cell")
        }
        precondition(notes.contains(where: { $0.contains("f13") }), "the note must name the key: \(notes)")

        let unknownModifier = cellJSON(
            #"{"id":"a","row":1,"col":1,"control":"button","label":"A","action":{"kind":"key","key":"space","modifiers":["hyper"]}}"#
        )
        guard case let .loaded(_, notes) = load(unknownModifier) else {
            preconditionFailure("an unknown modifier must not be silently ignored")
        }
        precondition(notes.contains(where: { $0.contains("modifier") }), "the note must mention a modifier: \(notes)")

        // v1 has no text action; it must be reported, not rendered as nothing.
        let textAction = cellJSON(
            #"{"id":"a","row":1,"col":1,"control":"button","label":"A","action":{"kind":"text","text":"hi"}}"#
        )
        guard case let .loaded(_, notes) = load(textAction) else {
            preconditionFailure("a text action should drop one cell")
        }
        precondition(notes.contains(where: { $0.contains("text") }),
                     "the note must name the unsupported kind: \(notes)")

        let buttonWithRoles = cellJSON(
            #"{"id":"a","row":1,"col":1,"control":"button","label":"A","actions":{"primary":{"kind":"none"}}}"#
        )
        guard case let .loaded(_, notes) = load(buttonWithRoles) else {
            preconditionFailure("a button must not carry role actions")
        }
        precondition(notes.contains(where: { $0.contains("role actions") }), "the note must say why: \(notes)")

        let dpadMissingUp = cellJSON(
            #"{"id":"a","row":1,"col":1,"control":"dpad","actions":{"down":{"kind":"key","key":"down"},"left":{"kind":"key","key":"left"},"right":{"kind":"key","key":"right"}}}"#
        )
        guard case let .loaded(_, notes) = load(dpadMissingUp) else {
            preconditionFailure("a dpad without up must be dropped")
        }
        precondition(notes.contains(where: { $0.contains("up") }), "the note must name the missing role: \(notes)")

        let dpadWithoutCenter = cellJSON(
            #"{"id":"a","row":1,"col":1,"control":"dpad","actions":{"up":{"kind":"key","key":"up"},"down":{"kind":"key","key":"down"},"left":{"kind":"key","key":"left"},"right":{"kind":"key","key":"right"}}}"#
        )
        guard case let .loaded(template, notes) = load(dpadWithoutCenter) else {
            preconditionFailure("a dpad without a centre is still usable")
        }
        precondition(template.cells.count == 1, "the dpad must survive")
        precondition(notes.contains(where: { $0.contains("center") }),
                     "the missing centre must be reported, not invented: \(notes)")

        let rockerMissingHalf = cellJSON(
            #"{"id":"a","row":1,"col":1,"control":"rocker","actions":{"primary":{"kind":"consumer","usage":"volumeUp"}}}"#
        )
        guard case let .loaded(_, notes) = load(rockerMissingHalf) else {
            preconditionFailure("a rocker with one half must be dropped")
        }
        precondition(notes.contains(where: { $0.contains("secondary") }), "the note must name the half: \(notes)")

        // A cell outside the grid is dropped; an unknown extra field is ignored.
        let outOfGrid = cellJSON(
            #"{"id":"a","row":9,"col":1,"control":"button","label":"A","action":{"kind":"none"}},{"id":"b","row":1,"col":1,"control":"button","label":"B","action":{"kind":"none"},"volume":3}"#
        )
        guard case let .loaded(template, notes) = load(outOfGrid) else {
            preconditionFailure("one out-of-grid cell must not reject the template")
        }
        precondition(template.cells.map(\.id) == ["b"], "only the in-grid cell survives")
        precondition(notes.contains(where: { $0.contains("a") && $0.contains("outside") }),
                     "the note must name the dropped cell: \(notes)")

        let unlabelledButton = cellJSON(
            #"{"id":"a","row":1,"col":1,"control":"button","action":{"kind":"none"}}"#
        )
        guard case let .loaded(template, notes) = load(unlabelledButton) else {
            preconditionFailure("an unlabelled button is still a control")
        }
        precondition(template.cells.count == 1, "the button must survive")
        precondition(notes.contains(where: { $0.contains("no label") }), "the note must say it is unlabelled")
    }

    static func layoutMath() {
        let template = RemoteTemplate.defaultTemplate
        let gap = 10.0
        let size = (width: 400.0, height: 600.0)
        let frames = template.frames(size: size, gap: gap)
        precondition(frames.count == template.cells.count, "every cell gets a frame")

        // 4 columns over 400 with 3 gaps of 10 leaves 370 for the units.
        let unitWidth = (400.0 - 3 * 10.0) / 4.0
        let unitHeight = (600.0 - 5 * 10.0) / 6.0
        // The origin is the VOL pair, mirroring the LG remote: a two-row rocker in
        // the first column. Home is a bottom-row cell, not the origin.
        let origin = frames.first(where: { $0.id == "volume" })!
        precondition(origin.x == 0 && origin.y == 0, "volume sits at the origin: \(origin)")
        precondition(origin.width == unitWidth, "a one-column rocker keeps one unit of width: \(origin)")
        precondition(origin.height == unitHeight * 2 + gap,
                     "a two-row rocker adds the gap between its units: \(origin)")

        let home = frames.first(where: { $0.id == "home" })!
        precondition(home.x == unitWidth + gap && home.y == unitHeight * 5 + gap * 5,
                     "home is row 6, column 2: \(home)")

        let pad = frames.first(where: { $0.id == "pad" })!
        precondition(pad.x == 0 && pad.y == unitHeight * 2 + gap * 2,
                     "the dpad starts at row 3, column 1, so only y moves: \(pad)")
        precondition(pad.width == unitWidth * 3 + gap * 2 && pad.height == unitHeight * 3 + gap * 2,
                     "a span must add the gaps between the units it covers: \(pad)")

        // Nothing spills outside the grid, and frames cannot overlap.
        let limit = template.frames(size: size, gap: 0)
        precondition(limit.allSatisfy { $0.x >= 0 && $0.y >= 0 }, "frames start inside the grid")
        precondition(limit.allSatisfy { $0.x + $0.width <= 400 && $0.y + $0.height <= 600 },
                     "a span must not spill past the grid: \(limit)")

        var covered = Set<String>()
        for frame in limit {
            let cell = template.cells.first(where: { $0.id == frame.id })!
            for row in cell.row..<cell.row + cell.rowSpan {
                for col in cell.col..<cell.col + cell.colSpan {
                    precondition(!covered.contains("\(row),\(col)"),
                                 "the decoder promised no overlap, frame for \(frame.id) breaks it")
                    covered.insert("\(row),\(col)")
                }
            }
        }
        precondition(covered.count == template.columns * template.rows,
                     "the default template must fill its grid, got \(covered.count)")

        let degenerate = RemoteTemplate(formatVersion: 1, id: "x", name: "X", columns: 4, rows: 4, cells: [])
        precondition(degenerate.frames(size: size, gap: gap).isEmpty, "an empty grid yields no frames")
        precondition(RemoteGrid.unitFrames(columns: 0, rows: 4, size: size, gap: gap).isEmpty,
                     "a zero-column grid yields no units")

        let vertical = RemoteCell(id: "v", row: 1, col: 1, rowSpan: 2, colSpan: 1, control: .rocker,
                                  label: "", tone: .plain, press: .hold, action: .none, roles: [:])
        precondition(!vertical.rockerIsHorizontal,
                     "a taller-than-wide rocker stacks its halves vertically")
        let horizontal = RemoteCell(id: "c", row: 1, col: 1, rowSpan: 1, colSpan: 2, control: .rocker,
                                    label: "", tone: .plain, press: .hold, action: .none, roles: [:])
        precondition(horizontal.rockerIsHorizontal,
                     "a wider-than-tall rocker puts its halves side by side")
    }

    static func usageTables() {
        // These numbers are the ones docs/tv-remote.md claims. If they drift, the
        // remote would send codes the LG C1 never acts on, silently.
        precondition(RemoteUsageId.home == 0x0223, "Home must stay 0x0223")
        precondition(RemoteUsageId.back == 0x0224, "Back must stay 0x0224")
        // Historical failed experiment; webOS keycode 461 does not identify a HID usage.
        precondition(RemoteUsageId.backLg == 0x01A4,
                     "Back experiment must send the HID usage mapped to Linux KEY_PREVIOUS (412)")
        precondition(RemoteUsageId.programGuide == 0x008D, "Program Guide must stay 0x008D")
        precondition(RemoteUsageId.channelUp == 0x009C, "Channel Up must stay 0x009C")
        precondition(RemoteUsageId.channelDown == 0x009D, "Channel Down must stay 0x009D")
        precondition(RemoteUsageId.info == 0x0060, "Data On Screen must stay 0x0060")
        precondition(RemoteUsageId.exit == 0x0094, "Exit must stay 0x0094")
        precondition(RemoteUsageId.menu == 0x0040, "Menu must stay 0x0040")

        // Both transports declare the Consumer selector as 0x0000-0x03FF; anything
        // outside would be a descriptor change, which v1 does not make.
        for (name, usage) in RemoteUsageId.names {
            precondition(usage >= 0x0000 && usage <= 0x03FF, "\(name) is outside the declared usage range")
        }
        precondition(RemoteUsageId.resolve("nope") == nil, "unknown usage names must not resolve")
        precondition(RemoteKeyId.resolve("nope") == nil, "unknown key names must not resolve")

        // Key names resolve through the shared HID table, not a private copy.
        precondition(RemoteKeyId.resolve("up") == HID.keyUpArrow, "up must resolve through HID")
        precondition(RemoteKeyId.resolve("return") == HID.keyEnter, "return must resolve to Enter")
        precondition(RemoteModifierName.mask(["shift", "ctrl"]) == HID.modLeftShift | HID.modLeftCtrl,
                     "modifier names must combine through HID")
        precondition(RemoteModifierName.mask([]) == 0, "no modifiers is the empty mask")
        precondition(RemoteModifierName.mask(["shift", "hyper"]) == nil, "an unknown modifier must fail")

        // Media usages must come from HIDConsumerUsage, not be re-typed here.
        precondition(RemoteUsageId.playPause == HIDConsumerUsage.playPause, "playPause must reuse HIDConsumerUsage")
        precondition(RemoteUsageId.mute == HIDConsumerUsage.mute, "mute must reuse HIDConsumerUsage")
        precondition(RemoteUsageId.volumeUp == HIDConsumerUsage.volumeIncrement,
                     "volumeUp must reuse HIDConsumerUsage")

        // The shipped template must not silently drop a control.
        let ids = Set(RemoteTemplate.defaultTemplate.cells.map(\.id))
        precondition(ids.count == RemoteTemplate.defaultTemplate.cells.count, "default ids must be unique")
        precondition(ids == Set(bundledTemplateLoad().template.cells.map(\.id)),
                     "the shipped file must carry exactly the default controls")

        let dpad = RemoteTemplate.defaultTemplate.cells.first(where: { $0.control == .dpad })!
        precondition(dpad.roles.count == 5, "the default dpad needs five roles")
        // Consumer Select (0x0041) did nothing on the maintainer's C1; Enter does.
        precondition(dpad.roles[.center]?.action.kind == .key && dpad.roles[.center]?.action.keycode == HID.keyEnter,
                     "the dpad centre must be Enter")
        precondition(dpad.roles[.up]?.action.kind == .key && dpad.roles[.up]?.action.keycode == HID.keyUpArrow,
                     "the dpad arm must be a keystroke, not a media usage")

        // A rocker is exactly two halves; three states go in three buttons, which
        // is why Previous / Play-pause / Next are separate cells.
        // Codes the C1 ignored are not in the shipped template: sending them is a
        // silent dead button, which is the worst failure this feature can have.
        let ignored: Set<UInt16> = [
            RemoteUsageId.menuPick, RemoteUsageId.home, RemoteUsageId.back,
            RemoteUsageId.playPause, RemoteUsageId.previous, RemoteUsageId.next,
        ]
        for cell in RemoteTemplate.defaultTemplate.cells {
            let usages: [UInt16]
            switch cell.control {
            case .button, .spacer:
                usages = cell.action.usage.map { [$0] } ?? []
            case .dpad, .rocker:
                usages = cell.roles.values.compactMap { $0.action.usage }
            }
            precondition(!usages.contains(where: { ignored.contains($0) }),
                         "cell \(cell.id) sends a usage the C1 ignored: \(usages)")
        }

        // VOL and CH are vertical pairs, like the LG remote.
        let rockers = RemoteTemplate.defaultTemplate.cells.filter { $0.control == .rocker }
        precondition(rockers.count == 1, "only the volume rocker remains")
        precondition(!ids.contains("channel") && !ids.contains("tv-input"),
                     "unused Channel and TV input controls must stay removed")
        let home = RemoteTemplate.defaultTemplate.cells.first(where: { $0.id == "home" })!
        precondition(home.action == .key(0, modifiers: HID.modLeftGUI),
                     "Home means Win/GUI, NOT the keyboard Home navigation key")
        let bundledHome = bundledTemplateLoad().template.cells.first(where: { $0.id == "home" })!
        precondition(bundledHome.action == home.action, "bundled Win resolves to a modifier-only action")
        let winReports = HIDInputState().tap(0, modifiers: HID.modLeftGUI)
        precondition(winReports.first?.data == Data([0x08, 0, 0, 0, 0, 0, 0, 0]),
                     "Win is the GUI modifier bit, never navigation Home or a regular key slot")
        precondition(winReports.last?.data == Data(repeating: 0, count: 8),
                     "Win must release the GUI modifier")
        precondition(rockers.allSatisfy { !$0.rockerIsHorizontal },
                     "VOL and CH stack their halves vertically")
        for rocker in rockers {
            precondition(!rocker.roles[.primary]!.label.isEmpty && !rocker.roles[.secondary]!.label.isEmpty,
                         "rocker halves must be labelled, otherwise they are two anonymous buttons")
        }
    }
}
