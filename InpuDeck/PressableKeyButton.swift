import SwiftUI
import UIKit

struct PressableKeyButton: UIViewRepresentable {
    let title: String
    var systemImage: String? = nil
    var secondaryTitle: String? = nil
    var secondaryTitleScale: CGFloat = 0.72
    var isActive: Bool = false
    var isProminent: Bool = false
    var isCompact: Bool = false
    var fontSize: CGFloat? = nil
    var minHeight: CGFloat = 44

    var onPress: () -> Void
    var onRelease: () -> Void
    /// When set, a drag that starts on this key becomes pointer movement instead
    /// of a key press. Taps and stationary holds keep their normal behaviour.
    var swipePointer: KeyboardSwipePointer? = nil
    var accessibilityIdentifier: String? = nil

    func makeUIView(context: Context) -> KeyUIButton {
        let button = KeyUIButton(type: .custom)
        button.baseTitle = title
        button.systemImage = systemImage
        button.secondaryTitle = secondaryTitle
        button.secondaryTitleScale = secondaryTitleScale
        button.isActive = isActive
        button.isProminent = isProminent
        button.isCompact = isCompact
        button.fontSize = fontSize
        button.minHeight = minHeight
        button.applyConfiguration()
        button.onPress = onPress
        button.onRelease = onRelease
        button.swipePointer = swipePointer
        button.setAccessibilityIdentifier(accessibilityIdentifier ?? "")
        button.resetTouchState()

        return button
    }

    func updateUIView(_ uiView: KeyUIButton, context: Context) {
        uiView.baseTitle = title
        uiView.systemImage = systemImage
        uiView.secondaryTitle = secondaryTitle
        uiView.secondaryTitleScale = secondaryTitleScale
        uiView.isActive = isActive
        uiView.isProminent = isProminent
        uiView.isCompact = isCompact
        uiView.fontSize = fontSize
        uiView.minHeight = minHeight
        uiView.applyConfiguration()
        // The closures change every time the surrounding view is rebuilt, for
        // example when the layout or caps lock changes. In-flight touches keep
        // the handler they started with so a press is always paired with its own
        // release.
        uiView.onPress = onPress
        uiView.onRelease = onRelease
        uiView.swipePointer = swipePointer
        uiView.setAccessibilityIdentifier(accessibilityIdentifier ?? "")
        if uiView.swipePointer !== swipePointer {
            uiView.resetTouchState()
        }
    }
}

final class KeyUIButton: UIButton {
    var baseTitle: String = "" {
        didSet {
            if baseTitle != oldValue {
                applyConfiguration()
            }
        }
    }
    var secondaryTitle: String? {
        didSet {
            if secondaryTitle != oldValue {
                applyConfiguration()
            }
        }
    }
    var systemImage: String? {
        didSet {
            if systemImage != oldValue {
                applyConfiguration()
            }
        }
    }
    var secondaryTitleScale: CGFloat = 0.72 {
        didSet {
            if secondaryTitleScale != oldValue {
                applyConfiguration()
            }
        }
    }
    var isActive: Bool = false {
        didSet {
            if isActive != oldValue {
                applyConfiguration()
            }
        }
    }
    var isProminent: Bool = false {
        didSet {
            if isProminent != oldValue {
                applyConfiguration()
            }
        }
    }
    var isCompact: Bool = false {
        didSet {
            if isCompact != oldValue {
                applyConfiguration()
            }
        }
    }
    var fontSize: CGFloat? {
        didSet {
            if fontSize != oldValue {
                applyConfiguration()
            }
        }
    }
    var minHeight: CGFloat = 44 {
        didSet {
            if minHeight != oldValue {
                heightConstraint?.constant = minHeight
            }
        }
    }

    private var heightConstraint: NSLayoutConstraint?
    private let secondaryTitleLabel = UILabel()

    override var isHighlighted: Bool {
        didSet {
            if isHighlighted != oldValue {
                updateColors()
            }
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        // Separate keys must be able to receive simultaneous fingers for
        // hardware-like chords (for example Ctrl+Alt+Delete).
        isExclusiveTouch = false
        
        configuration = nil
        contentHorizontalAlignment = .center
        contentVerticalAlignment = .center
        titleLabel?.adjustsFontSizeToFitWidth = true
        titleLabel?.minimumScaleFactor = 0.65
        titleLabel?.lineBreakMode = .byClipping
        titleLabel?.numberOfLines = 1
        titleLabel?.textAlignment = .center

        secondaryTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        secondaryTitleLabel.isUserInteractionEnabled = false
        secondaryTitleLabel.textAlignment = .right
        secondaryTitleLabel.adjustsFontSizeToFitWidth = true
        secondaryTitleLabel.minimumScaleFactor = 0.75
        addSubview(secondaryTitleLabel)
        NSLayoutConstraint.activate([
            secondaryTitleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            secondaryTitleLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            secondaryTitleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 3)
        ])
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous
        clipsToBounds = true
        
        // Create height constraint once
        heightConstraint = heightAnchor.constraint(greaterThanOrEqualToConstant: minHeight)
        heightConstraint?.isActive = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // Touch handling lives here rather than in target-action callbacks so one
    // finger's whole path (down, moved, up) is visible: that is what lets a drag
    // be told apart from a press.
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    var swipePointer: KeyboardSwipePointer?

    private struct TouchState {
        let press: () -> Void
        let release: () -> Void
        var keySent = false
        var swipeActive = false
        var pendingPress: DispatchWorkItem?
    }

    private var touchStates: [ObjectIdentifier: TouchState] = [:]

    func resetTouchState() {
        for state in touchStates.values {
            state.pendingPress?.cancel()
        }
        touchStates.removeAll()
        swipePointer?.reset()
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        for touch in touches { beginTouch(touch) }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesMoved(touches, with: event)
        for touch in touches { dragTouch(touch) }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches { endTouch(touch) }
        super.touchesEnded(touches, with: event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches { endTouch(touch) }
        super.touchesCancelled(touches, with: event)
    }

    // VoiceOver activation has no finger path, so treat it as a plain tap.
    override func accessibilityActivate() -> Bool {
        guard let press = onPress, let release = onRelease else { return false }
        press()
        release()
        return true
    }

    private func beginTouch(_ touch: UITouch) {
        guard let press = onPress, let release = onRelease else { return }
        let token = ObjectIdentifier(touch)
        var state = TouchState(press: press, release: release)

        if let swipe = swipePointer {
            swipe.begin(token, at: touch.location(in: self))
            touchStates[token] = state
            scheduleDeferredPress(token)
        } else {
            state.keySent = true
            touchStates[token] = state
            press()
        }
    }

    private func dragTouch(_ touch: UITouch) {
        let token = ObjectIdentifier(touch)
        guard var state = touchStates[token] else { return }

        if let swipe = swipePointer, swipe.dragged(token, to: touch.location(in: self)) {
            if !state.swipeActive {
                state.swipeActive = true
                state.pendingPress?.cancel()
                state.pendingPress = nil
                // A key-down that slipped through the grace window is released
                // immediately, so the swipe cannot keep typing.
                if state.keySent {
                    state.keySent = false
                    state.release()
                }
            }
        }
        touchStates[token] = state
    }

    private func endTouch(_ touch: UITouch) {
        let token = ObjectIdentifier(touch)
        guard var state = touchStates.removeValue(forKey: token) else { return }
        state.pendingPress?.cancel()

        if swipePointer?.end(token) ?? false {
            return
        }

        if state.keySent {
            state.release()
        } else {
            // The finger never travelled far enough to swipe: send a full tap.
            state.press()
            state.release()
        }
    }

    private func scheduleDeferredPress(_ token: ObjectIdentifier) {
        guard let grace = swipePointer?.pressGrace else { return }
        let work = DispatchWorkItem { [weak self] in self?.commitPress(token) }
        touchStates[token]?.pendingPress = work
        DispatchQueue.main.asyncAfter(deadline: .now() + grace, execute: work)
    }

    private func commitPress(_ token: ObjectIdentifier) {
        guard var state = touchStates[token], !state.swipeActive, !state.keySent else { return }
        if let swipe = swipePointer, swipe.looksLikeDrag(token) {
            // Still travelling: decide again after the next grace window.
            scheduleDeferredPress(token)
            return
        }
        state.keySent = true
        touchStates[token] = state
        state.press()
    }

    func applyConfiguration() {
        UIView.performWithoutAnimation {
            titleLabel?.font = UIFont.monospacedSystemFont(
                ofSize: fontSize ?? (isCompact ? 10 : 16),
                weight: .semibold
            )
            contentEdgeInsets = isCompact
                ? UIEdgeInsets(top: 2, left: 3, bottom: 2, right: 3)
                : UIEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
            layer.cornerRadius = isCompact ? 8 : 12
            updateColors()
        }
    }

    private func updateColors() {
        let pressed = isHighlighted
        let active = isActive

        let bg: UIColor
        let foreground: UIColor
        if isProminent {
            bg = pressed ? UIColor.systemRed.withAlphaComponent(0.75) : UIColor.systemRed
            foreground = .white
        } else if active {
            bg = pressed ? UIColor.systemBlue.withAlphaComponent(0.65) : UIColor.systemBlue.withAlphaComponent(0.9)
            foreground = .white
        } else {
            bg = pressed ? UIColor.secondarySystemFill : UIColor.tertiarySystemFill
            foreground = .label
        }

        backgroundColor = bg
        updateTitle(foreground: foreground)
    }

    private func updateTitle(foreground: UIColor) {
        setAttributedTitle(nil, for: .normal)
        setAttributedTitle(nil, for: .highlighted)
        setTitle(baseTitle, for: .normal)
        setImage(systemImage.flatMap { UIImage(systemName: $0) }, for: .normal)
        tintColor = foreground
        setTitleColor(foreground, for: .normal)
        setTitleColor(foreground, for: .highlighted)

        guard let secondaryTitle, !secondaryTitle.isEmpty else {
            secondaryTitleLabel.text = nil
            secondaryTitleLabel.isHidden = true
            accessibilityLabel = baseTitle
            accessibilityValue = nil
            return
        }

        let mainSize = fontSize ?? (isCompact ? 10 : 16)
        titleLabel?.font = UIFont.monospacedSystemFont(
            ofSize: mainSize,
            weight: .bold
        )
        secondaryTitleLabel.text = secondaryTitle
        secondaryTitleLabel.font = UIFont.monospacedSystemFont(
            ofSize: max(7, mainSize * min(max(secondaryTitleScale, 0.35), 1)),
            weight: .medium
        )
        secondaryTitleLabel.textColor = foreground.withAlphaComponent(0.62)
        secondaryTitleLabel.isHidden = false
        accessibilityLabel = baseTitle
        accessibilityValue = localizedFormat("Друга розкладка: %@", secondaryTitle)
    }
}
