import SwiftUI
import UIKit

/// A native multiline editor whose selection survives opening the legend.
/// Unlike the input tab editor, programmatic insertion must not move to the end.
struct CommandBodyEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange
    @Binding var wantsFocus: Bool

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textColor = .label
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.spellCheckingType = .no
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.textContainer.lineFragmentPadding = 0
        view.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.accessibilityIdentifier = "commandBody"
        view.accessibilityLabel = localized("Тіло команди")
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.isUpdating = true
        if view.markedTextRange == nil {
            if view.text != text { view.text = text }
            let desired = CommandTextInsertion.normalized(selection, in: view.text ?? "")
            if view.selectedRange != desired { view.selectedRange = desired }
        }
        coordinator.isUpdating = false
        // Act on focus-intent changes, not every transient responder mismatch.
        // Otherwise an update during a Name-field tap can queue a stale body
        // focus request and steal the keyboard from that field.
        let requested = wantsFocus
        if coordinator.lastFocusRequest != requested {
            coordinator.lastFocusRequest = requested
            if requested != view.isFirstResponder {
                DispatchQueue.main.async { [weak view, weak coordinator] in
                    guard let view, let coordinator,
                          coordinator.parent.wantsFocus == requested else { return }
                    if requested {
                        view.becomeFirstResponder()
                        view.scrollRangeToVisible(view.selectedRange)
                    } else {
                        view.resignFirstResponder()
                    }
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: CommandBodyEditor
        var isUpdating = false
        var lastFocusRequest: Bool?
        init(parent: CommandBodyEditor) { self.parent = parent }

        func textViewDidChange(_ view: UITextView) {
            guard !isUpdating else { return }
            parent.text = view.text ?? ""
            parent.selection = view.selectedRange
        }
        func textViewDidChangeSelection(_ view: UITextView) {
            guard !isUpdating, view.markedTextRange == nil else { return }
            if parent.selection != view.selectedRange { parent.selection = view.selectedRange }
        }
        func textViewDidBeginEditing(_ view: UITextView) {
            if !parent.wantsFocus { parent.wantsFocus = true }
        }
        func textViewDidEndEditing(_ view: UITextView) {
            if parent.wantsFocus { parent.wantsFocus = false }
        }
    }
}
