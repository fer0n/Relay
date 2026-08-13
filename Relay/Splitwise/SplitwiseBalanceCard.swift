//
//  SplitwiseBalanceCard.swift
//  Relay
//
//  Pinned-list-style card (mirrors Reminders' pinned smart lists) shown at
//  the top of ContentView, in place of the logo, once a default Splitwise
//  friend is configured (see SplitwiseDefaultFriendStore). Tapping it opens
//  that friend's transaction history (SplitwiseTransactionsView).
//

import SwiftUI

extension Color {
    /// Splitwise's own convention: positive means money is owed *to* whoever the
    /// figure describes (green). Shared by the card's headline balance, its
    /// per-member breakdown and SplitwiseTransactionsView's navigation subtitle,
    /// so the three can't drift apart.
    static func splitwiseBalance(_ amount: Double?) -> Color {
        (amount ?? 0) > 0 ? Color.accentColor : .primary
    }
}

extension SplitwiseFriend {
    /// e.g. "42.50 €" — falls back to a plain zero if there's no balance at
    /// all. Shared by the balance card and SplitwiseTransactionsView's
    /// navigation subtitle.
    var formattedBalanceText: String {
        guard let primaryBalance else { return 0.asMoneyString }
        return primaryBalance.amount.formatted(.currency(code: primaryBalance.currencyCode))
    }

    /// Positive means the friend owes the signed-in user.
    var balanceColor: Color {
        .splitwiseBalance(primaryBalance?.amount)
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

/// `maxWidth` defaults to the fixed width `SplitwiseBalanceGrid` centers on
/// ContentView; `SplitwiseBalancesView` passes `.infinity` so each card fills
/// its grid column instead.
///
/// Takes the already-formatted name/balance rather than a friend, so a group's
/// standing renders through the same card — see the two convenience inits.
struct SplitwiseBalanceCard: View {
    /// `.large` is ContentView's original single pinned card; `.compact`
    /// tightens padding/type sizes for the 2-up grid in
    /// SplitwiseBalancesView, where there's much less width per card.
    enum Size {
        case large
        case compact
    }

    /// One member's own standing inside a group, e.g. "Katha: -25.00 €" —
    /// negative means they owe the group.
    struct MemberBalance: Identifiable {
        let id: Int
        let name: String
        let amountText: String
        /// The same rule the headline balance follows, so a member who's owed
        /// reads the same way the card itself would.
        let amountColor: Color
    }

    let name: String
    let avatarURL: URL?
    let balanceText: String
    let balanceColor: Color
    /// Stands in for a missing picture: a group reads as two people, not one.
    let avatarFallbackSymbol: String
    /// Groups only: who inside the group is up or down. A friend's card has
    /// nothing to break down — their balance *is* the whole story.
    let memberBalances: [MemberBalance]
    var lastRefreshedAt: Date?
    var size: Size = .large
    var maxWidth: CGFloat? = 210

    init(
        friend: SplitwiseFriend,
        lastRefreshedAt: Date? = nil,
        size: Size = .large,
        maxWidth: CGFloat? = 210
    ) {
        name = friend.fullName
        avatarURL = friend.avatarURL
        balanceText = friend.formattedBalanceText
        balanceColor = friend.balanceColor
        avatarFallbackSymbol = Const.Symbol.person
        memberBalances = []
        self.lastRefreshedAt = lastRefreshedAt
        self.size = size
        self.maxWidth = maxWidth
    }

    /// A group's card shows what the signed-in user is up or down across the
    /// whole group, which is the only balance a group has from their side.
    init(
        group: SplitwiseGroup,
        currentUserId: Int?,
        lastRefreshedAt: Date? = nil,
        size: Size = .large,
        maxWidth: CGFloat? = 210
    ) {
        let balance = group.currentUserBalance(currentUserId: currentUserId)
        name = group.name
        avatarURL = group.avatarURL
        balanceText = balance.map { $0.amount.formatted(.currency(code: $0.currencyCode)) } ?? 0.asMoneyString
        balanceColor = .splitwiseBalance(balance?.amount)
        avatarFallbackSymbol = Const.Symbol.friends
        // Biggest first, so a card that can only show a couple of lines shows
        // the ones worth chasing. What counts as a standing depends on the
        // group's "simplify debts" setting — see memberStandings.
        memberBalances = group.memberStandings(currentUserId: currentUserId)
            .sorted { abs($0.amount) > abs($1.amount) }
            .map {
                MemberBalance(
                    id: $0.memberId,
                    name: $0.name,
                    amountText: $0.amount.formatted(.currency(code: $0.currencyCode)),
                    amountColor: .splitwiseBalance($0.amount)
                )
            }
        self.lastRefreshedAt = lastRefreshedAt
        self.size = size
        self.maxWidth = maxWidth
    }

    private var outerPadding: CGFloat { size == .large ? 15 : 15 }
    private var innerDiameter: CGFloat { size == .large ? 40 : 35 }
    private var iconFont: Font { size == .large ? .title2 : .title3 }
    private var balanceFont: Font { size == .large ? .title2.weight(.bold) : .title3.weight(.bold) }
    /// Negative padding around the icon circle in `.compact` — shrinks its
    /// reserved layout space (without shrinking the circle itself) so it
    /// sits tighter against the card's edge and the balance text.
    private var iconNegativePadding: CGFloat { size == .large ? 0 : 5 }

    var body: some View {
        Group {
            if size == .large {
                cardContent
                    .padding(outerPadding)
                    .frame(maxWidth: maxWidth, minHeight: 100, alignment: .topLeading)
                    .background(Color.sheetInsetColor, in: RoundedRectangle(cornerRadius: innerDiameter / 2 + outerPadding - iconNegativePadding, style: .continuous))
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: innerDiameter / 2 + outerPadding - iconNegativePadding, style: .continuous))
            } else {
                cardContent
                    .padding(outerPadding)
                    .frame(maxWidth: maxWidth, minHeight: 100, alignment: .topLeading)
                    .background(Color.sheetInsetColor, in: RoundedRectangle(cornerRadius: innerDiameter / 2 + outerPadding - iconNegativePadding, style: .continuous))
            }
        }
    }

    @ViewBuilder
    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                SplitwiseAvatarView(url: avatarURL, diameter: innerDiameter, iconFont: iconFont, fallbackSymbol: avatarFallbackSymbol)
                    .padding(-iconNegativePadding)

                Spacer(minLength: 8)

                Text(balanceText)
                    .font(balanceFont)
                    .foregroundStyle(balanceColor)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .contentTransition(.numericText())
                    .animation(.default, value: balanceText)
            }

            Spacer(minLength: memberBalances.isEmpty ? 20 : 12)

            nameText

            if !visibleMemberBalances.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(visibleMemberBalances) { member in
                        HStack(spacing: 4) {
                            Text(member.name)
                                .lineLimit(1)
                            Spacer(minLength: 2)
                            Text(member.amountText)
                                .monospacedDigit()
                                .lineLimit(1)
                                // Dimmed rather than full strength: these are a
                                // breakdown, and shouldn't compete with the
                                // card's own balance above them.
                                .foregroundStyle(member.amountColor.opacity(0.65))
                        }
                    }
                    if hiddenMemberBalanceCount > 0 {
                        Text("+\(hiddenMemberBalanceCount) more")
                    }
                }
                .font(size == .large ? .caption : .caption2)
                .foregroundStyle(.secondary)
                .padding(.leading, size == .large ? 5 : 0)
                .padding(.top, 2)
            }

            if let lastRefreshedAt {
                FuzzyDateText(date: lastRefreshedAt)
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.leading, 5)
                    .padding(.top, 2)
            }
        }
    }

    /// The compact card has room for two lines beside everything else; the
    /// stretched-out one shows the whole group.
    private var memberBalanceLimit: Int { size == .large ? memberBalances.count : 2 }

    private var visibleMemberBalances: [MemberBalance] {
        Array(memberBalances.prefix(memberBalanceLimit))
    }

    private var hiddenMemberBalanceCount: Int {
        memberBalances.count - visibleMemberBalances.count
    }

    @ViewBuilder
    private var nameText: some View {
        switch size {
        case .large:
            Text(name)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.foregroundColor)
                .lineLimit(1)
                .padding(.leading, 5)
        case .compact:
            Text(name)
                .font(.headline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
    }
}

#Preview {
    List {
        Section {
            SplitwiseBalanceGrid(
                friend: SplitwiseFriend(id: 1, firstName: "Alex", lastName: nil, balance: [SplitwiseBalance(currencyCode: Const.currencyCode, amount: "12.34")], picture: nil),
                lastRefreshedAt: Date().addingTimeInterval(-320),
                onTap: {}
            )
        }
        .listRowBackground(Color.clear)
    }
}
