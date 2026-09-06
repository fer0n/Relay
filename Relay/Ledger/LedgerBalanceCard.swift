//
//  LedgerBalanceCard.swift
//  Relay
//
//  Pinned-list-style card (after Reminders' pinned smart lists), at the top of
//  ContentView and again per row on LedgersView. The headline figure is what
//  the signed-in user is up or down across the whole ledger; the lines below
//  are who inside it they're up or down with.
//

import CloudKit
import SwiftUI

extension Color {
    /// Positive means money is owed *to* whoever the figure describes.
    static func ledgerBalance(_ cents: Int) -> Color {
        cents > 0 ? Color.accentColor : .primary
    }
}

/// Decoded participant avatars, kept alive across view updates.
///
/// The JPEG lives in the ledger snapshot, so the only thing standing between
/// it and the screen is `UIImage(data:)` — and that ran inside `body`, which
/// meant a full decode per card per invalidation, on the main thread. Keyed
/// by the data itself so a changed picture can't be served from under the old
/// one, and bounded by `NSCache` so a ledger full of pictures can't pin them
/// all in memory.
enum AvatarImageCache {
    private static let cache: NSCache<NSData, UIImage> = {
        let cache = NSCache<NSData, UIImage>()
        cache.countLimit = 64
        return cache
    }()

    @MainActor
    static func image(for data: Data) -> UIImage? {
        let key = data as NSData
        if let cached = cache.object(forKey: key) { return cached }
        guard let image = UIImage(data: data) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}

/// Centres the single card in the full row width, so a second pinned card
/// could join it later without touching ContentView.
struct LedgerBalanceGrid: View {
    let ledger: Ledger
    let balances: LedgerBalances
    let currentUserID: String?
    /// Nil hides the "Last refreshed …" line.
    var lastRefreshedAt: Date?
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            LedgerBalanceCard(
                ledger: ledger,
                balances: balances,
                currentUserID: currentUserID,
                lastRefreshedAt: lastRefreshedAt
            )
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }
}

/// `maxWidth` defaults to what `LedgerBalanceGrid` centres on ContentView;
/// `LedgersView` passes `.infinity` to fill the row.
struct LedgerBalanceCard: View {
    struct MemberBalance: Identifiable {
        let id: String
        let name: String
        let amountText: String
        let amountColor: Color
    }

    let name: String
    let balanceText: String
    let balanceColor: Color
    let avatarFallbackSymbol: String
    /// The other person's picture, when there's exactly one of them: on a
    /// two-person ledger a face names the ledger faster than any symbol.
    let avatarImageData: Data?
    let memberBalances: [MemberBalance]
    var lastRefreshedAt: Date?
    var maxWidth: CGFloat? = 210

    /// Everything here is a lookup into `balances`, which `LedgerStore`
    /// derived when the expenses last changed — an init runs on every
    /// SwiftUI invalidation, so it can't afford to walk the expense list.
    init(
        ledger: Ledger,
        balances: LedgerBalances,
        currentUserID: String?,
        lastRefreshedAt: Date? = nil,
        maxWidth: CGFloat? = 210
    ) {
        let net = currentUserID.map { balances.net(for: $0) } ?? 0
        name = ledger.name
        balanceText = net.asMoney(ledger.currencyCode)
        balanceColor = .ledgerBalance(net)
        avatarFallbackSymbol = ledger.isShared ? Const.Symbol.friends : Const.Symbol.ledger
        avatarImageData = ledger.others.count == 1 ? ledger.others.first?.imageData : nil

        // Pairwise, not net: a net position mixes in what third parties owe
        // them, which says nothing about the reader. Which pairwise figure —
        // what the two of them ran up, or what the settle-up plan has them
        // paying — is the ledger's `simplifiesDebts` to say.
        memberBalances = currentUserID.map { me in
            ledger.others
                .map { participant in
                    (participant, balances.cents(me: me, other: participant.id, simplified: ledger.simplifiesDebts))
                }
                .filter { $0.1 != 0 }
                .sorted { abs($0.1) > abs($1.1) }
                .map { participant, cents in
                    MemberBalance(
                        id: participant.id,
                        name: participant.firstName,
                        amountText: cents.asMoney(ledger.currencyCode),
                        amountColor: .ledgerBalance(cents)
                    )
                }
        } ?? []

        self.lastRefreshedAt = lastRefreshedAt
        self.maxWidth = maxWidth
    }

    private let outerPadding: CGFloat = 15
    private let innerDiameter: CGFloat = 40

    private var cornerRadius: CGFloat { innerDiameter / 2 + outerPadding }

    var body: some View {
        cardContent
            .padding(outerPadding)
            .frame(maxWidth: maxWidth, minHeight: 100, alignment: .topLeading)
            .background(Color.sheetInsetColor, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    @ViewBuilder
    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                avatar

                Spacer(minLength: 8)

                Text(balanceText)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(balanceColor)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .contentTransition(.numericText())
                    .animation(.default, value: balanceText)
            }

            Spacer(minLength: memberBalances.isEmpty ? 20 : 12)

            nameText

            if !memberBalances.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(memberBalances) { member in
                        HStack(spacing: 4) {
                            Text(member.name)
                                .lineLimit(1)
                            Spacer(minLength: 2)
                            Text(member.amountText)
                                .monospacedDigit()
                                .lineLimit(1)
                                .foregroundStyle(member.amountColor.opacity(0.65))
                        }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 5)
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

    @ViewBuilder
    private var avatar: some View {
        if let avatarImageData, let image = AvatarImageCache.image(for: avatarImageData) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: innerDiameter, height: innerDiameter)
                .clipShape(.circle)
        } else {
            Image(systemName: avatarFallbackSymbol)
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: innerDiameter, height: innerDiameter)
                .background(Color.secondary.opacity(0.15), in: Circle())
        }
    }

    private var nameText: some View {
        Text(name)
            .font(.title3.weight(.semibold))
            .foregroundStyle(Color.foregroundColor)
            .lineLimit(1)
            .padding(.leading, 5)
    }
}

#Preview {
    let ledger = Ledger(
        zoneID: .init(zoneName: "Ledger-1", ownerName: "_owner"),
        name: "Flat",
        currencyCode: Const.currencyCode,
        createdAt: Date(),
        isOwnedByCurrentUser: true,
        participants: [
            LedgerParticipant(id: "me", name: "Me", isCurrentUser: true, hasAccepted: true, isOwner: true),
            LedgerParticipant(id: "alex", name: "Alex Kim", isCurrentUser: false, hasAccepted: true, isOwner: false),
        ]
    )
    List {
        Section {
            LedgerBalanceGrid(
                ledger: ledger,
                balances: LedgerBalances(expenses: [
                    LedgerExpense(
                        title: "Dinner",
                        costCents: 2468,
                        currencyCode: Const.currencyCode,
                        date: Date(),
                        shares: [
                            LedgerExpenseShare(participantID: "me", paidCents: 2468, owedCents: 1234),
                            LedgerExpenseShare(participantID: "alex", paidCents: 0, owedCents: 1234),
                        ]
                    ),
                ]),
                currentUserID: "me",
                lastRefreshedAt: Date().addingTimeInterval(-320),
                onTap: {}
            )
        }
        .listRowBackground(Color.clear)
    }
}
