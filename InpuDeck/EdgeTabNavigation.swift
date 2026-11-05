import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

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
        guard let touch = touches.first, let view = view else {
            state = .failed
            return
        }
        let x = touch.location(in: view).x
        if x <= 28 { startEdge = .left }
        else if x >= view.bounds.width - 28 { startEdge = .right }
        else {
            state = .failed
            return
        }
        super.touchesBegan(touches, with: event)
    }

    override func reset() {
        super.reset()
        startEdge = nil
    }
}
