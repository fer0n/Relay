//
//  InstantFocusTextField.swift
//  Relay
//
//  The manual-entry amount field, wrapped in UIKit purely so the keyboard shows
//  up immediately.
//
//  A SwiftUI `TextField` focused via `@FocusState` in `.onAppear` doesn't get its
//  keyboard until *after* the presenting sheet's transition commits: SwiftUI
//  applies the focus at the end of the update cycle, and UIKit animates the
//  keyboard as a second step. Asking for first responder from `didMoveToWindow`
//  instead puts the request in during the sheet's own layout pass, so the
//  keyboard rises *with* the sheet rather than behind it.
//
//  Auto-focusing is opt-out (`autoFocuses`) because a "Re-add" already has an
//  amount and opens for review, where the keyboard would only cover the fields
//  being checked.
//

import SwiftUI
import UIKit

/// `UITextField` that claims first responder as soon as it lands in a window,
/// unless `focusesOnAppearing` is cleared before it gets there.
final class AutoFocusingTextField: UITextField {
    /// Set once at creation. Not a live "focus me now" switch — just whether the
    /// one automatic grab on first appearance happens at all.
    var focusesOnAppearing = true
    private var hasFocused = false

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard focusesOnAppearing, !hasFocused, window != nil else { return }
        hasFocused = true
        becomeFirstResponder()
    }
}

struct InstantFocusTextField: UIViewRepresentable {
    @Binding var text: String
    let placeholder: String
    /// False for a pre-filled amount — see this file's header.
    var autoFocuses: Bool = true

    func makeUIView(context: Context) -> AutoFocusingTextField {
        let field = AutoFocusingTextField()
        field.focusesOnAppearing = autoFocuses
        field.addTarget(context.coordinator, action: #selector(Coordinator.textChanged(_:)), for: .editingChanged)
        field.inputAccessoryView = context.coordinator.makeDismissBar(for: field)

        field.keyboardType = .decimalPad
        field.textAlignment = .center
        field.font = .systemFont(ofSize: 50, weight: .heavy)
        field.textColor = UIColor(Color.foregroundColor)
        field.tintColor = UIColor(Color.foregroundColor)

        // Mirrors `.minimumScaleFactor(0.5)` on the SwiftUI original.
        field.adjustsFontSizeToFitWidth = true
        field.minimumFontSize = 25

        field.attributedPlaceholder = NSAttributedString(
            string: placeholder,
            attributes: [
                .foregroundColor: UIColor.placeholderText,
                .font: UIFont.systemFont(ofSize: 50, weight: .heavy)
            ]
        )
        field.text = text
        return field
    }

    func updateUIView(_ field: AutoFocusingTextField, context: Context) {
        // Only push the binding down when it genuinely diverges, so this can't
        // clobber what the user is mid-way through typing.
        if field.text != text {
            field.text = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject {
        private let parent: InstantFocusTextField
        private weak var field: UITextField?

        init(_ parent: InstantFocusTextField) {
            self.parent = parent
        }

        @objc func textChanged(_ field: UITextField) {
            parent.text = field.text ?? ""
        }

        /// An `inputAccessoryView` rather than `.toolbar(placement: .keyboard)`,
        /// which only works for text inputs SwiftUI itself manages and has no hook
        /// into a raw `UITextField`. Mirrors Theme.swift's `dismissButtonToolbar`.
        func makeDismissBar(for field: UITextField) -> UIToolbar {
            self.field = field
            let bar = UIToolbar()
            bar.tintColor = .label
            let dismiss = UIBarButtonItem(
                image: UIImage(systemName: Const.Symbol.dismissKeyboard),
                style: .plain,
                target: self,
                action: #selector(dismissKeyboard)
            )
            dismiss.accessibilityLabel = String(localized: "Dismiss")
            bar.items = [UIBarButtonItem(systemItem: .flexibleSpace), dismiss]
            bar.sizeToFit()
            return bar
        }

        @objc private func dismissKeyboard() {
            field?.resignFirstResponder()
        }
    }
}
