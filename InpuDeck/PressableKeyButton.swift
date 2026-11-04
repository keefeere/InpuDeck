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
        button.accessibilityIdentifier = accessibilityIdentifier ?? ""

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
        uiView.accessibilityIdentifier = accessibilityIdentifier ?? ""
        // Compare before assigning: the button must know whether the gesture
        // object it was tracking with is gone. A brand-new key button appearing
        // while another key is being swiped must not disturb that swipe.
        if uiView.swipePointer !== swipePointer {
            uiView.clearOwnTouches()
        }
        uiView.swipePointer = swipePointer
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
        var moved = false
        let start: CGPoint
        var pendingPress: DispatchWorkItem?
    }

    private var touchStates: [ObjectIdentifier: TouchState] = [:]

    /// Releases this button's own in-flight touches and drops them from the shared
    /// gesture object; a swipe running on another key keeps tracking.
    func clearOwnTouches() {
        for (token, state) in touchStates {
            state.pendingPress?.cancel()
            if state.keySent {
                state.release()
            }
            swipePointer?.end(token)
        }
        touchStates.removeAll()
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
        for touch in touches { endTouch(touch, cancelled: false) }
        super.touchesEnded(touches, with: event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches { endTouch(touch, cancelled: true) }
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
        var state = TouchState(press: press, release: release, start: touch.location(in: self))

        if let swipe = swipePointer {
            swipe.begin(token, at: touch.location(in: self))
            state.pendingPress = scheduleDeferredPress(token)
            touchStates[token] = state
        } else {
            state.keySent = true
            touchStates[token] = state
            press()
        }
    }

    private func dragTouch(_ touch: UITouch) {
        let token = ObjectIdentifier(touch)
        let point = touch.location(in: self)
        guard var state = touchStates[token] else { return }

        if let swipe = swipePointer {
            // The button tracks drift itself, so a gesture that the system
            // interrupts, or that resets the shared pointer underneath it, can
            // never end up typing a key the host was never told about.
            if !state.moved, hypot(point.x - state.start.x, point.y - state.start.y) > swipe.tapTolerance {
                state.moved = true
            }
            if swipe.dragged(token, to: point) {
                if !state.swipeActive {
                    state.swipeActive = true
                    state.pendingPress?.cancel()
                    state.pendingPress = nil
                    // A key-down that slipped through the hold window is released
                    // immediately, so the swipe cannot keep the key held.
                    if state.keySent {
                        state.keySent = false
                        state.release()
                    }
                }
            } else if !state.keySent {
                // Still travelling inside the tap tolerance: postpone the hold
                // press so a drag that started late never types a character.
                // Once the finger has drifted past it, no key can be held.
                state.pendingPress?.cancel()
                state.pendingPress = state.moved ? nil : scheduleDeferredPress(token)
            }
        }
        touchStates[token] = state
    }

    private func endTouch(_ touch: UITouch, cancelled: Bool) {
        let token = ObjectIdentifier(touch)
        guard var state = touchStates.removeValue(forKey: token) else { return }
        state.pendingPress?.cancel()

        if swipePointer?.end(token) ?? false {
            return
        }

        if state.keySent {
            state.release()
        } else if !cancelled, !state.moved {
            // The finger lifted without travelling far enough to swipe: a full tap.
            // A touch that drifted, or a gesture the system cancelled, types nothing.
            state.press()
            state.release()
        }
    }

    private func scheduleDeferredPress(_ token: ObjectIdentifier) -> DispatchWorkItem? {
        guard let delay = swipePointer?.holdCommitDelay else { return nil }
        let work = DispatchWorkItem { [weak self] in self?.commitPress(token) }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        return work
    }

    private func commitPress(_ token: ObjectIdentifier) {
        guard var state = touchStates[token], !state.swipeActive, !state.keySent, !state.moved else { return }
        // A touch that has already travelled is latched: it becomes a swipe, or a
        // tap on lift, but never a held key the host has already been told about.
        guard swipePointer?.canCommitPress(token) ?? false else {
            state.pendingPress = nil
            touchStates[token] = state
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
