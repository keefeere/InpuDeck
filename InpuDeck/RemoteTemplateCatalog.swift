import Combine
import Foundation

/// What an import did. `notes` is a non-fatal disclosure about dropped cells,
/// `error` is a reason the file was refused.
enum RemoteTemplateImportResult: Equatable {
    case clean
    case notes(String)
    case error(String)
}

/// One owner for template files, the host's selection and the decoded template,
/// shared by the remote screen and the settings screen. The remote screen
/// renders `template`; the settings screen imports, lists and deletes files.
/// Pure Foundation + @MainActor: no views, no CoreBluetooth.
/// Design: docs/tv-remote.md.
@MainActor
final class RemoteTemplateCatalog: ObservableObject {
    /// The decoded bundled template — never nil; the shipped default stands in
    /// when the resource is missing or unreadable.
    let bundled: RemoteTemplate
    /// Localized reason the bundled template could not be read as-is, shown on
    /// the remote screen as a note. nil when the bundle is clean.
    @Published private(set) var bundledNote: String?
    /// Templates imported by the user, in file-name order.
    @Published private(set) var storedTemplates: [RemoteTemplateDescriptor] = []
    /// The template the host should draw right now.
    @Published private(set) var template: RemoteTemplate
    /// Bumped on every mutation, so screens can re-derive from the catalog
    /// instead of remembering a snapshot.
    @Published private(set) var version = 0

    private let store: RemoteTemplateStore
    private var currentHostKey: String

    init(hostKey: String, directory: URL? = nil) {
        self.currentHostKey = hostKey
        self.store = RemoteTemplateStore(
            directory: directory ?? RemoteTemplateStore.applicationDirectory()
                ?? FileManager.default.temporaryDirectory
        )
        let loaded = Self.loadBundledTemplate()
        self.bundled = loaded.template
        self.bundledNote = loaded.note
        self.template = loaded.template
        refresh()
    }

    /// The shipped resource, decoded with the same decoder the import path
    /// uses. A broken bundle is reported via `note`, never silently repaired.
    static func loadBundledTemplate() -> (template: RemoteTemplate, note: String?) {
        guard let url = Bundle.main.url(forResource: "RemoteTemplate.tv-default",
                                        withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            return (RemoteTemplate.defaultTemplate,
                    localized("Шаблон пульта не знайдено у пакунці"))
        }
        switch RemoteTemplateDecoder.decode(data) {
        case let .loaded(loaded, notes):
            let shown = loaded.cells.isEmpty ? RemoteTemplate.defaultTemplate : loaded
            let note = notes.isEmpty ? nil
                : localizedFormat("Деякі кнопки пульта не працюють (%d): перевірте шаблон", notes.count)
            return (shown, note)
        case .rejected(let reason):
            return (RemoteTemplate.defaultTemplate,
                    localizedFormat("Шаблон пульта не прочитано: %@", reason))
        }
    }

    /// Re-read the files, the selection for `hostKey` and the decoded template.
    func refresh(hostKey: String? = nil) {
        if let hostKey { currentHostKey = hostKey }
        storedTemplates = store.storedDescriptors()
        template = store.template(for: currentHostKey, bundled: bundled)
        version &+= 1
    }

    /// Everything the selector offers: the bundled template first, then the
    /// imported ones (the store skips undecodable files).
    var descriptors: [RemoteTemplateDescriptor] {
        [RemoteTemplateDescriptor(id: RemoteTemplate.defaultId,
                                  name: localized("Вбудований шаблон"),
                                  source: .bundled)] + storedTemplates
    }

    /// The id the selector should highlight. Never an unknown id: a stale key
    /// in UserDefaults falls back to the bundled one.
    var selectedTemplateID: String {
        let id = store.selectedTemplateID(for: currentHostKey) ?? RemoteTemplate.defaultId
        return descriptors.contains(where: { $0.id == id }) ? id : RemoteTemplate.defaultId
    }

    func select(id: String) {
        store.select(templateID: id, for: currentHostKey)
        refresh()
    }

    /// Import a JSON file into the store. A clean import returns `.clean`;
    /// dropped cells return `.notes` with the same message the remote screen
    /// would show; a refusal returns `.error` with the reason.
    @discardableResult
    func importTemplate(from url: URL) -> RemoteTemplateImportResult {
        // Security-scoped access is required for a Files pick; a bookmark is not
        // kept, because the template is copied into app support, not referenced.
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        switch store.importTemplate(from: url) {
        case let .success(notes):
            refresh()
            guard !notes.isEmpty else { return .clean }
            return .notes(localizedFormat("Деякі кнопки пульта не працюють (%d): перевірте шаблон", notes.count))
        case .failure(.unreadable):
            return .error(localized("Шаблон не вдалося прочитати"))
        case .failure(.tooLarge):
            return .error(localized("Файл шаблону завеликий"))
        case .failure(.conflictsWithBundled):
            return .error(localized("Шаблон із таким id уже є у пакунці"))
        case .failure(.invalid(let reason)):
            return .error(localizedFormat("Шаблон не підходить: %@", reason))
        }
    }

    func remove(id: String) {
        store.removeStoredTemplate(id: id)
        refresh()
    }
}
