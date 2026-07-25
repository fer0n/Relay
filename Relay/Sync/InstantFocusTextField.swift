//
//  InstantFocusTextField.swift
//  Relay
//
//  The manual-entry amount field, wrapped in UIKit purely so the keyboard
//  shows up immediately.
//
//  A SwiftUI `TextField` focused via `@FocusState` in `.onAppear` doesn't get
//  its keyboard until *after* the presenting sheet's transition commits —
//  SwiftUI applies the focus change at the end of the update cycle, and UIKit
//  then animates the keyboard as a second, separate step. Inside a sheet
//  (doubly so behind a `.zoom` navigation transition) that reads as a
//  consistent lag on every single open, not just the first.
//
//  Asking for first responder from `didMoveToWindow` instead puts the request
//  in during the sheet's own layout pass, so the keyboard rises *with* the
//  sheet rather than behind it.
//

import SwiftUI
import UIKit

/// `UITextField` that claims first responder as soon as it lands in a window.
final class AutoFocusingTextField: UITextField {
    private var hasFocused = false

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard !hasFocused, window != nil else { return }
        hasFocused = true
        becomeFirstResponder()
    }
}

struct InstantFocusTextField: UIViewRepresentable {
    @Binding var text: String
    let placeholder: String

    func makeUIView(context: Context) -> AutoFocusingTextField {
        let field = AutoFocusingTextField()
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
        // Don't clobber what the user is mid-way through typing — only push
        // the binding down when it genuinely diverges (e.g. a prefill landing).
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

        /// The chevron-down dismiss button, as an `inputAccessoryView` rather
        /// than a SwiftUI `.toolbar(placement: .keyboard)`. That placement only
        /// works for text inputs SwiftUI itself manages — it has no hook into a
        /// raw `UITextField` — so the bar has to be built here to appear at all.
        /// Mirrors `dismissButtonToolbar(isFocused:)` in Theme.swift.
        func makeDismissBar(for field: UITextField) -> UIToolbar {
            self.field = field
            let bar = UIToolbar()
            bar.tintColor = .label
            let dismiss = UIBarButtonItem(
                image: UIImage(systemName: "chevron.down"),
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
