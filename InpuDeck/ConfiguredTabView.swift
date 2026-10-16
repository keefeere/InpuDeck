import SwiftUI

/// Shared production tab rendering and edge navigation. Selection uses stable
/// IDs so hiding/reordering a tab cannot select a different page by accident.
struct ConfiguredTabView<Content: View>: View {
    @Binding var selection: AppTab
    @AppStorage("tabConfiguration") private var rawConfiguration = ""
    @AppStorage("expertMode") private var expertMode = false
    private let content: (AppTab) -> Content

    init(selection: Binding<AppTab>, @ViewBuilder content: @escaping (AppTab) -> Content) {
        _selection = selection
        self.content = content
    }

    private var configuration: AppTabConfiguration { AppTabConfiguration(rawValue: rawConfiguration) }

    var body: some View {
        GeometryReader { geometry in
            TabView(selection: Binding(
                get: { configuration.resolvedSelection(selection) },
                set: { selection = configuration.resolvedSelection($0) }
            )) {
                ForEach(configuration.visibleTabs) { tab in
                    content(tab)
                        .tabItem { tabLabel(tab) }
                        .tag(tab)
                }
            }
            .id(expertMode)
            .simultaneousGesture(DragGesture(minimumDistance: 24, coordinateSpace: .local).onEnded { value in
                let horizontal = value.translation.width
                let vertical = value.translation.height
                let atLeft = value.startLocation.x <= 28
                let atRight = value.startLocation.x >= geometry.size.width - 28
                guard abs(horizontal) >= 120, abs(horizontal) > abs(vertical) * 1.25 else { return }
                let direction: Int
                if atRight, horizontal < 0 { direction = 1 }
                else if atLeft, horizontal > 0 { direction = -1 }
                else { return }
                if let next = configuration.adjacent(to: selection, direction: direction) {
                    withAnimation(.easeOut(duration: 0.2)) { selection = next }
                }
            })
        }
        .onAppear { selection = configuration.resolvedSelection(selection) }
        .onChange(of: rawConfiguration) { _, _ in
            selection = configuration.resolvedSelection(selection)
        }
    }

    @ViewBuilder
    private func tabLabel(_ tab: AppTab) -> some View {
        if expertMode {
            icon(tab).accessibilityLabel(localized(tab.titleKey))
        } else {
            Label {
                Text(localized(tab.titleKey))
            } icon: {
                icon(tab)
            }
        }
    }

    @ViewBuilder
    private func icon(_ tab: AppTab) -> some View {
        if let asset = tab.assetName {
            Image(asset)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 24, height: 21)
        } else {
            Image(systemName: tab.systemImage)
        }
    }
}
