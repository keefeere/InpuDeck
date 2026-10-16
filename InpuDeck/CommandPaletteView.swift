import SwiftUI
import LocalAuthentication
import UIKit

/// The "Команди" tab: a palette of reusable input commands (plain text or
/// key combos) that can be sent to the active host.
///
/// Privacy model:
/// - Command bodies are hidden until the user unlocks with Local
///   Authentication: Face ID/Touch ID when available, with the device
///   passcode as the system-provided fallback (no separate app password).
/// - Tapping a row reveals only that command's body for 30 seconds.
/// - The palette re-locks automatically after 60 seconds.
/// - Deleting and editing commands requires an unlocked state.
struct CommandPaletteView: View {
    @ObservedObject var ble: RemoteInputController

    @StateObject private var store = CommandletStore()
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage("targetKeyboardLayout") private var layoutRawValue = KeyboardLayout.englishUS.rawValue
    @AppStorage("hostLayoutShortcut") private var shortcutRawValue = HostLayoutShortcut.controlSpace.rawValue

    @State private var isUnlocked = false
    @State private var visibleIDs: Set<UUID> = []
    @State private var authMessage: String?
    @State private var editingCommandlet: Commandlet?
    @State private var showsNewCommandlet = false
    @State private var deletingCommandlet: Commandlet?
    @State private var sendStatus: String?
    @State private var sendStatusToken = 0
    @State private var editMode: EditMode = .inactive
    /// Sensitive action waiting for the next successful unlock.
    @State private var pendingAction: PendingAction?

    @State private var unlockTask: Task<Void, Never>?
    @State private var hideTasks: [UUID: Task<Void, Never>] = [:]

    /// How long a revealed body stays visible before auto-hiding.
    private static let revealDuration: UInt64 = 30 * 1_000_000_000
    /// How long the palette stays unlocked before re-locking.
    private static let unlockDuration: UInt64 = 60 * 1_000_000_000

    private var selectedLayout: KeyboardLayout {
        KeyboardLayout(rawValue: layoutRawValue) ?? .englishUS
    }

    private var selectedShortcut: HostLayoutShortcut {
        HostLayoutShortcut(rawValue: shortcutRawValue) ?? .controlSpace
    }

    var body: some View {
        NavigationStack {
            commandList
                .navigationTitle(localized("Команди"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        EditButton()
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
                    showsNewCommandlet = false
                }
            )
        }
        .sheet(item: $editingCommandlet) { commandlet in
            CommandletEditorView(
                commandlet: commandlet,
                isNew: false,
                onSave: { updated in
                    store.update(updated)
                    editingCommandlet = nil
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
            Button(role: .destructive) {
                if let commandlet = deletingCommandlet {
                    delete(commandlet)
                }
                deletingCommandlet = nil
            } label: {
                Text(localized("Видалити"))
            }
            Button(role: .cancel) {
                deletingCommandlet = nil
            } label: {
                Text(localized("Скасувати"))
            }
        } message: {
            Text(localizedFormat(
                "«%@» буде видалено назавжди.",
                displayTitle(deletingCommandlet)
            ))
        }
        .alert(localized("Не вдалося розблокувати"), isPresented: Binding(
            get: { authMessage != nil },
            set: { if !$0 { authMessage = nil } }
        )) {
            Button(localized("Спробувати ще")) { beginUnlock() }
            Button(localized("Скасувати"), role: .cancel) { pendingAction = nil }
        } message: {
            Text(authMessage ?? "")
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                setUnlocked(false)
            }
        }
        .onDisappear { setUnlocked(false) }
    }

    // MARK: - List

    private var commandList: some View {
        List {
            ForEach(store.commandlets) { commandlet in
                CommandPaletteRow(
                    commandlet: commandlet,
                    isLocked: !isUnlocked,
                    isRevealed: visibleIDs.contains(commandlet.id),
                    isReady: ble.isReady,
                    onReveal: { reveal(commandlet) },
                    onSend: { send(commandlet) },
                    onEdit: { edit(commandlet) },
                    onDuplicate: { duplicate(commandlet) },
                    onCopy: { copyAsText(commandlet) },
                    onDelete: { deletingCommandlet = commandlet }
                )
            }
            .onMove { source, destination in
                store.move(from: source, to: destination)
            }

            Button {
                showsNewCommandlet = true
            } label: {
                Label(localized("Додати команду"), systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }

            if store.commandlets.isEmpty {
                emptyState
            }
        }
        .listStyle(.insetGrouped)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "command.square")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(localized("Поки що немає команд"))
                .font(.headline)
            Text(localized("Додайте текст або комбінацію клавіш і надсилайте їх на пристрій одним дотиком."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    /// Reveal the tapped command's body, prompting for unlock first if locked.
    @MainActor
    private func reveal(_ commandlet: Commandlet) {
        guard requireUnlock(.reveal(commandlet.id)) else { return }
        withAnimation { visibleIDs.insert(commandlet.id) }
        scheduleAutoHide(commandlet.id)
    }

    /// Edit requires an unlocked state.
    @MainActor
    private func edit(_ commandlet: Commandlet) {
        guard requireUnlock(.edit(commandlet)) else { return }
        editingCommandlet = commandlet
    }

    /// Duplicate requires an unlocked state (the copy contains the body).
    @MainActor
    private func duplicate(_ commandlet: Commandlet) {
        guard requireUnlock(.duplicate(commandlet)) else { return }
        _ = store.duplicate(commandlet)
    }

    /// Copying the body to the clipboard requires an unlocked state.
    @MainActor
    private func copyAsText(_ commandlet: Commandlet) {
        guard requireUnlock(.copy(commandlet)) else { return }
        UIPasteboard.general.string = commandlet.body
    }

    /// Delete requires an unlocked state (the confirmation dialog is shown first).
    @MainActor
    private func delete(_ commandlet: Commandlet) {
        guard requireUnlock(.delete(commandlet)) else { return }
        hideTasks[commandlet.id]?.cancel()
        hideTasks[commandlet.id] = nil
        visibleIDs.remove(commandlet.id)
        store.delete(commandlet)
    }

    private func send(_ commandlet: Commandlet) {
        guard ble.isReady else { return }
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

    // MARK: - Unlocking (Local Authentication)
    //
    // Face ID/Touch ID is used whenever it is available; the system itself
    // falls back to the device passcode (LAPolicy.deviceOwnerAuthentication),
    // so no separate app password is needed.

    /// Sensitive command actions that require an unlocked session.
    private enum PendingAction {
        case reveal(UUID)
        case edit(Commandlet)
        case duplicate(Commandlet)
        case copy(Commandlet)
        case delete(Commandlet)
    }

    /// Starts an unlock for `action`, which runs once the session unlocks.
    @MainActor
    private func requireUnlock(_ action: PendingAction) -> Bool {
        guard !isUnlocked else { return true }
        pendingAction = action
        beginUnlock()
        return false
    }

    /// Marks the session unlocked and runs the queued sensitive action.
    @MainActor
    private func completeUnlock() {
        setUnlocked(true)
        guard let action = pendingAction else { return }
        pendingAction = nil
        perform(action)
    }

    /// Prompts for Face ID/Touch ID; when biometrics are unavailable the
    /// system offers the device passcode instead.
    @MainActor
    private func beginUnlock() {
        let context = LAContext()
        var policyError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &policyError) else {
            authMessage = localized("Розблокування недоступне")
            return
        }
        context.cancelButtonTitle = localized("Скасувати")
        context.fallbackButtonTitle = localized("Код-пароль")
        Task { @MainActor in
            do {
                try await context.evaluatePolicy(
                    .deviceOwnerAuthentication,
                    localizedReason: localized("Відкрити команди")
                )
                completeUnlock()
            } catch {
                let code = (error as? LAError)?.code
                switch code {
                case .userCancel, .systemCancel:
                    // The user dismissed the prompt; drop the queued action.
                    pendingAction = nil
                case .biometryNotAvailable, .biometryLockout:
                    authMessage = localized("Біометрія недоступна, введіть код-пароль")
                default:
                    authMessage = localized("Не вдалося розблокувати")
                }
            }
        }
    }

    /// Executes a queued sensitive action after the session is unlocked.
    @MainActor
    private func perform(_ action: PendingAction) {
        switch action {
        case let .reveal(id):
            withAnimation { visibleIDs.insert(id) }
            scheduleAutoHide(id)
        case let .edit(commandlet):
            editingCommandlet = commandlet
        case let .duplicate(commandlet):
            _ = store.duplicate(commandlet)
        case let .copy(commandlet):
            UIPasteboard.general.string = commandlet.body
        case let .delete(commandlet):
            hideTasks[commandlet.id]?.cancel()
            hideTasks[commandlet.id] = nil
            visibleIDs.remove(commandlet.id)
            store.delete(commandlet)
        }
    }

    @MainActor
    private func setUnlocked(_ value: Bool) {
        isUnlocked = value
        unlockTask?.cancel()
        unlockTask = nil
        if value {
            // Refresh the auto-hide timers for already revealed bodies and
            // schedule the re-lock.
            for id in visibleIDs { scheduleAutoHide(id) }
            unlockTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: Self.unlockDuration)
                guard !Task.isCancelled else { return }
                withAnimation {
                    isUnlocked = false
                    visibleIDs.removeAll()
                }
                hideTasks.values.forEach { $0.cancel() }
                hideTasks = [:]
            }
        } else {
            hideTasks.values.forEach { $0.cancel() }
            hideTasks = [:]
            withAnimation { visibleIDs.removeAll() }
        }
    }

    /// Hide a single revealed body after the reveal timeout.
    @MainActor
    private func scheduleAutoHide(_ id: UUID) {
        hideTasks[id]?.cancel()
        hideTasks[id] = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.revealDuration)
            guard !Task.isCancelled else { return }
            withAnimation { visibleIDs.remove(id) }
        }
    }

    // MARK: - Helpers

    private func displayTitle(_ commandlet: Commandlet?) -> String {
        guard let commandlet else { return "" }
        return commandlet.name.isEmpty ? localized("Без назви") : commandlet.name
    }
}

// MARK: - Row

/// One commandlet card in the palette list. Tapping the body area reveals this
/// command's text (after biometric unlock); the play button sends it without
/// revealing anything on screen.
private struct CommandPaletteRow: View {
    let commandlet: Commandlet
    let isLocked: Bool
    let isRevealed: Bool
    let isReady: Bool
    let onReveal: () -> Void
    let onSend: () -> Void
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
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                    Text(syntaxTitle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                if isRevealed {
                    Text(commandlet.body)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                } else if commandlet.body.isEmpty {
                    Text(localized("Порожня команда"))
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                } else {
                    Text(String(repeating: "•", count: min(max(commandlet.body.count, 12), 40)))
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)

            Button(action: onSend) {
                Image(systemName: "play.fill")
                    .font(.title3)
                    .frame(width: 34, height: 34)
                    .background(Color(.tertiarySystemFill))
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .buttonStyle(.borderless)
            .disabled(!isReady || commandlet.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel(localizedFormat("Надіслати команду %@", title))
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: onReveal)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label(localized("Видалити"), systemImage: "trash")
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button {
                onEdit()
            } label: {
                Label(localized("Редагувати"), systemImage: "pencil")
            }
        }
        .opacity(isReady ? 1 : 0.75)
        .accessibilityLabel(accessibilityText)
        .contextMenu {
            Button(action: onEdit) {
                Label(localized("Редагувати"), systemImage: "pencil")
            }
            .disabled(isLocked)
            Button(action: onDuplicate) {
                Label(localized("Дублювати"), systemImage: "plus.square.on.square")
            }
            .disabled(isLocked)
            Button(action: onCopy) {
                Label(localized("Копіювати як текст"), systemImage: "doc.on.doc")
            }
            .disabled(isLocked)
        }
    }

    private var title: String {
        commandlet.name.isEmpty ? localized("Без назви") : commandlet.name
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
        return localizedFormat("Надіслати команду %@", title)
    }
}

// MARK: - Editor

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
                    TextField(localized("Назва"), text: $commandlet.name)
                    Picker(localized("Синтаксис"), selection: $commandlet.syntax) {
                        Text(localized("Текст")).tag(CommandletSyntax.text)
                        Text(localized("Клавіші")).tag(CommandletSyntax.keys)
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    TextField(
                        localized("Тіло"),
                        text: $commandlet.body,
                        axis: .vertical
                    )
                    .lineLimit(6...14)
                    .focused($bodyFocused)
                    if commandlet.syntax == .keys {
                        keyLinePreview
                    }
                } header: {
                    Text(localized("Тіло команди"))
                } footer: {
                    Text(commandlet.syntax == .keys
                         ? localized("Кожен рядок — окрема команда: Ctrl+Shift+Esc, F5, Enter або текст. Порожні рядки і # — коментарі.")
                         : localized("Надсилається як звичайний текст зі зміною розкладки."))
                        .font(.caption)
                }
            }
            .navigationTitle(isNew ? localized("Нова команда") : localized("Редагувати"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Скасувати") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "Додати" : "Зберегти") {
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
                    Text(localizedFormat("Рядок %@", String(parse.line)))
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
            return localizedFormat("Невідомий токен: %@", token)
        case .multipleKeys:
            return localized("Дві та більше клавіші в одному рядку")
        case .text(let text):
            return text.isEmpty ? localized("Порожній рядок") : localizedFormat("Текст: %@", text)
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
            guard let scalar = UnicodeScalar(value) else { return nil }
            return String(scalar)
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
