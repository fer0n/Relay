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
/// Visible on the root list, the Splitwise balances grid, and any friend's or
/// group's transactions page; hidden everywhere else (Templates, Settings, …).
/// On one of those pages it opens pre-scoped to that friend or group;
/// everywhere else it opens blank.
private struct FloatingAddButtonModifier: ViewModifier {
    let path: [ContentRoute]
    let namespace: Namespace.ID
    let onTapDefault: () -> Void
    let onTapTarget: (SplitwiseSplitTargetEntity) -> Void

    private var isVisible: Bool {
        switch path.last {
        case nil, .splitwiseBalances, .splitwiseFriendTransactions, .splitwiseGroupTransactions:
            return true
        default:
            return false
        }
    }

    /// Nil unless the top of the stack is a specific friend's or group's page —
    /// including if the cache lookup for that route's id somehow comes up empty.
    private var scopedTarget: SplitwiseSplitTargetEntity? {
        switch path.last {
        case .splitwiseFriendTransactions(let friendId):
            return SplitwiseFriendCacheStore.load()?.first { $0.id == friendId }
                .map { SplitwiseSplitTargetEntity(friend: $0) }
        case .splitwiseGroupTransactions(let groupId):
            return SplitwiseGroupCacheStore.load()?.first { $0.id == groupId }
                .map { SplitwiseSplitTargetEntity(group: $0) }
        default:
            return nil
        }
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
        onTapTarget: @escaping (SplitwiseSplitTargetEntity) -> Void
    ) -> some View {
        modifier(FloatingAddButtonModifier(path: path, namespace: namespace, onTapDefault: onTapDefault, onTapTarget: onTapTarget))
    }
}
