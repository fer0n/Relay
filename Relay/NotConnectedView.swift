//
//  NotConnectedView.swift
//  Relay
//

import SwiftUI

/// Full-screen "not connected" gate — shown in place of a form when the
/// service it depends on isn't authenticated yet.
struct NotConnectedView: View {
    let service: String
    let connect: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Not Connected", systemImage: "exclamationmark.triangle")
        } description: {
            Text("Connect your \(service) account in Relay first.")
        } actions: {
            Button("Connect", action: connect)
                .buttonStyle(.borderedProminent)
        }
    }
}

/// Same message as `NotConnectedView`, as an inline row rather than a
/// full-screen gate — for forms where only one section (not the whole
/// screen) depends on the service, e.g. a destination picker.
struct NotConnectedRow: View {
    let service: String
    let connect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Connect your \(service) account in Relay first.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("Connect", action: connect)
                .buttonStyle(.bordered)
        }
    }
}

extension View {
    /// Fires `action` once when `isAuthenticated` flips to true — the
    /// common "connect button succeeded" reaction shared by every
    /// `NotConnectedView`/`NotConnectedRow` call site (clear the gate,
    /// reload whatever needed the token).
    func onAuthenticated(_ isAuthenticated: Bool, perform action: @escaping () -> Void) -> some View {
        onChange(of: isAuthenticated) { _, newValue in
            guard newValue else { return }
            action()
        }
    }
}
