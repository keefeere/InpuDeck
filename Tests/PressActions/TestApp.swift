import SwiftUI

@main
struct PressActionsTestApp: App {
    var body: some Scene {
        WindowGroup { PressActionsTestView() }
    }
}

private struct PressActionsTestView: View {
    @State private var languageTaps = 0
    @State private var languageHolds = 0
    @State private var orientationTaps = 0
    @State private var orientationHolds = 0
    @State private var controlsEnabled = true

    // Mirrors the landscape keyboard: a swipeable letter key plus the two
    // pointer click zones.
    @State private var swipePointer = KeyboardSwipePointer()
    @State private var keyPresses = 0
    @State private var keyReleases = 0
    @State private var pointerSteps = 0
    @State private var pointerDistance = 0
    @State private var edgeNavigations = 0
    @State private var leftDown = 0
    @State private var leftUp = 0
    @State private var rightDown = 0
    @State private var rightUp = 0

    var body: some View {
        VStack(spacing: 24) {
            HStack(spacing: 32) {
                Button { languageTaps += 1 } label: {
                    Text(languageTaps.isMultiple(of: 2) ? "UA/EN" : "EN/UA")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .frame(width: 60, height: 36)
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(ShortAndLongPressButtonStyle(
                    longPressLabel: "Layout only", onLongPress: { languageHolds += 1 }
                ))
                .accessibilityLabel("Language")
                .accessibilityIdentifier("languageButton")

                Button { orientationTaps += 1 } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "rectangle.landscape")
                        Image(systemName: orientationTaps.isMultiple(of: 2) ? "lock.open" : "lock.fill")
                    }
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.accentColor.opacity(0.16))
                    .clipShape(Capsule())
                }
                .buttonStyle(ShortAndLongPressButtonStyle(
                    longPressLabel: "Landscape", onLongPress: { orientationHolds += 1 }
                ))
                .accessibilityLabel("Orientation")
                .accessibilityIdentifier("orientationButton")
            }
            .disabled(!controlsEnabled)

            PressableKeyButton(
                title: "A",
                isCompact: true,
                fontSize: 17,
                minHeight: 44,
                onPress: { keyPresses += 1 },
                onRelease: { keyReleases += 1 },
                swipePointer: swipePointer,
                accessibilityIdentifier: "swipeableKey"
            )
                .frame(width: 44, height: 44)
                .accessibilityLabel("Swipeable key")

            PressableKeyButton(
                title: "L",
                isCompact: true,
                fontSize: 11,
                minHeight: 44,
                onPress: { leftDown += 1 },
                onRelease: { leftUp += 1 },
                accessibilityIdentifier: "leftClickZone"
            )
                .frame(width: 44, height: 44)

            PressableKeyButton(
                title: "R",
                isCompact: true,
                fontSize: 11,
                minHeight: 44,
                onPress: { rightDown += 1 },
                onRelease: { rightUp += 1 },
                accessibilityIdentifier: "rightClickZone"
            )
                .frame(width: 44, height: 44)

            Text("\(keyPresses):\(keyReleases):\(pointerSteps)").accessibilityIdentifier("swipeCounts")
            Text("\(pointerDistance):\(edgeNavigations)").accessibilityIdentifier("pointerDistance")
            Text("\(leftDown):\(leftUp):\(rightDown):\(rightUp)").accessibilityIdentifier("clickCounts")
            Text("\(languageTaps):\(languageHolds)").accessibilityIdentifier("languageCounts")
            Text("\(orientationTaps):\(orientationHolds)").accessibilityIdentifier("orientationCounts")
            Button("Disable controls") { controlsEnabled = false }
                .accessibilityIdentifier("disableControls")
            Text(controlsEnabled ? "enabled" : "disabled").accessibilityIdentifier("enabledState")
        }
        .padding(24)
        .background(EdgeTabNavigation { _ in edgeNavigations += 1 })
        .onAppear {
            swipePointer.onPointerMove = { dx, _ in
                pointerSteps += 1
                pointerDistance += Int(dx)
            }
        }
    }
}
