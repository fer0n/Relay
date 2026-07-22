//
//  SplitwiseBalanceCard.swift
//  Relay
//
//  Pinned-list-style card (mirrors Reminders' pinned smart lists) shown at
//  the top of ContentView, in place of the logo, once a default Splitwise
//  friend is configured (see SplitwiseDefaultFriendStore). Tapping it opens
//  that friend's transaction history (SplitwiseFriendTransactionsView).
//

import SwiftUI

extension SplitwiseFriend {
    /// e.g. "42.50 €" — falls back to a plain zero if there's no balance at
    /// all. Shared by the balance card and SplitwiseFriendTransactionsView's
    /// navigation subtitle.
    var formattedBalanceText: String {
        guard let primaryBalance else { return 0.asMoneyString }
        return primaryBalance.amount.formatted(.currency(code: primaryBalance.currencyCode))
    }

    /// Matches Splitwise's own convention: positive means the friend owes
    /// the signed-in user (green), negative means the reverse (red). Shared
    /// by the balance card and SplitwiseFriendTransactionsView's navigation
    /// subtitle.
    var balanceColor: Color {
        guard let amount = primaryBalance?.amount else { return .secondary }
        if amount > 0 { return .green }
        if amount < 0 { return .red }
        return .secondary
    }
}

/// Centers the single balance card within the full row width — kept as its
/// own wrapper (rather than inlining the Button in ContentView) so a second
/// pinned card could join it as a real 2-up grid later without touching
/// ContentView.
struct SplitwiseBalanceGrid: View {
    let friend: SplitwiseFriend
    /// When the friend's balance was last actually fetched from Splitwise —
    /// nil hides the "Last refreshed …" line (e.g. before the first fetch
    /// completes).
    var lastRefreshedAt: Date?
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            SplitwiseBalanceCard(friend: friend, lastRefreshedAt: lastRefreshedAt)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }
}

private struct SplitwiseBalanceCard: View {
    let friend: SplitwiseFriend
    var lastRefreshedAt: Date?

    var outerPadding: CGFloat = 18
    var innerRadius: CGFloat = 46

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                Image(systemName: "person.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(width: innerRadius, height: innerRadius)
                    .background(Color.secondary.opacity(0.15), in: Circle())

                Spacer(minLength: 8)

                Text(friend.formattedBalanceText)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(friend.balanceColor)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            Spacer(minLength: 20)

            Text(friend.fullName)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.foregroundColor)
                .lineLimit(1)
                .padding(.leading, 5)

            if let lastRefreshedAt {
                // A coarse, single-unit "time ago" instead of Text's built-in
                // `.relative` style, which counts every second across two
                // units ("1 min, 3 sec ago") and jitters in width. TimelineView
                // ticks it each second; the string only changes once per unit
                // step, and monospaced digits keep the width stable.
                TimelineView(.periodic(from: lastRefreshedAt, by: 1)) { context in
                    Text(lastRefreshedAt.fuzzyRelative(to: context.date))
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.leading, 5)
                        .padding(.top, 2)
                }
            }
        }
        .padding(outerPadding)
        .frame(maxWidth: 230, minHeight: 100, alignment: .topLeading)
        .background(Color.sheetInsetColor, in: RoundedRectangle(cornerRadius: innerRadius / 2 + outerPadding, style: .continuous))
    }
}

#Preview {
    List {
        Section {
            SplitwiseBalanceGrid(
                friend: SplitwiseFriend(id: 1, firstName: "Alex", lastName: nil, balance: [SplitwiseBalance(currencyCode: "EUR", amount: "12.34")]),
                lastRefreshedAt: Date().addingTimeInterval(-320),
                onTap: {}
            )
        }
        .listRowBackground(Color.clear)
    }
}
