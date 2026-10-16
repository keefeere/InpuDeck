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
/// - Sending, deleting and editing commands require an unlocked state.
struct CommandPaletteView: View {
    @ObservedObject var ble: RemoteInputController
    var isActiveTab = true

    @StateObject private var store = CommandletStore()
    @Environment(\.scenePhase) private var scenePhase

    // Independent session assumption; never overwrite other tabs.
    @State private var selectedLayout: KeyboardLayout = .englishUS
    @AppStorage("hostLayoutShortcut") private var shortcutRawValue = HostLayoutShortcut.controlSpace.rawValue

    @State private var unlockState = CommandUnlockState()
    @State private var authContext: LAContext?
    // Async tasks capture a View value; mirror environment/plain inputs in
    // State so authentication completion observes the latest lifecycle values.
    @State private var isForegroundActive = false
    @State private var tabIsActive = false
    private var isUnlocked: Bool { unlockState.isUnlocked }
    @State private var visibleIDs: Set<UUID> = []
    @State private var authMessage: String?
    @State private var editingCommandlet: Commandlet?
    @State private var showsNewCommandlet = false
    @State private var deletingCommandlet: Commandlet?
    @State private var sendStatus: String?
    @State private var sendFailed = false
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
                    ToolbarItem(placement: .navigationBarTrailing) {
                        layoutButton
                    }
                }
                .environment(\.editMode, $editMode)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if let sendStatus {
                        Label(sendStatus, systemImage: sendFailed ? "exclamationmark.triangle" : "checkmark.circle")
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
                onActivity: { if isUnlocked { scheduleRelock() } },
                onSave: { commandlet in
                    guard store.add(commandlet) else {
                        let message = store.storageError ?? localized("Не вдалося зберегти команди")
                        store.storageError = nil
                        return message
                    }
                    showsNewCommandlet = false
                    return nil
                }
            )
        }
        .sheet(item: $editingCommandlet) { commandlet in
            CommandletEditorView(
                commandlet: commandlet,
                isNew: false,
                onActivity: { if isUnlocked { scheduleRelock() } },
                onSave: { updated in
                    guard isUnlocked, isForegroundActive, tabIsActive else {
                        return localized("Не вдалося розблокувати")
                    }
                    guard store.update(updated) else {
                        let message = store.storageError ?? localized("Не вдалося зберегти команди")
                        store.storageError = nil
                        return message
                    }
                    editingCommandlet = nil
                    return nil
                }
            )
        }
        .confirmationDialog(
            "Видалити команду?",
            isPresented: Binding(
                get: { deletingCommandlet != nil },
                set: { if !$0 { deletingCommandlet = nil } }
            ),
            titleVisibility: .visible,
            presenting: deletingCommandlet
        ) { commandlet in
            Button(role: .destructive) {
                delete(commandlet)
                deletingCommandlet = nil
            } label: {
                Text(localized("Видалити"))
            }
            Button(role: .cancel) {
                deletingCommandlet = nil
            } label: {
                Text(localized("Скасувати"))
            }
        } message: { commandlet in
            Text(localizedFormat(
                "«%@» буде видалено назавжди.",
                displayTitle(commandlet)
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
        .alert(localized("Помилка збереження"), isPresented: Binding(
            get: { store.storageError != nil },
            set: { if !$0 { store.storageError = nil } }
        )) {
            Button(localized("OK")) { store.storageError = nil }
        } message: {
            Text(store.storageError ?? "")
        }
        .onAppear {
            isForegroundActive = scenePhase == .active
            tabIsActive = isActiveTab
        }
        .onChange(of: scenePhase) { _, phase in
            isForegroundActive = phase == .active
            switch phase {
            case .active:
                if tabIsActive, unlockState.becameActive() { completeUnlock() }
            case .inactive:
                // Face ID itself may deactivate the scene. Hide private UI,
                // but retain its authentication request and queued action.
                hidePrivateUI()
                unlockState.becameInactive()
                if unlockState.requestID == nil { pendingAction = nil }
            case .background:
                lock()
            @unknown default:
                lock()
            }
        }
        .onChange(of: isActiveTab) { _, active in
            tabIsActive = active
            lock()
            if active { selectedLayout = .englishUS }
        }
        .onDisappear {
            tabIsActive = false
            lock()
        }
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
                    onDelete: { confirmDelete(commandlet) }
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

    private var layoutButton: some View {
        Button {
            changeLayout(synchronizeHost: true)
        } label: {
            Text("UA/EN")
                .font(.system(.caption, design: .monospaced).weight(.semibold))
                .foregroundStyle(Color.primary)
                .frame(minWidth: 44, minHeight: 32)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }
        .buttonStyle(ShortAndLongPressButtonStyle(
            longPressLabel: localized("Змінити лише екранну розкладку"),
            onLongPress: { changeLayout(synchronizeHost: false) }
        ))
        .accessibilityLabel("Змінити мову")
        .accessibilityValue(selectedLayout.shortName)
        .accessibilityHint("Довге натискання змінює лише екранну розкладку")
    }

    private func changeLayout(synchronizeHost: Bool) {
        let next: KeyboardLayout = selectedLayout == .englishUS ? .ukrainianEnhanced : .englishUS
        if synchronizeHost {
            guard ble.isReady else { return }
            let command = selectedShortcut.command
            guard ble.sendKeyTaps([(command.modifiers, command.keycode)]) else { return }
        }
        // Same contract as the keyboard: short = host + local, long = local
        // only, allowing manual alignment without sending a shortcut.
        selectedLayout = next
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

    /// Authenticate before presenting confirmation, never on its dismiss path.
    @MainActor
    private func confirmDelete(_ commandlet: Commandlet) {
        guard requireUnlock(.confirmDelete(commandlet)) else { return }
        deletingCommandlet = commandlet
    }

    @MainActor
    private func delete(_ commandlet: Commandlet) {
        guard isUnlocked, isForegroundActive, tabIsActive else { return }
        hideTasks[commandlet.id]?.cancel()
        hideTasks[commandlet.id] = nil
        visibleIDs.remove(commandlet.id)
        store.delete(commandlet)
    }

    @MainActor
    private func send(_ commandlet: Commandlet) {
        guard ble.isReady, tabIsActive, isForegroundActive else { return }
        guard requireUnlock(.send(commandlet)) else { return }
        guard unlockState.canSendCommands(isForegroundActive: isForegroundActive, isActiveTab: tabIsActive) else { return }
        sendFailed = true
        let finalLayout: KeyboardLayout
        var unsupported: [Character]
        var taps: [(modifiers: UInt8, keycode: UInt8)]
        switch commandlet.syntax {
        case .text:
            let plan = TextTypingPlanner.makePlan(
                for: commandlet.body,
                startingLayout: selectedLayout,
                layoutShortcut: selectedShortcut
            )
            finalLayout = plan.finalLayout
            unsupported = plan.unsupportedCharacters
            taps = plan.taps
        case .keys:
            guard !KeyComboParser.hasErrors(commandlet.body) else {
                sendStatus = localized("Команду не надіслано: виправте синтаксис.")
                sendStatusToken += 1
                return
            }
            let plan = KeyComboPlanner.makePlan(
                for: commandlet.body,
                startingLayout: selectedLayout,
                layoutShortcut: selectedShortcut
            )
            finalLayout = plan.finalLayout
            unsupported = plan.unsupportedCharacters
            taps = plan.taps
        }
        // Never execute a truncated command (potentially a dangerous one).
        guard unsupported.isEmpty else {
            sendStatus = localized("Команду не надіслано: непідтримувані символи.")
            sendStatusToken += 1
            return
        }
        guard !taps.isEmpty else { return }
        guard ble.sendKeyTaps(taps) else {
            sendStatus = localized("Команду не надіслано: транспорт не прийняв дані.")
            sendStatusToken += 1
            return
        }
        sendFailed = false
        selectedLayout = finalLayout
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
        case send(Commandlet)
        case reveal(UUID)
        case edit(Commandlet)
        case duplicate(Commandlet)
        case copy(Commandlet)
        case confirmDelete(Commandlet)
    }

    /// Starts an unlock for `action`, which runs once the session unlocks.
    @MainActor
    private func requireUnlock(_ action: PendingAction) -> Bool {
        guard tabIsActive, isForegroundActive else { return false }
        guard !isUnlocked else { return true }
        guard unlockState.requestID == nil else { return false }
        pendingAction = action
        beginUnlock()
        return false
    }

    /// Marks the session unlocked and runs the queued sensitive action.
    @MainActor
    private func completeUnlock() {
        scheduleRelock()
        guard let action = pendingAction else { return }
        pendingAction = nil
        perform(action)
    }

    /// Prompts for Face ID/Touch ID; when biometrics are unavailable the
    /// system offers the device passcode instead.
    @MainActor
    private func beginUnlock() {
        guard tabIsActive, isForegroundActive,
              let requestID = unlockState.begin() else { return }
        let context = LAContext()
        authContext = context
        Task { @MainActor in
            // Allow the menu or alert action to finish first.
            await Task.yield()
            guard unlockState.requestID == requestID else { return }
            var policyError: NSError?
            guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &policyError) else {
                unlockState.lock()
                authContext = nil
                authMessage = policyError?.localizedDescription ?? localized("Розблокування недоступне")
                return
            }
            do {
                let success = try await context.evaluatePolicy(
                    .deviceOwnerAuthentication,
                    localizedReason: localized("Відкрити команди")
                )
                guard unlockState.requestID == requestID else { return }
                authContext = nil
                guard success else {
                    unlockState.lock()
                    authMessage = localized("Не вдалося розблокувати")
                    return
                }
                if unlockState.authenticated(requestID, isActive: isForegroundActive && tabIsActive) {
                    completeUnlock()
                }
            } catch {
                guard unlockState.requestID == requestID else { return }
                unlockState.lock()
                authContext = nil
                switch (error as? LAError)?.code {
                case .userCancel, .systemCancel, .appCancel:
                    pendingAction = nil
                default:
                    authMessage = error.localizedDescription
                }
            }
        }
    }

    /// Executes a queued sensitive action after the session is unlocked.
    @MainActor
    private func perform(_ action: PendingAction) {
        guard isUnlocked, tabIsActive, isForegroundActive else { return }
        switch action {
        case let .send(commandlet):
            send(commandlet)
        case let .reveal(id):
            withAnimation { visibleIDs.insert(id) }
            scheduleAutoHide(id)
        case let .edit(commandlet):
            editingCommandlet = commandlet
        case let .duplicate(commandlet):
            _ = store.duplicate(commandlet)
        case let .copy(commandlet):
            UIPasteboard.general.string = commandlet.body
        case let .confirmDelete(commandlet):
            deletingCommandlet = commandlet
        }
    }

    @MainActor
    private func scheduleRelock() {
        unlockTask?.cancel()
        unlockTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.unlockDuration)
            guard !Task.isCancelled else { return }
            lock()
        }
    }

    @MainActor
    private func hidePrivateUI() {
        unlockTask?.cancel()
        unlockTask = nil
        hideTasks.values.forEach { $0.cancel() }
        hideTasks = [:]
        visibleIDs.removeAll()
        editingCommandlet = nil
        showsNewCommandlet = false
        deletingCommandlet = nil
    }

    @MainActor
    private func lock() {
        unlockState.lock()
        authContext?.invalidate()
        authContext = nil
        pendingAction = nil
        authMessage = nil
        hidePrivateUI()
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
            // Destructive role would animate removal before confirmation.
            Button {
                onDelete()
            } label: {
                Label(localized("Видалити"), systemImage: "trash")
            }
            .tint(.red)
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
            Button(action: onDuplicate) {
                Label(localized("Дублювати"), systemImage: "plus.square.on.square")
            }
            Button(action: onCopy) {
                Label(localized("Копіювати як текст"), systemImage: "doc.on.doc")
            }
            Button(role: .destructive, action: onDelete) {
                Label(localized("Видалити"), systemImage: "trash")
            }
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
    var onActivity: () -> Void = {}
    let onSave: (Commandlet) -> String?
    @State private var saveError: String?

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
                    Button(localized(isNew ? "Додати" : "Зберегти")) {
                        saveError = onSave(commandlet)
                        if saveError == nil { dismiss() }
                    }
                    .disabled(
                        commandlet.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || hasParseErrors
                    )
                }
            }
            .alert(localized("Помилка збереження"), isPresented: Binding(
                get: { saveError != nil },
                set: { if !$0 { saveError = nil } }
            )) {
                Button(localized("OK")) { saveError = nil }
            } message: {
                Text(saveError ?? "")
            }
            .onChange(of: commandlet) { _, _ in onActivity() }
            .onAppear {
                bodyFocused = true
                onActivity()
            }
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
