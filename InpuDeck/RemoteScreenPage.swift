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
    /// Shared with the settings screen, so a template changed there is drawn
    /// here the moment it is stored.
    @ObservedObject var catalog: RemoteTemplateCatalog
    /// Presents the templates screen directly — not the general settings.
    @State private var showsTemplates = false
    let hostKey: String
    private let header: Header

    private let gap: CGFloat = 10

    init(
        ble: RemoteInputController,
        isActiveTab: Bool,
        catalog: RemoteTemplateCatalog,
        hostKey: String,
        @ViewBuilder header: () -> Header
    ) {
        self.ble = ble
        self.isActiveTab = isActiveTab
        self.catalog = catalog
        self.hostKey = hostKey
        self.header = header()
    }

    var body: some View {
        VStack(spacing: 12) {
            header

            if let loadNote = catalog.bundledNote {
                Text(loadNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("remoteLoadNote")
            }

            templateBar

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
        .task {
            catalog.refresh(hostKey: hostKey)
        }
        .onChange(of: hostKey) { _, newKey in catalog.refresh(hostKey: newKey) }
        .onChange(of: isActiveTab) { _, active in
            // Holding a direction key while swiping away must not leave the TV
            // scrolling forever.
            if !active { ble.releaseAllInput() }
        }
        .onDisappear { ble.releaseAllInput() }
        .sheet(isPresented: $showsTemplates) {
            NavigationStack {
                RemoteTemplatesSettingsView(catalog: catalog)
            }
        }
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
        let columns = max(1, catalog.template.columns)
        let rows = max(1, catalog.template.rows)
        let spacing = Double(gap)
        let cellWidth = max(24, (Double(available.width) - spacing * Double(columns - 1)) / Double(columns))
        let cellHeight = min(max(40, cellWidth * 1.15),
                             (Double(available.height) - spacing * Double(rows - 1)) / Double(rows))
        return CGSize(width: cellWidth * Double(columns) + spacing * Double(columns - 1),
                      height: cellHeight * Double(rows) + spacing * Double(rows - 1))
    }

    private func items(in size: CGSize) -> [Item] {
        let template = catalog.template
        let frames = template.frames(size: (Double(size.width), Double(size.height)), gap: Double(gap))
        return template.cells.compactMap { cell in
            // A spacer exists only to keep the decoder's grid coverage honest.
            // Painting it would put a dead, unlabelled tile on the remote, which
            // reads as a broken button.
            guard cell.control != .spacer else { return nil }
            guard let frame = frames.first(where: { $0.id == cell.id }) else { return nil }
            return Item(id: cell.id, cell: cell, frame: frame)
        }
    }

    /// The cell's rect scaled around its own centre, so a `scale: 1.3` button
    /// fills only the middle of its tile instead of overlapping the neighbours.
    private func scaledFrame(_ frame: RemoteCellFrame, scale: Double) -> RemoteCellFrame {
        let w = frame.width * scale
        let h = frame.height * scale
        return RemoteCellFrame(id: frame.id, x: frame.x + (frame.width - w) / 2,
                              y: frame.y + (frame.height - h) / 2, width: w, height: h)
    }

    @ViewBuilder
    private func render(_ cell: RemoteCell, _ frame: RemoteCellFrame) -> some View {
        let frame = scaledFrame(frame, scale: cell.scale)
        switch cell.control {
        case .button, .spacer:
            // `items` never hands a spacer here; the branch keeps the switch
            // exhaustive without ever drawing a dead tile.
            keyButton(title: localized(cell.label), action: cell.action, press: cell.press,
                      prominent: cell.tone == .prominent, frame: frame, id: cell.id,
                      fontScale: cell.fontScale)

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
                                  frame: half.frame, id: "\(cell.id).\(half.role.rawValue)",
                                  fontScale: cell.fontScale)
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
                         id: "\(cell.id).\(role.rawValue)",
                         fontScale: cell.fontScale)
            .position(x: unit.x + unit.width / 2, y: unit.y + unit.height / 2)
    }

    /// Enter is a keystroke, not a scroll: holding it would spam the host. The
    /// directions keep the cell's `hold` so the host autorepeats.
    private func dpadPress(_ role: RemoteRole) -> RemotePress {
        role == .center ? .tap : .hold
    }

    private func keyButton(title: String, action: RemoteAction, press: RemotePress,
                           prominent: Bool, frame: RemoteCellFrame, id: String,
                           fontScale: Double = 1.0) -> some View {
        PressableKeyButton(
            title: title,
            isProminent: prominent,
            fontSize: fontScale == 1.0 ? nil : CGFloat(16 * fontScale),
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
            if let keycode = action.keycode {
                if keycode == 0 { ble.setModifiers(action.modifiers) }
                else { ble.sendKeyDown(modifiersMask: action.modifiers, keycode: keycode) }
            }
        case .consumer:
            if let usage = action.usage { ble.sendConsumerDown(usage: usage) }
        case .none:
            break
        }
    }

    private func sendUp(_ action: RemoteAction) {
        switch action.kind {
        case .key:
            if let keycode = action.keycode {
                if keycode == 0 { ble.setModifiers(0) }
                else { ble.sendKeyUp(keycode: keycode) }
            }
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



    /// The template this host should draw, drawn from the shared catalog.
    /// The catalog owns the file store, so a change made in the settings screen
    /// is picked up the moment it lands.
    @ViewBuilder
    private var templateBar: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(catalog.descriptors, id: \.id) { descriptor in
                    Button {
                        catalog.select(id: descriptor.id)
                    } label: {
                        if descriptor.id == catalog.selectedTemplateID {
                            Label(descriptor.name, systemImage: "checkmark")
                        } else {
                            Text(descriptor.name)
                        }
                    }
                    .accessibilityIdentifier("remoteTemplate-\(descriptor.id)")
                }
            } label: {
                Label(catalog.template.name, systemImage: "square.grid.2x2")
                    .font(.caption)
            }
            .fixedSize()
            .buttonStyle(.borderless)
            .accessibilityIdentifier("remoteTemplateMenu")
            Spacer()

            Button {
                showsTemplates = true
            } label: {
                Label(localized("Шаблони"), systemImage: "square.grid.2x2.fill")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("remoteTemplateSettings")
        }
        .padding(.horizontal, 2)
    }
}
