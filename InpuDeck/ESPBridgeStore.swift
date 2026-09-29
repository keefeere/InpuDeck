import Foundation

enum ESPFirmwareSecurityIssue: String, Identifiable {
    case unsafeLegacy
    case unknownCapability

    var id: String { rawValue }

    var title: String {
        switch self {
        case .unsafeLegacy:
            localized("Небезпечна прошивка ESP")
        case .unknownCapability:
            localized("Несумісна прошивка ESP")
        }
    }

    var message: String {
        switch self {
        case .unsafeLegacy:
            localized("Цей адаптер не підтримує захищене сполучення. InpuDeck заблокував введення. Повністю перепроший ESP актуальним інсталятором; --skip-flash недостатньо.")
        case .unknownCapability:
            localized("Версію захисту цього адаптера не розпізнано. InpuDeck заблокував введення. Встанови актуальну прошивку ESP.")
        }
    }
}

enum ESPBridgeNamePayload {
    static let maximumByteCount = 28

    static func decode(_ data: Data?) -> String? {
        guard let data, !data.isEmpty, data.count <= maximumByteCount,
              !data.contains(where: { $0 < 0x20 || $0 == 0x7F }),
              let decoded = String(data: data, encoding: .utf8) else { return nil }
        let name = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
}

struct SavedESPBridge: Codable, Identifiable, Equatable {
    let id: UUID
    var advertisedName: String?
    var customName: String?
    var lastConnectedAt: Date?

    init(
        id: UUID,
        advertisedName: String? = nil,
        customName: String? = nil,
        lastConnectedAt: Date? = nil
    ) {
        self.id = id
        self.advertisedName = advertisedName
        self.customName = customName
        self.lastConnectedAt = lastConnectedAt
    }

    var name: String {
        customName ?? advertisedName ?? localized("ESP-адаптер без назви")
    }

    var hasDisplayName: Bool { customName != nil || advertisedName != nil }

    var diagnosticName: String { "\(name) [\(id.uuidString.prefix(8))]" }
}

struct DiscoveredESPBridge: Identifiable, Equatable {
    let id: UUID
    var name: String?
    var signal: Int?
    var isConnectable: Bool

    var displayName: String { name ?? localized("ESP-адаптер без назви") }
    var hasDisplayName: Bool { name != nil }
    var diagnosticName: String { "\(displayName) [\(id.uuidString.prefix(8))]" }
}

/// App-local ESP registry. CoreBluetooth identifiers distinguish adapters even
/// when they advertise the same name; the name exists only for human selection.
final class ESPBridgeStore {
    private struct Snapshot: Codable {
        var bridges: [SavedESPBridge] = []
        var selectedBridgeID: UUID?
    }

    private let defaults: UserDefaults
    private let registryKey: String
    private let legacySelectionKey: String
    private var snapshot: Snapshot

    var bridges: [SavedESPBridge] { snapshot.bridges }
    var selectedBridgeID: UUID? { snapshot.selectedBridgeID }

    init(
        defaults: UserDefaults = .standard,
        registryKey: String = "espBridge.registry",
        legacySelectionKey: String = "lastBridgePeripheralIdentifier"
    ) {
        self.defaults = defaults
        self.registryKey = registryKey
        self.legacySelectionKey = legacySelectionKey

        if let data = defaults.data(forKey: registryKey),
           let decoded = try? JSONDecoder().decode(Snapshot.self, from: data) {
            snapshot = decoded
        } else {
            snapshot = Snapshot()
            if let value = defaults.string(forKey: legacySelectionKey),
               let id = UUID(uuidString: value) {
                snapshot.bridges = [SavedESPBridge(id: id)]
                snapshot.selectedBridgeID = id
            }
            persist()
        }
    }

    func bridge(_ id: UUID) -> SavedESPBridge? {
        bridges.first { $0.id == id }
    }

    func select(_ id: UUID, name: String?) {
        remember(id, name: name)
        snapshot.selectedBridgeID = id
        persist()
    }

    func connected(_ id: UUID, fallbackName: String?) {
        // CBPeripheral.name is cached by iOS and can retain the name from
        // before a bridge was reflashed or renamed. It is useful only for a
        // nameless migrated entry; never let it replace a name observed in a
        // current advertisement or read from the authenticated name channel.
        if bridge(id)?.advertisedName == nil {
            remember(id, name: fallbackName)
        }
        snapshot.selectedBridgeID = id
        if let index = snapshot.bridges.firstIndex(where: { $0.id == id }) {
            snapshot.bridges[index].lastConnectedAt = Date()
        }
        persist()
    }

    func updateDiscoveredName(_ name: String?, for id: UUID) {
        guard let name = Self.clean(name),
              let index = snapshot.bridges.firstIndex(where: { $0.id == id }),
              snapshot.bridges[index].advertisedName != name else { return }
        snapshot.bridges[index].advertisedName = name
        persist()
    }

    func updateCachedNameIfMissing(_ name: String?, for id: UUID) {
        // CBPeripheral.name may remain stale across a firmware rename. It is
        // useful only for a migrated or otherwise nameless registry entry.
        guard bridge(id)?.advertisedName == nil else { return }
        remember(id, name: name)
        persist()
    }

    func rename(_ id: UUID, to name: String) {
        guard let index = snapshot.bridges.firstIndex(where: { $0.id == id }) else { return }
        snapshot.bridges[index].customName = Self.clean(name)
        persist()
    }

    func forget(_ id: UUID) {
        snapshot.bridges.removeAll { $0.id == id }
        if snapshot.selectedBridgeID == id { snapshot.selectedBridgeID = nil }
        persist()
    }

    private func remember(_ id: UUID, name: String?) {
        if let index = snapshot.bridges.firstIndex(where: { $0.id == id }) {
            if let name = Self.clean(name) { snapshot.bridges[index].advertisedName = name }
        } else {
            snapshot.bridges.append(SavedESPBridge(id: id, advertisedName: Self.clean(name)))
        }
    }

    private static func clean(_ name: String?) -> String? {
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        return String(name.prefix(80))
    }

    private func persist() {
        snapshot.bridges.sort {
            ($0.lastConnectedAt ?? .distantPast) > ($1.lastConnectedAt ?? .distantPast)
        }
        if let data = try? JSONEncoder().encode(snapshot) { defaults.set(data, forKey: registryKey) }
        if let selectedBridgeID {
            defaults.set(selectedBridgeID.uuidString, forKey: legacySelectionKey)
        } else {
            defaults.removeObject(forKey: legacySelectionKey)
        }
    }
}
