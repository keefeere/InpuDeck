import SwiftUI

/// The Air mouse surface: it shows how the phone is being held as the pointing
/// stick and offers a way to drop whatever the pointer is holding on to. It owns
/// no touch gestures on purpose, so a phone in a pocket or a bag cannot send
/// pointer reports by accident.
struct AirMousePadView: View {
    @ObservedObject var pointer: AirMousePointer
    var isReady: Bool
    /// Expert mode drops the explanation, not the diagnosis: a surface that says
    /// nothing because the gyroscope is missing or the permission was refused is a
    /// surface that looks broken.
    var expertMode: Bool = false
    /// The two click buttons live *in* this surface, tall enough to be found by
    /// feel: pointing with the phone at arm's length means the screen is not what
    /// the eye is on, so a 48 pt row under the field is a target the thumb has to
    /// hunt for.
    var onPressLeft: () -> Void
    var onReleaseLeft: () -> Void
    var onPressRight: () -> Void
    var onReleaseRight: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                PressableKeyButton(
                    title: expertMode ? "" : localized("Ліва кнопка"),
                    minHeight: 96,
                    onPress: onPressLeft,
                    onRelease: onReleaseLeft
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Ліва кнопка")

                PressableKeyButton(
                    title: expertMode ? "" : localized("Права кнопка"),
                    minHeight: 96,
                    onPress: onPressRight,
                    onRelease: onReleaseRight
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Права кнопка")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let caption = caption {
                Text(caption)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("airMouseStatus")
            }

            Button {
                pointer.recentre()
            } label: {
                if expertMode {
                    Image(systemName: "arrow.counterclockwise")
                } else {
                    Label("Скинути нахил", systemImage: "arrow.counterclockwise")
                }
            }
            .buttonStyle(.bordered)
            .disabled(!pointer.isTracking)
            .accessibilityIdentifier("airMouseRecentre")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(12)
    }

    private var caption: String? {
        guard isReady else {
            return localized("Спочатку під’єднай комп’ютер: нахил рухатиме курсор, щойно з’явиться зв’язок, а кнопки кліка вже тут.")
        }
        switch pointer.status {
        case .off:
            return expertMode ? nil : localized("Air mouse вимкнено")
        case .waiting:
            return localized("Читаю гіроскоп…")
        case .tracking:
            return expertMode
                ? nil
                : localized("Крути телефон — курсор іде за ним. Кнопки кліка — тут, під великим пальцем.")
        case .unavailable:
            return localized("На цьому пристрої немає гіроскопа")
        case .blocked:
            return localized("iOS не дає доступ до руху: Налаштування → Конфіденційність і безпека → Рух і фітнес")
        }
    }
}
