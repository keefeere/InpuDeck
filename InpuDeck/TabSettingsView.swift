import SwiftUI

struct TabSettingsView: View {
    @AppStorage("tabConfiguration") private var rawConfiguration = ""
    @AppStorage("expertMode") private var expertMode = false
    private var configuration: AppTabConfiguration { AppTabConfiguration(rawValue: rawConfiguration) }

    var body: some View {
        List {
            Section {
                ForEach(configuration.order) { tab in
                    HStack(spacing: 12) {
                        Button {
                            var next = configuration
                            if next.toggle(tab) { rawConfiguration = next.rawValue }
                        } label: {
                            Image(systemName: configuration.isEnabled(tab) ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .frame(width: 36, height: 36)
                        }
                        .buttonStyle(.borderless)
                        .disabled(!configuration.canToggle(tab))
                        .accessibilityLabel(localized(tab.titleKey))
                        .accessibilityValue(localized(configuration.isEnabled(tab) ? "Увімкнено" : "Вимкнено"))
                        .accessibilityIdentifier("tabEnabled-\(tab.rawValue)")
                        Text(localized(tab.titleKey))
                        Spacer()
                    }
                    .accessibilityIdentifier("tabSetting-\(tab.rawValue)")
                }
                .onMove { source, destination in
                    var next = configuration
                    next.move(from: source, to: destination)
                    rawConfiguration = next.rawValue
                }
            } footer: {
                if !expertMode {
                    Text(localized("Галочки вмикають вкладки. Перетягніть рядки за ручки праворуч, щоб змінити порядок. Принаймні одна вкладка має залишатися ввімкненою."))
                }
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle(localized("Вкладки"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
