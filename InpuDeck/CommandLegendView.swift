import SwiftUI

struct CommandLegendView: View {
    let syntax: CommandletSyntax
    let onInsert: (String, Int?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var showsFunctionKeys = false

    private var legacy: Bool { syntax == .keys }
    private func marker(_ key: String) -> String { legacy ? key : "<\(key)>" }
    private func insert(_ text: String, caretOffset: Int? = nil) {
        onInsert(text, caretOffset)
        dismiss()
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if syntax == .text {
                        Text(localized("У режимі «Текст» маркери надсилаються буквально. Для натискань оберіть «Текст + клавіші» в редакторі."))
                    } else if legacy {
                        Text(localized("Старий формат: клавіші — окремими рядками. Вставка з легенди додає межі рядка за потреби."))
                    } else {
                        Text(localized("Натисніть елемент, щоб вставити його на місце курсора або замість виділеного тексту."))
                    }
                }

                Section {
                    modifier("Ctrl", id: "ctrl", description: localized("Control — модифікатор керування"))
                    modifier("Shift", id: "shift", description: localized("Shift — регістр або додатковий модифікатор"))
                    modifier("Alt", id: "alt", description: localized("Alt / Option — альтернативний модифікатор"))
                    modifier("Win", id: "win", description: localized("Win / Cmd / Super — системний модифікатор"))
                    modifier("AltGr", id: "altgr", description: localized("AltGr — правий Alt"))
                } header: {
                    Text(localized("Модифікатори"))
                } footer: {
                    Text(localized("Модифікатор вставляє заготовку комбінації. Допишіть клавішу в позиції курсора."))
                }

                Section(localized("Клавіші")) {
                    key("Enter", id: "enter", description: localized("Enter — підтвердити або новий рядок"))
                    key("Tab", id: "tab", description: localized("Tab — наступне поле"))
                    key("Esc", id: "escape", description: localized("Esc — скасувати"))
                    key("Del", id: "delete", description: localized("Del / Delete — видалити вперед"))
                    key("Backspace", id: "backspace", description: localized("Backspace — видалити назад"))
                }

                Section(localized("Курсорні клавіші")) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4)) {
                        compactKey("Left", id: "left", glyph: "←")
                        compactKey("Down", id: "down", glyph: "↓")
                        compactKey("Up", id: "up", glyph: "↑")
                        compactKey("Right", id: "right", glyph: "→")
                    }
                }

                Section(localized("Навігація")) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 2)) {
                        compactKey("Home", id: "home")
                        compactKey("End", id: "end")
                        compactKey("PgUp", id: "pageup")
                        compactKey("PgDn", id: "pagedown")
                    }
                }

                Section(localized("Функціональні клавіші")) {
                    DisclosureGroup(isExpanded: $showsFunctionKeys) {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4)) {
                            ForEach(1...12, id: \.self) { number in
                                compactKey("F\(number)", id: "f\(number)")
                            }
                        }
                    } label: {
                        Text("F1–F12").accessibilityIdentifier("legend-functions")
                    }
                }

                Section(localized("Приклади комбінацій")) {
                    key("Ctrl+C", id: "copy", description: localized("Ctrl+C — приклад копіювання"))
                    key("Ctrl+V", id: "paste", description: localized("Ctrl+V — приклад вставки"))
                    key("Ctrl+Shift+Esc", id: "task-manager", description: localized("Ctrl+Shift+Esc — диспетчер завдань Windows"))
                }

                if syntax == .mixed {
                    Section(localized("Екранування")) {
                        literal(#"\<Enter>"#, id: "literal-enter", description: localized("Набрати текст <Enter>, а не натиснути клавішу"))
                        literal(#"\<"#, id: "literal-left", description: localized("Набрати символ <"))
                        literal(#"\>"#, id: "literal-right", description: localized("Набрати символ >"))
                        literal(#"\\"#, id: "literal-backslash", description: localized("Набрати бекслеш"))
                    }
                }
            }
            .navigationTitle(localized("Легенда команд"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(localized("Готово")) { dismiss() }
                        .accessibilityIdentifier("commandLegendDone")
                }
            }
        }
    }

    private func modifier(_ name: String, id: String, description: String) -> some View {
        let template = marker(name + "+")
        return Button {
            insert(template, caretOffset: template.utf16.count - (legacy ? 0 : 1))
        } label: {
            row(name, description: description)
        }
        .accessibilityIdentifier("legend-modifier-" + id)
    }

    private func key(_ key: String, id: String, description: String) -> some View {
        Button { insert(marker(key)) } label: { row(marker(key), description: description) }
            .accessibilityIdentifier("legend-key-" + id)
    }

    private func compactKey(_ key: String, id: String, glyph: String? = nil) -> some View {
        Button { insert(marker(key)) } label: {
            VStack(spacing: 3) {
                if let glyph { Text(glyph).font(.title2) }
                Text(marker(key)).font(.callout.monospaced())
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.vertical, 4)
            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
        }
        // Multiple buttons share one List row. Automatic row-button behavior
        // can otherwise activate more than the tapped grid item.
        .buttonStyle(.borderless)
        .accessibilityLabel(marker(key))
        .accessibilityIdentifier("legend-key-" + id)
    }

    private func literal(_ value: String, id: String, description: String) -> some View {
        Button { insert(value) } label: { row(value, description: description) }
            .accessibilityIdentifier("legend-" + id)
    }

    private func row(_ value: String, description: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(.body.monospaced())
            Text(description).font(.caption).foregroundStyle(.secondary)
        }
    }
}
