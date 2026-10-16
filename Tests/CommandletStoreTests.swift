import Foundation

@main
struct CommandletStoreTests {
    @MainActor
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("commands.json")
        let store = CommandletStore(fileURL: file)
        let original = Commandlet(name: "Test", syntax: .text, body: "hello")
        precondition(store.add(original))
        precondition(CommandletStore(fileURL: file).commandlets == [original])
        var updated = original
        updated.body = "updated"
        precondition(store.update(updated))
        precondition(store.duplicate(updated) != nil)
        precondition(store.commandlets.count == 2)
        precondition(store.delete(updated))
        precondition(CommandletStore(fileURL: file).commandlets == store.commandlets)

        // A path with a missing parent cannot be written. No in-memory success.
        let unavailable = CommandletStore(fileURL: root.appendingPathComponent("missing/commands.json"))
        precondition(!unavailable.add(original))
        precondition(unavailable.commandlets.isEmpty)
        precondition(unavailable.storageError != nil)

        let corrupt = root.appendingPathComponent("corrupt.json")
        let badData = Data("not JSON".utf8)
        try badData.write(to: corrupt)
        let damaged = CommandletStore(fileURL: corrupt)
        precondition(damaged.storageError != nil)
        precondition(!damaged.add(original))
        let preserved = try Data(contentsOf: corrupt)
        precondition(preserved == badData, "Never overwrite unreadable user commands")
        print("Command persistence tests passed.")
    }
}
