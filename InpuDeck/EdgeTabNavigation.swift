import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Marker for views whose own touch handling already drives keyboard pointer
/// swipes. An edge pan must never run alongside them: a swipe that starts on
/// such a view belongs to the keyboard, not to tab navigation.
protocol KeyGestureParticipant: AnyObject {}

/// A navigation pan that fails immediately when its first touch is not at an
/// edge. A recognizer covering the whole tab view can otherwise compete with
/// keyboard-key touches even when its eventual action ignores the gesture.
struct EdgeTabNavigation: UIViewRepresentable {
    var onNavigate: (Int) -> Void

    func makeUIView(context: Context) -> EdgeTabNavigationView {
        let view = EdgeTabNavigationView()
        view.onNavigate = onNavigate
        return view
    }

    func updateUIView(_ view: EdgeTabNavigationView, context: Context) {
        view.onNavigate = onNavigate
    }
}

final class EdgeTabNavigationView: UIView, UIGestureRecognizerDelegate {
    var onNavigate: (Int) -> Void = { _ in }
    private weak var installedWindow: UIWindow?
    private lazy var pan: EdgeOnlyPanGestureRecognizer = {
        let recognizer = EdgeOnlyPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        recognizer.delegate = self
        recognizer.cancelsTouchesInView = false
        recognizer.maximumNumberOfTouches = 1
        return recognizer
    }()

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if installedWindow !== window {
            installedWindow?.removeGestureRecognizer(pan)
            installedWindow = window
            window?.addGestureRecognizer(pan)
        }
    }

    @objc private func handlePan(_ recognizer: EdgeOnlyPanGestureRecognizer) {
        guard recognizer.state == .ended, let window = installedWindow else { return }
        let translation = recognizer.translation(in: window)
        guard abs(translation.x) >= 120, abs(translation.x) > abs(translation.y) * 1.25 else { return }
        if recognizer.startEdge == .left, translation.x > 0 { onNavigate(-1) }
        if recognizer.startEdge == .right, translation.x < 0 { onNavigate(1) }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }
}

final class EdgeOnlyPanGestureRecognizer: UIPanGestureRecognizer {
    enum Edge { case left, right }
    private(set) var startEdge: Edge?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = touches.first, let window = view as? UIWindow else {
            state = .failed
            return
        }
        let location = touch.location(in: window)
        if location.x <= 28 { startEdge = .left }
        else if location.x >= window.bounds.width - 28 { startEdge = .right }
        else {
            state = .failed
            return
        }
        // The recognizer lives on the window so it can watch whole-screen
        // gestures. That is only correct while the content under the touch
        // actually belongs to the tabs it drives.
        guard !presentsModally(in: window, at: location) else {
            state = .failed
            return
        }
        guard !participatesInKeyboardGestures(in: window, at: location) else {
            state = .failed
            return
        }
        super.touchesBegan(touches, with: event)
    }

    /// A sheet or cover presents its content over the tabs; an edge gesture
    /// there must never switch the tab hidden underneath it.
    private func presentsModally(in window: UIWindow, at location: CGPoint) -> Bool {
        var responder: UIResponder? = window.hitTest(location, with: nil)
        var firstController: UIViewController?
        while let current = responder, firstController == nil {
            if let controller = current as? UIViewController {
                firstController = controller
            }
            responder = current.next
        }
        // Any controller inside a presented stack sits (directly or through
        // parents) under the controller that is being presented.
        var candidate: UIViewController? = firstController
        while let parent = candidate?.parent { candidate = parent }
        return candidate?.presentingViewController != nil
    }

    /// Touches that land on keyboard keys (or pointer click zones) belong to
    /// the keyboard: its own handling turns drags into pointer movement, so the
    /// navigation pan must not also claim the same touch.
    private func participatesInKeyboardGestures(in window: UIWindow, at location: CGPoint) -> Bool {
        guard let hit = window.hitTest(location, with: nil) else { return false }
        var host: UIView? = hit
        while let current = host, current !== window {
            if current is KeyGestureParticipant { return true }
            host = current.superview
        }
        return false
    }

    override func reset() {
        super.reset()
        startEdge = nil
    }
}
