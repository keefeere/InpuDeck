import Foundation

struct SavedHIDHost: Codable, Identifiable, Equatable {
    let id: UUID
    var discoveredName: String?
    var customName: String?
    var supportsOutgoingConnection = false
    var lastConnectedAt: Date?

    var name: String {
        customName ?? discoveredName ?? localized("BT-пристрій без назви")
    }

    var hasDisplayName: Bool { customName != nil || discoveredName != nil }

    var diagnosticName: String { "\(name) [\(id.uuidString.prefix(8))]" }
}

/// A Direct Bluetooth peer the user explicitly denied. This is kept outside
/// the saved-host registry so adding the field cannot invalidate registries
/// written by older app versions.
struct RejectedHIDHost: Codable, Identifiable, Equatable {
    let id: UUID
    var discoveredName: String?
    let rejectedAt: Date

    var name: String { discoveredName ?? localized("Відхилений BT-пристрій") }
    var diagnosticName: String { "\(name) [\(id.uuidString.prefix(8))]" }
}

enum HIDHostApprovalDecision: Equatable {
    case route
    case requestApproval
    case awaitDecision
    case block
}

/// Decides whether an encrypted Direct Bluetooth peer may reach the HID route.
/// The system Bluetooth bond alone is intentionally insufficient for a new
/// peer: it also needs either an explicit in-app selection or approval.
enum HIDHostApprovalPolicy {
    static func decision(
        for id: UUID,
        routedHost: UUID?,
        preferredHost: UUID?,
        knownHosts: Set<UUID>,
        rejectedHosts: Set<UUID>,
        pairingOpen: Bool,
        pendingHost: UUID?
    ) -> HIDHostApprovalDecision {
        if routedHost == id || preferredHost == id { return .route }
        if knownHosts.contains(id) || rejectedHosts.contains(id) || !pairingOpen { return .block }
        guard let pendingHost else { return .requestApproval }
        return pendingHost == id ? .awaitDecision : .block
    }
}

/// App-local host selection, not the system Bluetooth bond database. The Share
/// extension intentionally uses a separate defaults container and host key.
final class HIDHostStore {
    private struct Snapshot: Codable {
        var hosts: [SavedHIDHost] = []
        var selectedHostID: UUID?
        var hasManagedHosts = false
    }

    private let defaults: UserDefaults
    private let hostKey: String
    private let registryKey: String
    private let rejectedRegistryKey: String
    private var snapshot: Snapshot
    private var rejectedSnapshot: [RejectedHIDHost]

    var hosts: [SavedHIDHost] { snapshot.hosts }
    var rejectedHosts: [RejectedHIDHost] { rejectedSnapshot }
    var selectedHostID: UUID? { snapshot.selectedHostID }
    var shouldPairOnStart: Bool { !snapshot.hasManagedHosts && selectedHostID == nil }

    init(defaults: UserDefaults = .standard, hostKey: String = "directHID.selectedHost") {
        self.defaults = defaults
        self.hostKey = hostKey
        registryKey = hostKey + ".registry"
        rejectedRegistryKey = hostKey + ".rejected"
        if let data = defaults.data(forKey: rejectedRegistryKey),
           let decoded = try? JSONDecoder().decode([RejectedHIDHost].self, from: data) {
            rejectedSnapshot = decoded
        } else {
            rejectedSnapshot = []
        }
        if let data = defaults.data(forKey: registryKey),
           let decoded = try? JSONDecoder().decode(Snapshot.self, from: data) {
            snapshot = decoded
        } else {
            snapshot = Snapshot()
            // A damaged registry must not silently reopen pairing to any host.
            snapshot.hasManagedHosts = defaults.object(forKey: registryKey) != nil
            let selected = defaults.string(forKey: hostKey).flatMap(UUID.init(uuidString:))
            let outgoing = defaults.string(forKey: "directHID.outgoingHost").flatMap(UUID.init(uuidString:))
            for id in Set([selected, outgoing].compactMap { $0 }) {
                snapshot.hosts.append(SavedHIDHost(
                    id: id,
                    discoveredName: id == outgoing ? Self.clean(defaults.string(forKey: "directHID.outgoingHostName")) : nil,
                    supportsOutgoingConnection: id == outgoing
                ))
            }
            snapshot.selectedHostID = selected
            snapshot.hasManagedHosts = snapshot.hasManagedHosts || !snapshot.hosts.isEmpty
            persist()
        }
    }

    func host(_ id: UUID) -> SavedHIDHost? { hosts.first { $0.id == id } }
    func isRejected(_ id: UUID) -> Bool { rejectedSnapshot.contains { $0.id == id } }

    func select(_ id: UUID, name: String?, supportsOutgoing: Bool) {
        rejectedSnapshot.removeAll { $0.id == id }
        if let index = snapshot.hosts.firstIndex(where: { $0.id == id }) {
            if let name = Self.clean(name) { snapshot.hosts[index].discoveredName = name }
            snapshot.hosts[index].supportsOutgoingConnection = snapshot.hosts[index].supportsOutgoingConnection || supportsOutgoing
        } else {
            snapshot.hosts.append(SavedHIDHost(id: id, discoveredName: Self.clean(name), supportsOutgoingConnection: supportsOutgoing))
        }
        snapshot.selectedHostID = id
        snapshot.hasManagedHosts = true
        persist()
        persistRejectedHosts()
    }

    func connected(_ id: UUID, name: String?, supportsOutgoing: Bool) {
        select(id, name: name, supportsOutgoing: supportsOutgoing)
        if let index = snapshot.hosts.firstIndex(where: { $0.id == id }) {
            snapshot.hosts[index].lastConnectedAt = Date()
        }
        persist()
    }

    func updateDiscoveredName(_ name: String, for id: UUID) {
        guard let name = Self.clean(name), let index = snapshot.hosts.firstIndex(where: { $0.id == id }),
              snapshot.hosts[index].discoveredName != name else { return }
        snapshot.hosts[index].discoveredName = name
        persist()
    }

    func rename(_ id: UUID, to name: String) {
        guard let index = snapshot.hosts.firstIndex(where: { $0.id == id }) else { return }
        snapshot.hosts[index].customName = Self.clean(name)
        persist()
    }

    func forget(_ id: UUID) {
        snapshot.hosts.removeAll { $0.id == id }
        if selectedHostID == id { snapshot.selectedHostID = nil }
        snapshot.hasManagedHosts = true
        if defaults.string(forKey: "directHID.outgoingHost") == id.uuidString {
            defaults.removeObject(forKey: "directHID.outgoingHost")
            defaults.removeObject(forKey: "directHID.outgoingHostName")
        }
        persist()
    }

    func reject(_ id: UUID, name: String?) {
        let rejected = RejectedHIDHost(
            id: id,
            discoveredName: Self.clean(name),
            rejectedAt: Date()
        )
        if let index = rejectedSnapshot.firstIndex(where: { $0.id == id }) {
            rejectedSnapshot[index] = rejected
        } else {
            rejectedSnapshot.append(rejected)
        }
        persistRejectedHosts()
    }

    func allowAgain(_ id: UUID) {
        guard rejectedSnapshot.contains(where: { $0.id == id }) else { return }
        rejectedSnapshot.removeAll { $0.id == id }
        persistRejectedHosts()
    }

    private static func clean(_ name: String?) -> String? {
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        return String(name.prefix(80))
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(snapshot) { defaults.set(data, forKey: registryKey) }
        if let selectedHostID { defaults.set(selectedHostID.uuidString, forKey: hostKey) }
        else { defaults.removeObject(forKey: hostKey) }
    }

    private func persistRejectedHosts() {
        if let data = try? JSONEncoder().encode(rejectedSnapshot) {
            defaults.set(data, forKey: rejectedRegistryKey)
        }
    }
}

/// Serializes asynchronous advertising requests. In particular, two unsubscribe
/// callbacks must not issue two starts before the first start completes.
struct HIDAdvertisingState {
    enum Action: Equatable { case start, stop }
    private enum Phase { case idle, starting, advertising }
    private var phase = Phase.idle
    private var wanted = false

    init(isAdvertising: Bool = false) {
        phase = isAdvertising ? .advertising : .idle
    }

    mutating func update(wanted: Bool) -> Action? {
        self.wanted = wanted
        switch phase {
        case .idle where wanted:
            phase = .starting
            return .start
        case .advertising where !wanted:
            phase = .idle
            return .stop
        default:
            return nil
        }
    }

    mutating func didStart(succeeded: Bool) -> Action? {
        phase = succeeded ? .advertising : .idle
        // Do not retry a failed request in a tight loop. A later explicit
        // reconnect or Bluetooth state/subscription change can retry it.
        guard succeeded else { return nil }
        return update(wanted: wanted)
    }
}
