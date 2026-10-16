import SwiftUI

/// The production Commands container. Keep the connection header outside the
/// navigation stack and in normal flow; don't overlay its navigation controls
/// with a root safe-area inset. The UI harness uses this same container.
struct CommandPalettePage<Header: View>: View {
    let ble: RemoteInputController
    let isActiveTab: Bool
    private let header: Header

    init(
        ble: RemoteInputController,
        isActiveTab: Bool,
        @ViewBuilder header: () -> Header
    ) {
        self.ble = ble
        self.isActiveTab = isActiveTab
        self.header = header()
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            CommandPaletteView(ble: ble, isActiveTab: isActiveTab)
        }
    }
}
