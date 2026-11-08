import SwiftUI

/// The Air mouse surface: it shows how the phone is being held as the pointing
/// stick and offers a way to drop the tilt that is currently held. It owns no
/// touch gestures on purpose, so a phone in a pocket or a bag cannot send
/// pointer reports by accident.
struct AirMousePadView: View {
    @ObservedObject var pointer: AirMousePointer
    var isReady: Bool

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .strokeBorder(
                        Color.primary.opacity(pointer.isTracking ? 0.25 : 0.12),
                        style: StrokeStyle(lineWidth: 1, dash: [5, 5])
                    )
                Image(systemName: "scope")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(pointer.isTracking ? Color.accentColor : Color.secondary)
            }
            .frame(width: 96, height: 96)

            Text(statusText)
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("airMouseStatus")

            Button {
                pointer.recentre()
            } label: {
                Label("Скинути нахил", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(.bordered)
            .disabled(!pointer.isTracking)
            .accessibilityIdentifier("airMouseRecentre")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(12)
    }

    private var statusText: String {
        guard isReady else {
            return localized("Спочатку під’єднай комп’ютер: нахил рухатиме курсор, щойно з’явиться зв’язок.")
        }
        switch pointer.status {
        case .off:
            return localized("Air mouse вимкнено")
        case .waiting:
            return localized("Читаю гіроскоп…")
        case .tracking:
            return localized("Нахиляй телефон — курсор іде за ним. Кнопки кліка — під цим полем.")
        case .unavailable:
            return localized("На цьому пристрої немає гіроскопа")
        case .blocked:
            return localized("iOS не дає доступ до руху: Налаштування → Конфіденційність і безпека → Рух і фітнес")
        }
    }
}
