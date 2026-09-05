//
//  SplitwiseErrorAlert.swift
//  Relay
//

import SwiftUI

struct SplitwiseDisplayError {
    let message: String
    let isContactable: Bool

    static func from(_ error: Error, fallback: String) -> SplitwiseDisplayError {
        switch error {
        case SplitwiseAPIError.forbidden(let message):
            return SplitwiseDisplayError(message: message, isContactable: true)
        case SplitwiseAPIError.validation(let message):
            return SplitwiseDisplayError(message: message, isContactable: false)
        default:
            return SplitwiseDisplayError(message: fallback, isContactable: false)
        }
    }
}

extension View {
    func splitwiseErrorAlert(_ title: String, error: Binding<SplitwiseDisplayError?>) -> some View {
        modifier(SplitwiseErrorAlertModifier(title: title, error: error))
    }
}

private struct SplitwiseErrorAlertModifier: ViewModifier {
    let title: String
    @Binding var error: SplitwiseDisplayError?
    @Environment(\.openURL) private var openURL

    func body(content: Content) -> some View {
        content.alert(
            title,
            isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })
        ) {
            if error?.isContactable == true {
                Button("Contact Developer") {
                    if let message = error?.message {
                        openURL(SignInErrorMail.reportURL(service: "Splitwise", message: message, detail: nil))
                    }
                }
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(error?.message ?? "")
        }
    }
}
