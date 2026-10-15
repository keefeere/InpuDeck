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

    private let fileURL: URL

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

    func add(_ commandlet: Commandlet) {
        commandlets.append(commandlet)
        save()
    }

    func update(_ commandlet: Commandlet) {
        guard let index = commandlets.firstIndex(where: { $0.id == commandlet.id }) else { return }
        commandlets[index] = commandlet
        save()
    }

    func delete(_ commandlet: Commandlet) {
        commandlets.removeAll { $0.id == commandlet.id }
        save()
    }

    func duplicate(_ commandlet: Commandlet) -> Commandlet? {
        guard let index = commandlets.firstIndex(where: { $0.id == commandlet.id }) else { return nil }
        var copy = commandlets[index]
        copy.id = UUID()
        copy.name = localizedFormat("%@ (копія)", commandlet.name)
        commandlets.insert(copy, at: index + 1)
        save()
        return copy
    }

    func move(from source: IndexSet, to destination: Int) {
        commandlets.move(fromOffsets: source, toOffset: destination)
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        commandlets = (try? JSONDecoder().decode([Commandlet].self, from: data)) ?? []
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(commandlets) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
