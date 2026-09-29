import SwiftUI
import UIKit

struct ConnectionStatusView: View {
    @ObservedObject var input: RemoteInputController
    @ObservedObject private var direct: DirectHIDTransport
    @ObservedObject private var esp: BLEKeyboardBridge
    var compact = false
    @State private var showsBluetooth = false
    @State private var showsESPBridges = false
    @AppStorage("developerMode") private var developerMode = false

    init(input: RemoteInputController, compact: Bool = false) {
        self.input = input
        self.direct = input.direct
        self.esp = input.esp
        self.compact = compact
    }

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                Section("ESP-адаптери") {
                    if visibleSavedBridges.isEmpty {
                        Text("Немає збережених ESP-адаптерів")
                    } else {
                        ForEach(visibleSavedBridges) { bridge in
                            Button { input.selectESPBridge(bridge.id) } label: {
                                destinationLabel(
                                    developerMode ? bridge.diagnosticName : bridge.name,
                                    protocolIcon: Image(systemName: "cpu"),
                                    selected: input.mode == .esp && esp.selectedBridgeID == bridge.id,
                                    connected: input.mode == .esp && esp.connectedBridgeID == bridge.id
                                )
                            }
                        }
                    }
                }
                Section("Прямий Bluetooth") {
                    if visibleSavedHosts.isEmpty {
                        Text("Немає збережених BT-пристроїв")
                    } else {
                        ForEach(visibleSavedHosts) { host in
                            Button { input.selectDirectHost(host.id) } label: {
                                destinationLabel(
                                    developerMode ? host.diagnosticName : host.name,
                                    protocolIcon: Image("BluetoothProtocolIcon"),
                                    selected: input.mode == .bluetooth && direct.selectedHostID == host.id,
                                    connected: input.mode == .bluetooth && direct.connectedHostID == host.id
                                )
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    activeProtocolIcon
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: compact ? 15 : 17, height: compact ? 15 : 17)
                        .foregroundStyle(.secondary)
                    Circle().fill(input.isReady ? .green : .orange).frame(width: 7, height: 7)
                    statusLabel
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: compact ? 32 : 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .frame(maxWidth: .infinity)
            .layoutPriority(1)
            .disabled(input.isSwitching)
            .accessibilityLabel("Вибрати пристрій")
            .accessibilityValue(displayStatus)

            Menu {
                Button("Знайти ESP-адаптер", systemImage: "antenna.radiowaves.left.and.right") {
                    input.prepareESPDiscovery()
                    showsESPBridges = true
                }
                Button("Додати BT-пристрій", systemImage: "link.badge.plus") {
                    input.prepareDirectManagement()
                    showsBluetooth = true
                }
            } label: {
                Image(systemName: "link.badge.plus")
            }
            .accessibilityLabel("Пристрої та сполучення")
            .disabled(input.isSwitching)
            Button(action: input.reconnectNow) {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(input.isSwitching)
            .accessibilityLabel("Перепідключити")
        }
        .buttonStyle(.borderless)
        .sheet(isPresented: $showsBluetooth) {
            DirectBluetoothSheet(transport: direct, browser: direct.browser)
        }
        .sheet(isPresented: $showsESPBridges) {
            ESPBridgeSheet(input: input, bridge: esp)
        }
        .alert(item: firmwareSecurityIssueBinding) { issue in
            Alert(
                title: Text(issue.title),
                message: Text(issue.message),
                dismissButton: .default(Text("Зрозуміло")) {
                    esp.dismissFirmwareSecurityIssue()
                }
            )
        }
    }

    private var statusLabel: some View {
        Text(displayStatus)
            .font(compact ? .caption2 : .caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var displayStatus: String {
        if !developerMode {
            if input.mode == .esp, let issue = esp.firmwareSecurityIssue {
                return issue.title
            }
            if input.mode == .bluetooth, let id = direct.selectedHostID,
               let host = direct.savedHosts.first(where: { $0.id == id }), host.hasDisplayName {
                return host.name
            }
            if input.mode == .esp, let id = esp.selectedBridgeID,
               let bridge = esp.savedBridges.first(where: { $0.id == id }), bridge.hasDisplayName {
                return bridge.name
            }
            return localized(input.isReady ? "Підключено" : "Очікується підключення")
        }
        return input.statusText
    }

    private var activeProtocolIcon: Image {
        input.mode == .esp ? Image(systemName: "cpu") : Image("BluetoothProtocolIcon")
    }

    private var firmwareSecurityIssueBinding: Binding<ESPFirmwareSecurityIssue?> {
        Binding(
            get: { esp.firmwareSecurityIssue },
            set: { issue in
                if issue == nil { esp.dismissFirmwareSecurityIssue() }
            }
        )
    }

    @ViewBuilder
    private func destinationLabel(
        _ name: String,
        protocolIcon: Image,
        selected: Bool,
        connected: Bool
    ) -> some View {
        HStack {
            protocolIcon
                .renderingMode(.template)
                .frame(width: 20)
            Text(name)
            if connected {
                Image(systemName: "checkmark")
            } else if selected {
                Image(systemName: "clock")
            }
        }
    }

    private var visibleSavedHosts: [SavedHIDHost] {
        developerMode ? direct.savedHosts : direct.savedHosts.filter(\.hasDisplayName)
    }

    private var visibleSavedBridges: [SavedESPBridge] {
        developerMode ? esp.savedBridges : esp.savedBridges.filter(\.hasDisplayName)
    }
}

private struct ESPBridgeSheet: View {
    @ObservedObject var input: RemoteInputController
    @ObservedObject var bridge: BLEKeyboardBridge
    @Environment(\.dismiss) private var dismiss
    @AppStorage("developerMode") private var developerMode = false
    @State private var bridgeToRename: SavedESPBridge?
    @State private var bridgeToForget: SavedESPBridge?
    @State private var editedName = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(
                        bridge.statusText,
                        systemImage: bridge.isReady
                            ? "checkmark.circle.fill"
                            : "antenna.radiowaves.left.and.right"
                    )
                    .foregroundStyle(bridge.isReady ? .green : .primary)
                }

                if !visibleSavedBridges.isEmpty {
                    Section("Мої ESP-адаптери") {
                        ForEach(visibleSavedBridges) { saved in
                            bridgeRow(
                                id: saved.id,
                                name: developerMode ? saved.diagnosticName : saved.name,
                                signal: signal(for: saved.id),
                                isConnectable: true
                            )
                            .contextMenu {
                                Button("Перейменувати в застосунку", systemImage: "pencil") {
                                    editedName = saved.customName ?? saved.advertisedName ?? ""
                                    bridgeToRename = saved
                                }
                                Button("Забути", systemImage: "trash", role: .destructive) {
                                    bridgeToForget = saved
                                }
                            }
                        }
                    }
                }

                Section("Знайдені поруч") {
                    if visibleNearbyBridges.isEmpty {
                        HStack(spacing: 10) {
                            if bridge.isScanning { ProgressView() }
                            Text(bridge.isScanning ? "Шукаємо ESP-адаптери…" : "ESP-адаптерів не знайдено")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        ForEach(visibleNearbyBridges) { candidate in
                            bridgeRow(
                                id: candidate.id,
                                name: developerMode ? candidate.diagnosticName : candidate.displayName,
                                signal: candidate.signal,
                                isConnectable: candidate.isConnectable
                            )
                        }
                    }
                }

                Section {
                    Text("Одночасно активний лише один пристрій. Перед перемиканням InpuDeck відпускає натиснуті клавіші й кнопки на попередньому.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Label {
                        Text("Перше сполучення: вибери адаптер і введи його шестизначний код у системному запиті iOS. Після прошивки вікно сполучення відкрите п’ять хвилин.")
                    } icon: {
                        Image(systemName: "lock.shield")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    Text("Щоб додати новий iPhone, затисни BOOT на адаптері на 3–7 секунд. Утримання BOOT понад 10 секунд видаляє всі сполучення й відкриває налаштування заново.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("ESP-адаптери")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Закрити") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        bridge.beginDiscovery()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Повторити пошук ESP-адаптерів")
                }
            }
        }
        .onAppear {
            input.prepareESPDiscovery()
            bridge.beginDiscovery()
        }
        .onDisappear { bridge.endDiscovery() }
        .alert("Ім’я адаптера в InpuDeck", isPresented: Binding(
            get: { bridgeToRename != nil },
            set: { if !$0 { bridgeToRename = nil } }
        ), presenting: bridgeToRename) { saved in
            TextField("Ім’я", text: $editedName)
            Button("Зберегти") {
                bridge.renameBridge(saved.id, to: editedName)
                bridgeToRename = nil
            }
            Button("Скасувати", role: .cancel) { bridgeToRename = nil }
        } message: { _ in
            Text("Змінюється лише підпис у цьому застосунку. Рекламоване ім’я ESP залишається без змін.")
        }
        .confirmationDialog("Забути ESP-адаптер?", isPresented: Binding(
            get: { bridgeToForget != nil },
            set: { if !$0 { bridgeToForget = nil } }
        ), presenting: bridgeToForget) { saved in
            Button("Забути \(saved.name)", role: .destructive) {
                input.forgetESPBridge(saved.id)
                bridgeToForget = nil
            }
            Button("Скасувати", role: .cancel) { bridgeToForget = nil }
        } message: { saved in
            Text("\(saved.name) буде вилучено зі списку InpuDeck. Його можна знайти знову під час сканування.")
        }
    }

    private func bridgeRow(id: UUID, name: String, signal: Int?, isConnectable: Bool) -> some View {
        Button {
            input.selectESPBridge(id)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "cpu")
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text(name)
                    if bridge.connectedBridgeID == id {
                        Text("Підключено")
                            .font(.caption)
                            .foregroundStyle(.green)
                    } else if bridge.selectedBridgeID == id {
                        Text("Вибрано · очікуємо підключення")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let signal {
                    Text("\(signal) dBm")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if bridge.connectedBridgeID == id {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else if bridge.selectedBridgeID == id {
                    Image(systemName: "clock")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .disabled(input.isSwitching || !isConnectable)
    }

    private func signal(for id: UUID) -> Int? {
        bridge.discoveredBridges.first(where: { $0.id == id })?.signal
    }

    private var visibleSavedBridges: [SavedESPBridge] {
        developerMode ? bridge.savedBridges : bridge.savedBridges.filter(\.hasDisplayName)
    }

    private var visibleNearbyBridges: [DiscoveredESPBridge] {
        bridge.discoveredBridges.filter { candidate in
            !bridge.savedBridges.contains { $0.id == candidate.id }
                && (developerMode || candidate.hasDisplayName)
        }
    }
}

private struct DirectBluetoothSheet: View {
    @ObservedObject var transport: DirectHIDTransport
    @ObservedObject var browser: BluetoothHostBrowser
    @Environment(\.dismiss) private var dismiss
    @State private var hostToRename: SavedHIDHost?
    @State private var hostToForget: SavedHIDHost?
    @State private var editedName = ""
    @AppStorage("developerMode") private var developerMode = false
    @AppStorage("expertMode") private var expertMode = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(sheetStatusText, systemImage: transport.isReady ? "checkmark.circle.fill" : "antenna.radiowaves.left.and.right")
                        .foregroundStyle(transport.isReady ? .green : .primary)
                    if developerMode, let error = transport.lastError {
                        Text(error).font(.caption).foregroundStyle(.orange)
                    }
                }
                if !visibleSavedHosts.isEmpty {
                    Section {
                        ForEach(visibleSavedHosts) { host in
                            HStack(spacing: 12) {
                                Button { transport.connect(to: host.id) } label: {
                                    HStack(spacing: 12) {
                                        Image("BluetoothProtocolIcon")
                                            .renderingMode(.template)
                                            .frame(width: 20)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(host.name)
                                            if developerMode {
                                                Text("UUID: \(host.id.uuidString)")
                                                    .font(.caption2.monospaced()).foregroundStyle(.secondary)
                                            }
                                            Text(hostStatus(host.id))
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        if transport.connectedHostID == host.id {
                                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                        } else if transport.selectedHostID == host.id {
                                            Image(systemName: "clock").foregroundStyle(.secondary)
                                        }
                                    }
                                    .contentShape(Rectangle())
                                }
                                .disabled(!transport.canPair)
                                Menu {
                                    if developerMode {
                                        Button("Копіювати UUID", systemImage: "doc.on.doc") {
                                            UIPasteboard.general.string = host.id.uuidString
                                        }
                                    }
                                    Button("Перейменувати", systemImage: "pencil") {
                                        editedName = host.customName ?? host.discoveredName ?? ""
                                        hostToRename = host
                                    }
                                    Button("Забути в застосунку", systemImage: "trash", role: .destructive) {
                                        hostToForget = host
                                    }
                                } label: {
                                    Image(systemName: "ellipsis.circle")
                                        .padding(.vertical, 8)
                                }
                                .accessibilityLabel("Налаштування: \(host.name)")
                            }
                            .buttonStyle(.borderless)
                        }
                    } header: {
                        Text("Мої BT-пристрої")
                    } footer: {
                        if !expertMode {
                            Text("Натисни на BT-пристрій, щоб спрямувати ввід до нього. Якщо назва недоступна, задай її через меню ⋯.")
                            if developerMode {
                                Text("UUID — ідентифікатор у цьому iPhone; справжню Bluetooth MAC-адресу iOS застосунку не надає.")
                            }
                        }
                    }
                }
                if !transport.rejectedHosts.isEmpty {
                    Section {
                        ForEach(transport.rejectedHosts) { host in
                            HStack(spacing: 12) {
                                Image(systemName: "hand.raised.fill")
                                    .frame(width: 20)
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(developerMode ? host.diagnosticName : host.name)
                                    Text("Ввід до цього пристрою заблоковано")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Дозволити знову") {
                                    transport.allowRejectedHost(host.id)
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    } header: {
                        Text("Відхилені BT-пристрої")
                    } footer: {
                        if !expertMode {
                            Text("InpuDeck не питатиме про них знову. «Дозволити знову» лише знімає блокування; після цього відкрий нове сполучення.")
                        }
                    }
                }
                Section("Сполучення з BT-пристрою") {
                    if !expertMode {
                        Text("У налаштуваннях Bluetooth пристрою вибери «\(transport.advertisedName)» або ім’я цього iPhone. Підтвердь системний запит, якщо він з’явиться.")
                            .font(.subheadline)
                        if developerMode {
                            Text("Linux: звичайна команда «З’єднатися» вмикає всі профілі спареного iPhone, разом з аудіо. Щоб підключити лише клавіатуру й мишу, запусти на пристрої:")
                                .font(.caption).foregroundStyle(.secondary)
                            Text("./scripts/inpudeck-hid.sh")
                                .font(.caption2.monospaced()).textSelection(.enabled)
                            Text("Скрипт сам знаходить адресу iPhone. Вручну її покаже bluetoothctl devices Paired, далі bluetoothctl connect <адреса> 00001812-…. Підставити адресу сюди не можна: iOS не дає застосункам Bluetooth-адресу пристрою.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Button(localized(transport.isPairing ? "Сполучення відкрите · поновити" : "Дозволити нове сполучення")) {
                        transport.beginPairing()
                    }
                    .disabled(!transport.canPair)
                }
                Section("Сполучення з iPhone") {
                    if !expertMode {
                        if developerMode {
                            Text("Якщо Mac уже знає iPhone й не показує його як клавіатуру, відкрий Bluetooth на Mac, запусти пошук тут і вибери Mac. Пристрій має бути доступний через Bluetooth LE.")
                                .font(.subheadline)
                            Text("Linux тут зазвичай не з’являється: пристрій із BlueZ сам не рекламує себе через Bluetooth LE, тому знайти його з iPhone неможливо. З’єднання завжди починає пристрій, а iPhone лише лишається видимим.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("Натисни «Знайти BT-пристрій» і вибери Mac зі списку. Для Linux починай сполучення з пристрою.")
                                .font(.subheadline)
                        }
                    }
                    Button(localized(browser.isScanning ? "Зупинити пошук" : "Знайти BT-пристрій")) {
                        if browser.isScanning { browser.stopScan() } else { browser.scan() }
                    }
                    .disabled(!transport.canPair)
                    if developerMode, !browser.statusText.isEmpty {
                        Text(browser.statusText).font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(visibleBrowserDevices) { device in
                        Button {
                            transport.connect(to: device.id)
                        } label: {
                            HStack(spacing: 12) {
                                Image("BluetoothProtocolIcon")
                                    .renderingMode(.template)
                                    .frame(width: 20)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(device.name)
                                    if developerMode {
                                        Text("UUID: \(device.id.uuidString)")
                                            .font(.caption2.monospaced()).foregroundStyle(.secondary)
                                        if let signal = device.signal {
                                            Text("\(signal) dBm").font(.caption2).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                Spacer()
                                if transport.connectedHostID == device.id {
                                    Image(systemName: "checkmark.circle.fill")
                                } else if transport.selectedHostID == device.id {
                                    ProgressView()
                                }
                            }
                        }
                        .disabled(!transport.canPair || !device.isConnectable)
                        .contextMenu {
                            if developerMode {
                                Button("Копіювати UUID", systemImage: "doc.on.doc") {
                                    UIPasteboard.general.string = device.id.uuidString
                                }
                            }
                        }
                    }
                }
                if developerMode {
                    Section("Пробудження пристрою") {
                        Button("Спробувати пробудити", systemImage: "sun.max") {
                            transport.requestWakeProbe()
                        }
                        .disabled(!transport.canPair || transport.selectedHostID == nil)
                        if !expertMode {
                            Text("Надсилає натискання й відпускання Shift вибраному пристрою, якщо HID підключено. Перевір, чи він прокинувся; результат відправлення буде в журналі.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Section("Журнал підключення") {
                        Button("Записати поточний стан", systemImage: "list.bullet.clipboard") {
                            transport.recordConnectionSnapshot()
                        }
                        ShareLink(item: transport.diagnosticText) {
                            Label("Поділитися журналом", systemImage: "square.and.arrow.up")
                        }
                        if !expertMode {
                            Text("Журнал містить назви й UUID пристроїв, стан BLE та HID, етапи підключення і спроби пробудження, без введеного тексту.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(Array(transport.diagnostics.suffix(12).enumerated()), id: \.offset) { _, line in
                            Text(line).font(.caption2.monospaced()).textSelection(.enabled)
                        }
                    }
                }
            }
            .navigationTitle("Bluetooth")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
        .alert("Назва BT-пристрою", isPresented: Binding(
            get: { hostToRename != nil },
            set: { if !$0 { hostToRename = nil } }
        ), presenting: hostToRename) { host in
            TextField("Наприклад, Linux або MacBook", text: $editedName)
            Button("Зберегти") {
                transport.renameHost(host.id, to: editedName)
                hostToRename = nil
            }
            Button("Скасувати", role: .cancel) { hostToRename = nil }
        } message: { _ in
            Text("Ця назва використовується лише в InpuDeck. Порожнє поле повертає автоматичну назву.")
        }
        .alert("Забути BT-пристрій?", isPresented: Binding(
            get: { hostToForget != nil },
            set: { if !$0 { hostToForget = nil } }
        ), presenting: hostToForget) { host in
            Button("Забути", role: .destructive) {
                transport.forgetHost(host.id)
                hostToForget = nil
            }
            Button("Скасувати", role: .cancel) { hostToForget = nil }
        } message: { host in
            Text("\(host.name) буде вилучено зі списку та автопідключення застосунку. Системне спарювання залишиться. Щоб видалити і його: Налаштування iPhone → Bluetooth → ⓘ → Забути цей пристрій або видали iPhone на BT-пристрої.")
        }
        .directHostApprovalAlert(transport: transport)
        .onDisappear { browser.stopScan() }
    }

    private func hostStatus(_ id: UUID) -> String {
        if transport.connectedHostID == id { return localized("Клавіатура й миша підключені") }
        if transport.selectedHostID == id { return localized("Вибрано · очікуємо підключення") }
        return localized("Натисни, щоб підключити")
    }

    private var visibleSavedHosts: [SavedHIDHost] {
        developerMode ? transport.savedHosts : transport.savedHosts.filter(\.hasDisplayName)
    }

    private var sheetStatusText: String {
        if developerMode { return transport.statusText }
        if let id = transport.selectedHostID,
           transport.savedHosts.first(where: { $0.id == id })?.hasDisplayName != true {
            return localized(transport.isReady ? "Підключено" : "Очікується підключення")
        }
        return transport.statusText.replacingOccurrences(
            of: localized("HID готовий"),
            with: localized("Підключено")
        )
    }

    private var visibleBrowserDevices: [BluetoothHostCandidate] {
        browser.devices.filter { device in
            !transport.savedHosts.contains { $0.id == device.id }
                && !transport.rejectedHosts.contains { $0.id == device.id }
                && (developerMode || device.hasDisplayName)
        }
    }
}

extension View {
    func directHostApprovalAlert(transport: DirectHIDTransport) -> some View {
        alert(item: Binding(
            get: { transport.pendingHostApproval },
            set: { _ in }
        )) { approval in
            Alert(
                title: Text(localized("Дозволити новий BT-пристрій?")),
                message: Text(localizedFormat(
                    "«%@» хоче отримувати введення з InpuDeck. Дозволяй лише пристрою, який сполучаєш зараз. Відхилення буде запам’ятовано; системне Bluetooth-спарювання за потреби видаляється окремо.",
                    approval.name
                )),
                primaryButton: .destructive(Text(localized("Відхилити"))) {
                    transport.rejectPendingHost(approval.id)
                },
                secondaryButton: .default(Text(localized("Дозволити"))) {
                    transport.approvePendingHost(approval.id)
                }
            )
        }
    }
}
