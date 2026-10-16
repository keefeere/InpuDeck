import SwiftUI
import Combine

// Only the input transport is fake. Render the actual production Commands view,
// store, parser and press style; no Bluetooth device is used by these UI tests.
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
    @State private var selectedTab = 3

    init() {
        UserDefaults.standard.set(
            ProcessInfo.processInfo.arguments.contains("--expert"), forKey: "expertMode")
        try? FileManager.default.removeItem(at: CommandletStore.defaultFileURL())
        let store = CommandletStore()
        if ProcessInfo.processInfo.arguments.contains("--many-commands") {
            for index in 0..<24 {
                let id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!
                store.add(Commandlet(id: id, name: String(format: "Fixture %02d", index),
                                     syntax: .text, body: "Sample"))
            }
        } else {
            store.add(Commandlet(name: "Fixture", syntax: .keys, body: "Enter"))
        }
    }

    var body: some Scene {
        WindowGroup {
            TabView(selection: $selectedTab) {
                Text("Other tab").tabItem { Text("Other") }.tag(0)
                CommandPalettePage(ble: input, isActiveTab: selectedTab == 3) {
                    HStack {
                        Text("Connection header")
                        Spacer()
                        Text(String(input.sentCount)).accessibilityIdentifier("sentCount")
                    }
                    .padding()
                    .background(.ultraThinMaterial)
                }
                .tabItem { Image(systemName: "command.square").accessibilityLabel("Команди") }.tag(3)
            }
        }
    }
}
