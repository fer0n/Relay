//
//  OnboardingSplitwiseFriendPage.swift
//  Relay
//

import SwiftUI

/// Onboarding step shown after Splitwise is connected — lets the user pick
/// a default Splitwise friend up front so AddWalletTransactionToYNABIntent
/// doesn't have to ask live every time.
struct OnboardingSplitwiseFriendPage: View {
    let splitwiseAuth: SplitwiseAuthService
    /// True when the user has selected a friend (or no friends exist to pick from).
    @Binding var canContinue: Bool

    @State private var friends: [SplitwiseFriend] = []
    @State private var selectedFriend: SplitwiseDefaultFriend? = SplitwiseDefaultFriendStore.load()
    @State private var isLoading = false

    var body: some View {
        Group {
            if isLoading && friends.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if friends.isEmpty {
                ContentUnavailableView(
                    "No Friends Found",
                    systemImage: "person.2.slash",
                    description: Text("Add friends in Splitwise and they'll appear here.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 40)
            } else {
                List {
                    splitwiseFriendRows(friends) { friend in
                        friendRow(friend)
                    }
                }
                .themedList(background: .sheetBackgroundColor)
            }
        }
        .task(id: splitwiseAuth.accessToken) {
            if let cached = SplitwiseFriendCacheStore.load() {
                friends = SplitwiseFriendUsageStore.sorted(cached)
            }
            guard let token = splitwiseAuth.accessToken else { return }
            isLoading = true
            let fetched = (try? await SplitwiseFriendCacheStore.fetch(token: token)) ?? friends
            friends = SplitwiseFriendUsageStore.sorted(fetched)
            isLoading = false
            updateCanContinue()
        }
        .onChange(of: selectedFriend?.id) { updateCanContinue() }
        .onChange(of: friends.isEmpty) { updateCanContinue() }
    }

    @ViewBuilder
    private func friendRow(_ friend: SplitwiseFriend) -> some View {
        Button {
            select(friend)
        } label: {
            HStack {
                Text(friend.fullName)
                    .foregroundStyle(.primary)
                Spacer()
                if selectedFriend?.id == friend.id {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                        .fontWeight(.semibold)
                }
            }
        }
        .cardRowBackground()
    }

    private func select(_ friend: SplitwiseFriend) {
        let value = SplitwiseDefaultFriend(
            id: friend.id,
            firstName: friend.firstName,
            fullName: friend.fullName
        )
        selectedFriend = value
        try? SplitwiseDefaultFriendStore.save(value)
    }

    private func updateCanContinue() {
        canContinue = friends.isEmpty || selectedFriend != nil
    }
}

#Preview {
    OnboardingSplitwiseFriendPage(splitwiseAuth: SplitwiseAuthService(), canContinue: .constant(false))
}
