import SwiftUI
import LocalAuthentication
import UIKit

/// The "Команди" tab: a palette of reusable input commands (plain text or
/// key combos) that can be sent to the active host with one tap. The body is
/// hidden until the user unlocks the tab with Face ID / device passcode.
struct CommandPaletteView: View {
    @ObservedObject var ble: RemoteInputController

    @StateObject private var store = CommandletStore()
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage("targetKeyboardLayout") private var layoutRawValue = KeyboardLayout.englishUS.rawValue
    @AppStorage("hostLayoutShortcut") private var shortcutRawValue = HostLayoutShortcut.controlSpace.rawValue

    @State private var isUnlocked = false
    @State private var authMessage: String?
    @State private var editingCommandlet: Commandlet?
    @State private var showsNewCommandlet = false
    @State private var deletingCommandlet: Commandlet?
    @State private var sendStatus: String?
    @State private var sendStatusToken = 0
    @State private var editMode: EditMode = .inactive

    private var selectedLayout: KeyboardLayout {
        KeyboardLayout(rawValue: layoutRawValue) ?? .englishUS
    }

    private var selectedShortcut: HostLayoutShortcut {
        HostLayoutShortcut(rawValue: shortcutRawValue) ?? .controlSpace
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.commandlets.isEmpty {
                    emptyState
                } else {
                    commandList
                }
            }
            .navigationTitle("Команди")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    EditButton()
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showsNewCommandlet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Додати команду")
                }
            }
            .environment(\.editMode, $editMode)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let sendStatus {
                    Label(sendStatus, systemImage: "checkmark.circle")
                        .font(.caption)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.ultraThinMaterial)
                        .task(id: sendStatusToken) {
                            try? await Task.sleep(for: .seconds(2))
                            self.sendStatus = nil
                        }
                }
            }
        }
        .sheet(isPresented: $showsNewCommandlet) {
            CommandletEditorView(
                commandlet: Commandlet(name: "", syntax: .text, body: ""),
                isNew: true,
                onSave: { commandlet in
                    store.add(commandlet)
                }
            )
        }
        .sheet(item: $editingCommandlet) { commandlet in
            CommandletEditorView(
                commandlet: commandlet,
                onSave: { updated in
                    store.update(updated)
                }
            )
        }
        .confirmationDialog(
            "Видалити команду?",
            isPresented: Binding(
                get: { deletingCommandlet != nil },
                set: { if !$0 { deletingCommandlet = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Видалити", role: .destructive) {
                if let commandlet = deletingCommandlet {
                    store.delete(commandlet)
                }
                deletingCommandlet = nil
            }
            Button("Скасувати", role: .cancel) {
                deletingCommandlet = nil
            }
        } message: {
            Text(localizedFormat("«%@» буде видалено назавжди.", deletingCommandlet?.name ?? ""))
        }
        .alert("Не вдалося розблокувати", isPresented: Binding(
            get: { authMessage != nil },
            set: { if !$0 { authMessage = nil } }
        )) {
            Button("Скасувати", role: .cancel) {}
        } message: {
            Text(authMessage ?? "")
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                isUnlocked = false
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "command.square")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Поки що немає команд")
                .font(.headline)
            Text("Додайте текст або комбінацію клавіш і надсилайте їх на пристрій одним дотиком.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                showsNewCommandlet = true
            } label: {
                Label("Додати команду", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var commandList: some View {
        List {
            ForEach(store.commandlets) { commandlet in
                CommandPaletteRow(
                    commandlet: commandlet,
                    isLocked: !isUnlocked,
                    isReady: ble.isReady,
                    onSend: { send(commandlet) },
                    onUnlock: unlock,
                    onEdit: { editingCommandlet = commandlet },
                    onDuplicate: { store.duplicate(commandlet) },
                    onCopy: { copyAsText(commandlet) },
                    onDelete: { deletingCommandlet = commandlet }
                )
            }
            .onMove { source, destination in
                store.move(from: source, to: destination)
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - Actions

    private func send(_ commandlet: Commandlet) {
        guard isUnlocked, ble.isReady else { return }
        var taps: [(modifiers: UInt8, keycode: UInt8)]
        switch commandlet.syntax {
        case .text:
            let plan = TextTypingPlanner.makePlan(
                for: commandlet.body,
                startingLayout: selectedLayout,
                layoutShortcut: selectedShortcut
            )
            if plan.finalLayout != selectedLayout {
                layoutRawValue = plan.finalLayout.rawValue
            }
            taps = plan.taps
        case .keys:
            let plan = KeyComboPlanner.makePlan(
                for: commandlet.body,
                startingLayout: selectedLayout,
                layoutShortcut: selectedShortcut
            )
            if plan.finalLayout != selectedLayout {
                layoutRawValue = plan.finalLayout.rawValue
            }
            taps = plan.taps
        }
        guard !taps.isEmpty else { return }
        ble.sendKeyTaps(taps)
        sendStatus = localizedFormat("Надіслано через %@", ble.mode.title)
        sendStatusToken += 1
    }

    private func copyAsText(_ commandlet: Commandlet) {
        guard isUnlocked else { return }
        UIPasteboard.general.string = commandlet.body
    }

    private func unlock() {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            authMessage = error?.localizedDescription ?? localized("Розблокування недоступне")
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: localized("Відкрити команди")) { success, _ in
            Task { @MainActor in
                isUnlocked = success
            }
        }
    }

}

/// One commandlet card in the palette list. While locked the body is masked
/// and tapping asks for biometric authentication instead of sending.
private struct CommandPaletteRow: View {
    let commandlet: Commandlet
    let isLocked: Bool
    let isReady: Bool
    let onSend: () -> Void
    let onUnlock: () -> Void
    let onEdit: () -> Void
    let onDuplicate: () -> Void
    let onCopy: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: syntaxIcon)
                .font(.title3)
                .frame(width: 34, height: 34)
                .background(Color(.tertiarySystemFill))
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(commandlet.name.isEmpty ? "Без назви" : commandlet.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text(syntaxTitle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                if isLocked {
                    Text(String(repeating: "•", count: min(max(commandlet.body.count, 12), 40)))
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                } else if !commandlet.body.isEmpty {
                    Text(commandlet.body)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                } else {
                    Text("Порожня команда")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 8)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if isLocked {
                onUnlock()
            } else {
                onSend()
            }
        }
        .disabled(isLocked ? false : !isReady)
        .opacity(isLocked ? 1 : (isReady ? 1 : 0.55))
        .accessibilityLabel(accessibilityText)
        .contextMenu {
            Button {
                onEdit()
            } label: {
                Label("Редагувати", systemImage: "pencil")
            }
            .disabled(isLocked)
            Button {
                onDuplicate()
            } label: {
                Label("Дублювати", systemImage: "plus.square.on.square")
            }
            .disabled(isLocked)
            Button {
                onCopy()
            } label: {
                Label("Копіювати як текст", systemImage: "doc.on.doc")
            }
            .disabled(isLocked)
            Divider()
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("Видалити", systemImage: "trash")
            }
        }
    }

    private var syntaxIcon: String {
        commandlet.syntax == .keys ? "keyboard" : "text.cursor"
    }

    private var syntaxTitle: LocalizedStringKey {
        commandlet.syntax == .keys ? "Клавіші" : "Текст"
    }

    private var accessibilityText: String {
        if isLocked {
            return localized("Команда заблокована. Натисніть, щоб розблокувати.")
        }
        if !isReady {
            return localized("Немає з'єднання. Команду не можна надіслати.")
        }
        return localizedFormat("Надіслати команду %@", commandlet.name)
    }
}

/// Sheet editor for a commandlet: name, syntax picker and the multi-line
/// body. For "keys" syntax each line is parsed live and errors are marked.
private struct CommandletEditorView: View {
    @State var commandlet: Commandlet
    var isNew = false
    let onSave: (Commandlet) -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var bodyFocused: Bool

    private var hasParseErrors: Bool {
        commandlet.syntax == .keys && KeyComboParser.hasErrors(commandlet.body)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Назва", text: $commandlet.name)
                    Picker("Синтаксис", selection: $commandlet.syntax) {
                        Text("Текст").tag(CommandletSyntax.text)
                        Text("Клавіші").tag(CommandletSyntax.keys)
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    TextField(
                        "Тіло команди",
                        text: $commandlet.body,
                        axis: .vertical
                    )
                    .lineLimit(6...14)
                    .focused($bodyFocused)
                    if commandlet.syntax == .keys {
                        keyLinePreview
                    }
                } header: {
                    Text("Тіло")
                } footer: {
                    Text(commandlet.syntax == .keys
                         ? "Кожен рядок — окрема команда: Ctrl+Shift+Esc, F5, Enter або текст. Порожні рядки і # — коментарі."
                         : "Надсилається як звичайний текст зі зміною розкладки.")
                        .font(.caption)
                }
            }
            .navigationTitle(isNew ? "Нова команда" : "Редагувати")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Скасувати") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Зберегти") {
                        onSave(commandlet)
                        dismiss()
                    }
                    .disabled(
                        commandlet.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || hasParseErrors
                    )
                }
            }
            .onAppear { bodyFocused = true }
        }
    }

    @ViewBuilder
    private var keyLinePreview: some View {
        let parses = KeyComboParser.parseBody(commandlet.body)
        if !parses.isEmpty {
            ForEach(Array(parses.enumerated()), id: \.offset) { _, parse in
                HStack(spacing: 6) {
                    Image(systemName: parse.isError ? "xmark.circle.fill" : "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(parse.isError ? .red : .green)
                    Text("Рядок \(parse.line)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(displayText(for: parse))
                        .font(.caption)
                        .lineLimit(1)
                }
            }
        }
    }

    private func displayText(for parse: KeyLineParse) -> String {
        switch parse.outcome {
        case .unknownToken(let token):
            return "Невідомий токен: \(token)"
        case .multipleKeys:
            return "Дві та більше клавіші в одному рядку"
        case .text(let text):
            return text.isEmpty ? "Порожній рядок" : "Текст: \(text)"
        case let .tap(tap):
            return comboText(for: tap)
        }
    }

    private func comboText(for tap: ParsedKeyTap) -> String {
        var parts: [String] = []
        if tap.modifiers & HID.modLeftCtrl != 0 { parts.append("Ctrl") }
        if tap.modifiers & HID.modRightCtrl != 0 { parts.append("RCtrl") }
        if tap.modifiers & HID.modLeftShift != 0 { parts.append("Shift") }
        if tap.modifiers & HID.modRightShift != 0 { parts.append("RShift") }
        if tap.modifiers & HID.modLeftAlt != 0 { parts.append("Alt") }
        if tap.modifiers & HID.modRightAlt != 0 { parts.append("AltGr") }
        if tap.modifiers & HID.modLeftGUI != 0 { parts.append("Win") }
        if tap.modifiers & HID.modRightGUI != 0 { parts.append("RWin") }
        switch tap.key {
        case let .special(keycode):
            if keycode == 0 { return parts.isEmpty ? "—" : parts.joined(separator: "+") }
            parts.append(KeyComboDisplay.name(forKeycode: keycode) ?? "0x\(String(format: "%02X", keycode))")
        case let .character(character):
            parts.append(String(character))
        }
        return parts.joined(separator: "+")
    }
}

/// Human-readable names for the HID keycodes used in the editor preview.
enum KeyComboDisplay {
    private static let names: [UInt8: String] = [
        HID.keyTab: "Tab",
        HID.keyEnter: "Enter",
        HID.keyEscape: "Esc",
        HID.keySpace: "Space",
        HID.keyBackspace: "Backspace",
        HID.keyDelete: "Delete",
        HID.keyHome: "Home",
        HID.keyEnd: "End",
        HID.keyPageUp: "PageUp",
        HID.keyPageDown: "PageDown",
        HID.keyInsert: "Insert",
        HID.keyPrintScreen: "PrintScreen",
        HID.keyScrollLock: "ScrollLock",
        HID.keyPause: "Pause",
        HID.keyLeftArrow: "←",
        HID.keyRightArrow: "→",
        HID.keyUpArrow: "↑",
        HID.keyDownArrow: "↓",
    ]

    static func name(forKeycode keycode: UInt8) -> String? {
        if let name = names[keycode] { return name }
        if (HID.keyF1...HID.keyF12).contains(keycode) {
            return "F\(Int(keycode - HID.keyF1) + 1)"
        }
        if (HID.keyA...HID.keyZ).contains(keycode) {
            let value = 0x61 + UInt32(keycode - HID.keyA)
            return String(Character(UnicodeScalar(value)))
        }
        if (HID.key1...HID.key0).contains(keycode) {
            let index = Int(keycode - HID.key1)
            return index < 9 ? "\(index + 1)" : "0"
        }
        return nil
    }
}

#Preview {
    CommandPaletteView(ble: RemoteInputController())
}
