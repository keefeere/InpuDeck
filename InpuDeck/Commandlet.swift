import Combine
import Foundation
import SwiftUI

/// The syntax a commandlet body is interpreted in.
enum CommandletSyntax: String, Codable, CaseIterable, Identifiable {
    /// Typed as plain text with automatic layout switching.
    case text
    /// Parsed line by line into key taps (modifers, named keys, characters).
    case keys

    var id: String { rawValue }
}

/// A reusable input command shown in the Command Palette tab.
struct Commandlet: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var syntax: CommandletSyntax
    /// Multi-line body: plain text or one key command per line.
    var body: String

    init(id: UUID = UUID(), name: String, syntax: CommandletSyntax, body: String) {
        self.id = id
        self.name = name
        self.syntax = syntax
        self.body = body
    }
}

/// Persists the command palette list as JSON in Application Support.
@MainActor
final class CommandletStore: ObservableObject {
    @Published private(set) var commandlets: [Commandlet] = []
    @Published var storageError: String?

    private let fileURL: URL
    private var loadError: String?

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        load()
    }

    static func defaultFileURL() -> URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("InpuDeck", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("commandlets.json")
    }

    @discardableResult
    func add(_ commandlet: Commandlet) -> Bool {
        var next = commandlets
        next.append(commandlet)
        return save(next)
    }

    @discardableResult
    func update(_ commandlet: Commandlet) -> Bool {
        guard let index = commandlets.firstIndex(where: { $0.id == commandlet.id }) else { return false }
        var next = commandlets
        next[index] = commandlet
        return save(next)
    }

    @discardableResult
    func delete(_ commandlet: Commandlet) -> Bool {
        save(commandlets.filter { $0.id != commandlet.id })
    }

    func duplicate(_ commandlet: Commandlet) -> Commandlet? {
        guard let index = commandlets.firstIndex(where: { $0.id == commandlet.id }) else { return nil }
        var copy = commandlets[index]
        copy.id = UUID()
        copy.name = localizedFormat("%@ (копія)", commandlet.name)
        var next = commandlets
        next.insert(copy, at: index + 1)
        return save(next) ? copy : nil
    }

    func move(from source: IndexSet, to destination: Int) {
        var next = commandlets
        next.move(fromOffsets: source, toOffset: destination)
        save(next)
    }

    private func load() {
        do {
            let data = try Data(contentsOf: fileURL)
            commandlets = try JSONDecoder().decode([Commandlet].self, from: data)
        } catch let error as NSError {
            if error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return }
            // Do not overwrite unreadable/corrupt data with an empty list.
            loadError = error.localizedDescription
            storageError = error.localizedDescription
        }
    }

    @discardableResult
    private func save(_ next: [Commandlet]) -> Bool {
        guard loadError == nil else {
            storageError = loadError
            return false
        }
        do {
            let data = try JSONEncoder().encode(next)
            try data.write(to: fileURL, options: .atomic)
            commandlets = next
            storageError = nil
            return true
        } catch {
            // Keep the last persisted list when disk writes fail.
            storageError = error.localizedDescription
            return false
        }
    }
}
