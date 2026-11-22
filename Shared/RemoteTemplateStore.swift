import Foundation

/// Where a template came from. `bundled` is the shipped file inside the app
/// bundle; `stored` is a JSON file the user imported.
enum RemoteTemplateSource: String, Equatable {
    case bundled
    case stored
}

/// A template the remote screen can offer. `id` is the template's own id from
/// the JSON, which is also the file name inside the store directory.
struct RemoteTemplateDescriptor: Equatable {
    let id: String
    let name: String
    let source: RemoteTemplateSource
}

/// Why an import was refused. The message is shown to the user verbatim, so it
/// names the concrete problem instead of "invalid file".
enum RemoteTemplateStoreError: Error, Equatable {
    case unreadable
    case invalid(String)
    case conflictsWithBundled
    case tooLarge
}

/// Imported templates plus which template each host uses.
///
/// Pure Foundation: no SwiftUI, no CoreBluetooth. The app supplies the host key
/// (transport + selected device), so a TV keeps its remote and a PC keeps its
/// own. Design: docs/tv-remote.md.
final class RemoteTemplateStore {
    /// A template file is a grid description, not a document; 256 KB is far
    /// above any plausible template and stops a bogus pick from being written.
    static let maximumFileBytes = 256 * 1024

    private let fileManager: FileManager
    private let directory: URL
    private let defaults: UserDefaults
    private let selectionKeyPrefix = "remoteTemplate.selected."

    init(directory: URL,
         fileManager: FileManager = .default,
         defaults: UserDefaults = .standard) {
        self.fileManager = fileManager
        self.directory = directory
        self.defaults = defaults
    }

    /// The app-support location the iOS target uses. Kept out of `init`'s
    /// default so tests can point the store at a temporary directory.
    static func applicationDirectory(fileManager: FileManager = .default) -> URL? {
        let bases = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        guard let base = bases.first else { return fileManager.temporaryDirectory }
        return base.appendingPathComponent("RemoteTemplates", isDirectory: true)
    }

    /// Stored templates, in file-name order. A file that no longer decodes is
    /// skipped rather than offered: selecting it would produce a broken remote.
    func storedDescriptors() -> [RemoteTemplateDescriptor] {
        guard let names = try? fileManager.contentsOfDirectory(at: directory,
                                                              includingPropertiesForKeys: nil) else { return [] }
        return names
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url),
                      case let .loaded(template, _) = RemoteTemplateDecoder.decode(data),
                      template.id == url.deletingPathExtension().lastPathComponent else { return nil }
                return RemoteTemplateDescriptor(id: template.id, name: template.name, source: .stored)
            }
    }

    func descriptors(bundled: [RemoteTemplateDescriptor]) -> [RemoteTemplateDescriptor] {
        let seen = Set(bundled.map(\.id))
        return bundled + storedDescriptors().filter { !seen.contains($0.id) }
    }

    /// Copies an imported file into the store after it decodes. Returns the
    /// notes the decoder produced, which the caller shows instead of hiding a
    /// silently dropped cell.
    @discardableResult
    func importTemplate(from url: URL) -> Result<[String], RemoteTemplateStoreError> {
        guard let data = try? Data(contentsOf: url) else { return .failure(.unreadable) }
        guard data.count <= Self.maximumFileBytes else { return .failure(.tooLarge) }
        switch RemoteTemplateDecoder.decode(data) {
        case .rejected(let reason):
            return .failure(.invalid(reason))
        case let .loaded(template, notes):
            guard template.id != RemoteTemplate.defaultId else { return .failure(.conflictsWithBundled) }
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: storedURL(for: template.id), options: .atomic)
            } catch {
                return .failure(.unreadable)
            }
            return .success(notes)
        }
    }

    func removeStoredTemplate(id: String) {
        try? fileManager.removeItem(at: storedURL(for: id))
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix(selectionKeyPrefix) && defaults.string(forKey: key) == id {
            defaults.removeObject(forKey: key)
        }
    }

    /// The template this host should draw. An unknown or deleted id falls back
    /// to the bundled template, so a stale preference never blanks the screen.
    func template(for hostKey: String, bundled: RemoteTemplate) -> RemoteTemplate {
        guard let id = selectedTemplateID(for: hostKey), id != RemoteTemplate.defaultId else { return bundled }
        guard let data = try? Data(contentsOf: storedURL(for: id)),
              case let .loaded(template, _) = RemoteTemplateDecoder.decode(data) else {
            return bundled
        }
        return template
    }

    func selectedTemplateID(for hostKey: String) -> String? {
        defaults.string(forKey: selectionKeyPrefix + hostKey)
    }

    /// Passing the bundled id clears the key: the shipped template is the
    /// default, and storing it as a choice would pin a fallback to a bundle
    /// path that can change with the app.
    func select(templateID: String, for hostKey: String) {
        let key = selectionKeyPrefix + hostKey
        if templateID == RemoteTemplate.defaultId {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(templateID, forKey: key)
        }
    }

    private func storedURL(for id: String) -> URL {
        directory.appendingPathComponent("\(id).json")
    }
}
