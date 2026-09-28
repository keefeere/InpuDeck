import Foundation

@main
struct ESPBridgeStoreTests {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }

    static func main() {
        let suite = "ESPBridgeStoreTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            preconditionFailure("Unable to create isolated UserDefaults")
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let legacy = UUID()
        defaults.set(legacy.uuidString, forKey: "legacy.bridge")
        var store = ESPBridgeStore(
            defaults: defaults,
            registryKey: "bridges",
            legacySelectionKey: "legacy.bridge"
        )
        check(store.selectedBridgeID == legacy, "Legacy bridge selection migrates")
        check(store.bridges.map(\.id) == [legacy], "Legacy bridge enters the registry")

        store.updateDiscoveredName("KeeFRogBz", for: legacy)
        let television = UUID()
        store.select(television, name: "Телевізор")
        check(store.selectedBridgeID == television, "A second bridge can be selected")
        check(store.bridges.count == 2, "Both bridges remain saved")
        check(store.bridge(television)?.name == "Телевізор", "UTF-8 advertised names survive persistence")

        store.connected(television, fallbackName: "InpuDeck Bridge")
        check(
            store.bridge(television)?.advertisedName == "Телевізор",
            "A cached CoreBluetooth name cannot replace the current advertised name"
        )
        store.rename(television, to: "Вітальня")
        check(store.bridge(television)?.name == "Вітальня", "An app-local label overrides the advertised name")

        check(
            ESPBridgeNamePayload.decode(Data("ESP Телевізор".utf8)) == "ESP Телевізор",
            "The authenticated name channel preserves UTF-8 names"
        )
        check(
            ESPBridgeNamePayload.decode(Data([0xFF, 0xFE])) == nil,
            "The authenticated name channel rejects invalid UTF-8"
        )
        check(
            ESPBridgeNamePayload.decode(Data("Bad\nName".utf8)) == nil,
            "The authenticated name channel rejects control characters"
        )

        store = ESPBridgeStore(
            defaults: defaults,
            registryKey: "bridges",
            legacySelectionKey: "legacy.bridge"
        )
        check(store.selectedBridgeID == television, "Selection persists")
        check(Set(store.bridges.map(\.id)) == Set([legacy, television]), "Registry persists every adapter")

        store.forget(television)
        check(store.selectedBridgeID == nil, "Forgetting the active bridge clears the selection")
        check(store.bridges.map(\.id) == [legacy], "Forgetting one bridge preserves the others")

        print("PASS: ESP bridge registry migration, authenticated UTF-8 names, cached-name isolation, multi-adapter selection and forgetting")
    }
}
