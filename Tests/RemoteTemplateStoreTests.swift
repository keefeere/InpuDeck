import Foundation

@main
struct RemoteTemplateStoreTests {
    /// A minimal but valid template: 3x3 grid, two buttons and one spacer.
    static let validTemplate = """
    {"formatVersion":1,"id":"pc-min","name":"PC","columns":3,"rows":3,"cells":[
      {"id":"a","row":1,"col":1,"control":"button","label":"A","action":{"kind":"key","key":"return"}},
      {"id":"b","row":1,"col":2,"control":"button","label":"B","action":{"kind":"consumer","usage":"mute"}},
      {"id":"c","row":1,"col":3,"control":"spacer","label":"","action":{"kind":"none"}},
      {"id":"d","row":2,"col":1,"rowSpan":2,"colSpan":3,"control":"spacer","label":"","action":{"kind":"none"}}
    ]}
    """

    static let badTemplate = """
    {"formatVersion":1,"id":"bad","name":"Bad","columns":2,"rows":3,"cells":[]}
    """

    static func main() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteTemplateStoreTests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let defaults = UserDefaults(suiteName: "RemoteTemplateStoreTests")!
        defaults.removePersistentDomain(forName: "RemoteTemplateStoreTests")
        let store = RemoteTemplateStore(directory: directory, defaults: defaults)

        importing(store: store, directory: directory)
        perHostSelection(store: store, defaults: defaults)
        removalAndFallback(store: store, directory: directory, defaults: defaults)

        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: "RemoteTemplateStoreTests")
        print("Remote template store import and per-host selection tests passed.")
    }

    static func pick(_ data: String, in directory: URL, name: String = "pick.json") -> URL {
        let url = directory.appendingPathComponent(name)
        try! Data(data.utf8).write(to: url)
        return url
    }

    static func importing(store: RemoteTemplateStore, directory: URL) {
        let bundled = RemoteTemplateDescriptor(id: RemoteTemplate.defaultId, name: "TV", source: .bundled)

        precondition(store.storedDescriptors().isEmpty, "a fresh store holds no templates")
        precondition(store.descriptors(bundled: [bundled]).map(\.id) == [RemoteTemplate.defaultId],
                     "without imports only the bundled template is offered")

        switch store.importTemplate(from: pick(validTemplate, in: directory, name: "good.json")) {
        case .success(let notes):
            precondition(notes.isEmpty, "a valid template must report no dropped cells: \(notes)")
        case .failure(let error):
            preconditionFailure("a valid template must import, got \(error)")
        }
        precondition(store.storedDescriptors().map(\.id) == ["pc-min"],
                     "the imported template must be listed by its own id")
        precondition(store.descriptors(bundled: [bundled]).map(\.id) == [RemoteTemplate.defaultId, "pc-min"],
                     "the picker must show the bundled template and the import")

        // A template the decoder refuses must not reach the store directory.
        switch store.importTemplate(from: pick(badTemplate, in: directory, name: "bad.json")) {
        case .success(let notes):
            preconditionFailure("an invalid template must be refused, got notes \(notes)")
        case .failure(.invalid(let reason)):
            precondition(reason.contains("columns"), "the reason must name the problem: \(reason)")
        case .failure(let error):
            preconditionFailure("an invalid template must report .invalid, got \(error)")
        }
        precondition(store.storedDescriptors().map(\.id) == ["pc-min"],
                     "a refused import must not change the store")

        // The bundled template is a fallback, so shadowing it would hide the
        // shipped remote behind a user file with the same id.
        let shadow = validTemplate.replacingOccurrences(of: "\"pc-min\"", with: "\"\(RemoteTemplate.defaultId)\"")
        switch store.importTemplate(from: pick(shadow, in: directory, name: "shadow.json")) {
        case .success:
            preconditionFailure("an import must not overwrite the bundled template id")
        case .failure(.conflictsWithBundled):
            break
        case .failure(let error):
            preconditionFailure("a bundled id must report .conflictsWithBundled, got \(error)")
        }

        switch store.importTemplate(from: directory.appendingPathComponent("missing.json")) {
        case .failure(.unreadable):
            break
        case .failure(let error):
            preconditionFailure("a missing file must report .unreadable, got \(error)")
        case .success:
            preconditionFailure("a missing file must not import")
        }
    }

    static func perHostSelection(store: RemoteTemplateStore, defaults: UserDefaults) {
        let bundled = RemoteTemplate.defaultTemplate
        precondition(store.selectedTemplateID(for: "esp:tv") == nil,
                     "a host with no choice has no stored id")
        precondition(store.template(for: "esp:tv", bundled: bundled).id == RemoteTemplate.defaultId,
                     "the default rendering is the bundled template")

        store.select(templateID: "pc-min", for: "esp:pc")
        precondition(store.template(for: "esp:pc", bundled: bundled).id == "pc-min",
                     "the chosen host draws the imported template")
        precondition(store.template(for: "esp:tv", bundled: bundled).id == RemoteTemplate.defaultId,
                     "another host keeps the bundled template")

        // Choosing the bundled id is the default, so it must not pin a key.
        store.select(templateID: RemoteTemplate.defaultId, for: "esp:pc")
        precondition(store.selectedTemplateID(for: "esp:pc") == nil,
                     "choosing the bundled template must clear the stored choice")
        precondition(store.template(for: "esp:pc", bundled: bundled).id == RemoteTemplate.defaultId,
                     "after clearing the choice the bundled template is drawn again")
    }

    static func removalAndFallback(store: RemoteTemplateStore, directory: URL, defaults: UserDefaults) {
        store.select(templateID: "pc-min", for: "esp:pc")
        store.select(templateID: "pc-min", for: "direct:keyboard")

        // A deleted template must never leave a host pointing at nothing.
        store.removeStoredTemplate(id: "pc-min")
        precondition(store.storedDescriptors().isEmpty, "removal must delete the file")
        precondition(store.selectedTemplateID(for: "esp:pc") == nil
                     && store.selectedTemplateID(for: "direct:keyboard") == nil,
                     "removal must clear every host that used the template")
        precondition(store.template(for: "esp:pc", bundled: RemoteTemplate.defaultTemplate).id == RemoteTemplate.defaultId,
                     "a host whose template vanished falls back to the bundled one")

        // A stale id pointing at a file that no longer exists is a fallback too.
        defaults.set("gone", forKey: "remoteTemplate.selected.esp:tv")
        precondition(store.template(for: "esp:tv", bundled: RemoteTemplate.defaultTemplate).id == RemoteTemplate.defaultId,
                     "an unknown stored id must fall back, not blank the remote")
        try? FileManager.default.removeItem(at: directory)
    }
}
