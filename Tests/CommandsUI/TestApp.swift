import SwiftUI
import Combine

// Only the input transport and individual non-Commands pages are fake. Render
// production tab navigation/settings and the actual Commands view/container.
final class RemoteInputController: ObservableObject {
    @Published var isReady = true
    @Published var sentCount = 0
    let mode = TestInputMode()
    @discardableResult
    func sendKeyTaps(_ taps: [(modifiers: UInt8, keycode: UInt8)]) -> Bool {
        sentCount += taps.count
        return true
    }
}
struct TestInputMode {
    let title = "Test"
}

@main
struct CommandsUIApp: App {
    @StateObject private var input = RemoteInputController()
    @State private var selectedTab: AppTab
    @State private var showsSettings = false
    @AppStorage("tabConfiguration") private var rawConfiguration = ""

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        UserDefaults.standard.set(arguments.contains("--expert"), forKey: "expertMode")
        if !arguments.contains("--preserve-tabs") {
            UserDefaults.standard.removeObject(forKey: "tabConfiguration")
        }
        let configuration = AppTabConfiguration(
            rawValue: UserDefaults.standard.string(forKey: "tabConfiguration") ?? "")
        _selectedTab = State(initialValue: arguments.contains("--preserve-tabs") ? configuration.visibleTabs[0] : .commands)
        try? FileManager.default.removeItem(at: CommandletStore.defaultFileURL())
        let store = CommandletStore()
        if arguments.contains("--many-commands") {
            for index in 0..<24 {
                let id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!
                store.add(Commandlet(id: id, name: String(format: "Fixture %02d", index),
                                     syntax: .text, body: "Sample"))
            }
        } else {
            store.add(Commandlet(name: "Fixture", syntax: .keys, body: "Enter"))
        }
    }

    private var activeTab: AppTab {
        AppTabConfiguration(rawValue: rawConfiguration).resolvedSelection(selectedTab)
    }

    var body: some Scene {
        WindowGroup {
            ConfiguredTabView(selection: $selectedTab) { tab in
                if tab == .commands {
                    CommandPalettePage(ble: input, isActiveTab: activeTab == .commands) {
                        HStack {
                            Text(selectedTab.rawValue).accessibilityIdentifier("selectedPage")
                            Spacer()
                            settingsButton
                            Text(String(input.sentCount)).accessibilityIdentifier("sentCount")
                        }
                        .padding()
                        .background(.ultraThinMaterial)
                    }
                } else {
                    VStack {
                        Text(tab.rawValue).accessibilityIdentifier("selectedPage")
                        settingsButton
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.systemGroupedBackground))
                }
            }
            .sheet(isPresented: $showsSettings) {
                NavigationStack {
                    TabSettingsView()
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { showsSettings = false }
                                    .accessibilityIdentifier("dismissTabSettings")
                            }
                        }
                }
            }
        }
    }

    private var settingsButton: some View {
        Button("Settings") { showsSettings = true }
            .accessibilityIdentifier("openTabSettings")
    }
}
