import SwiftUI

/// One rocker half, drawn as its own control, so it needs a stable SwiftUI id.
private struct RockerHalf: Identifiable {
    let role: RemoteRole
    let frame: RemoteCellFrame
    var id: String { role.rawValue }
}

/// The TV remote screen: a template grid rendered from `RemoteTemplate`.
/// Design: docs/tv-remote.md.
///
/// The renderer is deliberately dumb — every coordinate and every keycode comes
/// from the decoder, so this file only draws and sends.
struct RemoteScreenPage<Header: View>: View {
    let ble: RemoteInputController
    let isActiveTab: Bool
    private let header: Header

    /// The bundled template is the shipped specification; this copy is the
    /// fallback used when the resource is missing or unreadable.
    @State private var template = RemoteTemplate.defaultTemplate
    @State private var loadNote: String?

    private let gap: CGFloat = 10

    init(
        ble: RemoteInputController,
        isActiveTab: Bool,
        @ViewBuilder header: () -> Header
    ) {
        self.ble = ble
        self.isActiveTab = isActiveTab
        self.header = header()
    }

    var body: some View {
        VStack(spacing: 12) {
            header

            if let loadNote {
                Text(loadNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("remoteLoadNote")
            }

            GeometryReader { geometry in
                let size = gridSize(in: geometry.size)
                ZStack(alignment: .topLeading) {
                    ForEach(items(in: size)) { item in
                        render(item.cell, item.frame)
                            .position(x: item.frame.x + item.frame.width / 2,
                                      y: item.frame.y + item.frame.height / 2)
                    }
                }
                .frame(width: size.width, height: size.height)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .accessibilityIdentifier("remoteGrid")
        }
        .padding()
        .task { loadBundledTemplate() }
        .onChange(of: isActiveTab) { _, active in
            // Holding a direction key while swiping away must not leave the TV
            // scrolling forever.
            if !active { ble.releaseAllInput() }
        }
        .onDisappear { ble.releaseAllInput() }
    }

    /// Identifiable because SwiftUI needs a stable id per cell; `id` is the
    /// template's control id, so it survives a template reload.
    private struct Item: Identifiable {
        let id: String
        let cell: RemoteCell
        let frame: RemoteCellFrame
    }

    /// The grid fills the width, but letting rows absorb all leftover height
    /// turns every tile into a tall slab: the remote looked like a column of
    /// empty gaps on a phone. Tiles stay close to square, and the grid centers
    /// vertically inside whatever height is left.
    private func gridSize(in available: CGSize) -> CGSize {
        let columns = max(1, template.columns)
        let rows = max(1, template.rows)
        let spacing = Double(gap)
        let cellWidth = max(24, (Double(available.width) - spacing * Double(columns - 1)) / Double(columns))
        let cellHeight = min(max(40, cellWidth * 1.15),
                             (Double(available.height) - spacing * Double(rows - 1)) / Double(rows))
        return CGSize(width: cellWidth * Double(columns) + spacing * Double(columns - 1),
                      height: cellHeight * Double(rows) + spacing * Double(rows - 1))
    }

    private func items(in size: CGSize) -> [Item] {
        let frames = template.frames(size: (Double(size.width), Double(size.height)), gap: Double(gap))
        return template.cells.compactMap { cell in
            guard let frame = frames.first(where: { $0.id == cell.id }) else { return nil }
            return Item(id: cell.id, cell: cell, frame: frame)
        }
    }

    @ViewBuilder
    private func render(_ cell: RemoteCell, _ frame: RemoteCellFrame) -> some View {
        switch cell.control {
        case .button, .spacer:
            keyButton(title: localized(cell.label), action: cell.action, press: cell.press,
                      prominent: cell.tone == .prominent, frame: frame, id: cell.id)

        case .dpad:
            // A dpad is a 3x3 grid: the corners stay empty, the arms and centre
            // are the five roles.
            let units = RemoteGrid.unitFrames(columns: 3, rows: 3,
                                              size: (Double(frame.width), Double(frame.height)),
                                              gap: Double(gap))
            ZStack(alignment: .topLeading) {
                dpadButton(cell, .up, units[1], frame)
                dpadButton(cell, .left, units[3], frame)
                dpadButton(cell, .center, units[4], frame)
                dpadButton(cell, .right, units[5], frame)
                dpadButton(cell, .down, units[7], frame)
            }
            .frame(width: frame.width, height: frame.height)

        case .rocker:
            let width = Double(frame.width)
            let height = Double(frame.height)
            let spacing = Double(gap)
            let halves: [RockerHalf] = cell.rockerIsHorizontal
                ? [RockerHalf(role: .primary,
                        frame: RemoteCellFrame(id: RemoteRole.primary.rawValue, x: 0, y: 0,
                                               width: (width - spacing) / 2, height: height)),
                   RockerHalf(role: .secondary,
                        frame: RemoteCellFrame(id: RemoteRole.secondary.rawValue,
                                               x: (width + spacing) / 2, y: 0,
                                               width: (width - spacing) / 2, height: height))]
                : [RockerHalf(role: .primary,
                        frame: RemoteCellFrame(id: RemoteRole.primary.rawValue, x: 0, y: 0,
                                               width: width, height: (height - spacing) / 2)),
                   RockerHalf(role: .secondary,
                        frame: RemoteCellFrame(id: RemoteRole.secondary.rawValue,
                                               x: 0, y: (height + spacing) / 2,
                                               width: width, height: (height - spacing) / 2))]
            ZStack(alignment: .topLeading) {
                ForEach(halves, id: \.role) { half in
                    if let slot = cell.roles[half.role] {
                        keyButton(title: slot.label.isEmpty ? directionGlyph(half.role) : localized(slot.label),
                                  action: slot.action, press: cell.press, prominent: false,
                                  frame: half.frame, id: "\(cell.id).\(half.role.rawValue)")
                            .position(x: half.frame.x + half.frame.width / 2,
                                      y: half.frame.y + half.frame.height / 2)
                    }
                }
            }
            .frame(width: frame.width, height: frame.height)
        }
    }

    private func dpadButton(_ cell: RemoteCell, _ role: RemoteRole, _ unit: RemoteCellFrame,
                            _ cellFrame: RemoteCellFrame) -> some View {
        let label = cell.roles[role]?.label ?? ""
        return keyButton(title: label.isEmpty ? directionGlyph(role) : localized(label),
                         action: cell.roles[role]?.action ?? .none, press: dpadPress(role),
                         prominent: role == .center,
                         frame: RemoteCellFrame(id: unit.id, x: unit.x, y: unit.y,
                                                width: unit.width, height: unit.height),
                         id: "\(cell.id).\(role.rawValue)")
            .position(x: unit.x + unit.width / 2, y: unit.y + unit.height / 2)
    }

    /// Enter is a keystroke, not a scroll: holding it would spam the host. The
    /// directions keep the cell's `hold` so the host autorepeats.
    private func dpadPress(_ role: RemoteRole) -> RemotePress {
        role == .center ? .tap : .hold
    }

    private func keyButton(title: String, action: RemoteAction, press: RemotePress,
                           prominent: Bool, frame: RemoteCellFrame, id: String) -> some View {
        PressableKeyButton(
            title: title,
            isProminent: prominent,
            minHeight: 40,
            onPress: {
                sendDown(action)
                if press == .tap { sendUp(action) }
            },
            onRelease: {
                if press == .hold { sendUp(action) }
            },
            allowsSwipe: false,
            accessibilityIdentifier: "remote-\(id)"
        )
        .frame(width: frame.width, height: frame.height)
    }

    private func sendDown(_ action: RemoteAction) {
        switch action.kind {
        case .key:
            if let keycode = action.keycode { ble.sendKeyDown(modifiersMask: action.modifiers, keycode: keycode) }
        case .consumer:
            if let usage = action.usage { ble.sendConsumerDown(usage: usage) }
        case .none:
            break
        }
    }

    private func sendUp(_ action: RemoteAction) {
        switch action.kind {
        case .key:
            if let keycode = action.keycode { ble.sendKeyUp(keycode: keycode) }
        case .consumer:
            ble.sendConsumerUp()
        case .none:
            break
        }
    }

    private func directionGlyph(_ role: RemoteRole) -> String {
        switch role {
        case .up: return "▲"
        case .down: return "▼"
        case .left: return "◀"
        case .right: return "▶"
        case .center: return "⏎"
        case .primary: return "+"
        case .secondary: return "−"
        }
    }



    /// A bad bundled template is reported, never silently repaired: the same
    /// decoder is what the unit tests run, so this only guards a packaging bug.
    private func loadBundledTemplate() {
        guard let url = Bundle.main.url(forResource: "RemoteTemplate.tv-default", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            template = RemoteTemplate.defaultTemplate
            loadNote = localized("Шаблон пульта не знайдено у пакунці")
            return
        }
        switch RemoteTemplateDecoder.decode(data) {
        case let .loaded(loaded, notes):
            template = loaded.cells.isEmpty ? RemoteTemplate.defaultTemplate : loaded
            loadNote = notes.isEmpty ? nil
                : localizedFormat("Деякі кнопки пульта не працюють (%d): перевірте шаблон", notes.count)
        case .rejected(let reason):
            template = RemoteTemplate.defaultTemplate
            loadNote = localizedFormat("Шаблон пульта не прочитано: %@", reason)
        }
    }
}
