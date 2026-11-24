import SwiftUI
import UniformTypeIdentifiers

/// Template management for the TV remote: import a JSON file, list the stored
/// templates, change which one this host uses, and delete an imported template
/// by swiping it away. The remote screen keeps only the selector and this entry
/// point; the import itself lives here.
struct RemoteTemplatesSettingsView: View {
    @ObservedObject var catalog: RemoteTemplateCatalog

    @State private var showsImporter = false
    @State private var message: String?
    @State private var messageIsNote = false

    var body: some View {
        List {
            Section {
                Button {
                    showsImporter = true
                } label: {
                    Label(localized("Імпортувати шаблон"), systemImage: "square.and.arrow.down")
                }
                .accessibilityIdentifier("remoteTemplatesImport")

                if let message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(messageIsNote ? .secondary : .red)
                }
            } footer: {
                Text(localized("JSON-файл шаблону з форматом на кшталт docs/tv-remote.md. Вибраний шаблон збережеться для цього пристрою; видалення позбавляє його лише цього пристрою."))
                    .font(.caption)
            }

            Section(localized("Шаблони")) {
                ForEach(catalog.descriptors, id: \.id) { descriptor in
                    Button {
                        catalog.select(id: descriptor.id)
                        message = nil
                    } label: {
                        HStack(spacing: 10) {
                            Text(descriptor.name)
                            Spacer()
                            if catalog.selectedTemplateID == descriptor.id {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.green)
                            }
                        }
                    }
                    .accessibilityIdentifier("remoteTemplate-\\(descriptor.id)")
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        if descriptor.source == .stored {
                            Button(role: .destructive) {
                                catalog.remove(id: descriptor.id)
                                message = localized("Шаблон вилучено")
                                messageIsNote = true
                            } label: {
                                Label(localized("Видалити"), systemImage: "trash")
                            }
                            .accessibilityIdentifier("remoteTemplateDelete-\\(descriptor.id)")
                        }
                    }
                }
            }
        }
        .navigationTitle(localized("Шаблони пульта"))
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $showsImporter,
                      allowedContentTypes: [.json],
                      allowsMultipleSelection: false) { result in
            importTemplate(result)
        }
    }

    private func importTemplate(_ result: Result<[URL], Error>) {
        guard case let .success(urls) = result, let url = urls.first else {
            if case .failure(let error) = result {
                message = localizedFormat("Шаблон не імпортовано: %@", error.localizedDescription)
                messageIsNote = false
            }
            return
        }
        switch catalog.importTemplate(from: url) {
        case .clean:
            message = localized("Шаблон імпортовано")
            messageIsNote = true
        case .notes(let note):
            message = note
            messageIsNote = true
        case .error(let reason):
            message = reason
            messageIsNote = false
        }
    }
}
