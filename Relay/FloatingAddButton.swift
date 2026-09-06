//
//  FloatingAddButton.swift
//  Relay
//

import SwiftUI

/// The "+" that starts a manual entry, pinned bottom-trailing on ContentView's
/// NavigationStack. Attached once at the stack level rather than per-screen —
/// via `.floatingAddButton` on the NavigationStack itself, not on `mainList`
/// or any pushed destination — so it's one persisting view across pushes,
/// animating in/out on `path` changes instead of being torn down and
/// re-mounted per screen.
///
/// Visible on the root list, the Ledgers list, and any single ledger's page;
/// hidden everywhere else (Templates, Settings, …). On a ledger's page it
/// opens pre-scoped to that ledger; everywhere else it opens blank.
private struct FloatingAddButtonModifier: ViewModifier {
    let path: [ContentRoute]
    let namespace: Namespace.ID
    let onTapDefault: () -> Void
    let onTapTarget: (SplitTargetEntity) -> Void

    private var isVisible: Bool {
        switch path.last {
        case nil, .ledgers, .ledger:
            return true
        default:
            return false
        }
    }

    /// Nil unless the top of the stack is a specific ledger's page — including
    /// if that zone name no longer resolves to a loaded ledger.
    @MainActor
    private var scopedTarget: SplitTargetEntity? {
        guard case .ledger(let zoneName) = path.last else { return nil }
        return LedgerStore.shared.ledgers.first { $0.zoneName == zoneName }
            .map { SplitTargetEntity(ledger: $0) }
    }

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .bottom) {
                Group {
                    if isVisible {
                        button
                            .transition(.opacity)
                    }
                }
                .animation(.snappy, value: isVisible)
            }
    }

    private var button: some View {
        Button {
            if let scopedTarget {
                onTapTarget(scopedTarget)
            } else {
                onTapDefault()
            }
        } label: {
            Image(systemName: Const.Symbol.add)
                .font(.title2)
                .fontWeight(.bold)
                .padding(18)
                .glassEffect(.regular.tint(Color.accentColor).interactive())
        }
        .foregroundStyle(Color.backgroundColor)
        .matchedTransitionSource(id: "add", in: namespace)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.horizontal, 30)
    }
}

extension View {
    func floatingAddButton(
        path: [ContentRoute],
        namespace: Namespace.ID,
        onTapDefault: @escaping () -> Void,
        onTapTarget: @escaping (SplitTargetEntity) -> Void
    ) -> some View {
        modifier(FloatingAddButtonModifier(path: path, namespace: namespace, onTapDefault: onTapDefault, onTapTarget: onTapTarget))
    }
}
