//
//  LedgerMembersView.swift
//  Relay
//
//  Everyone on one ledger, and where who they are can be changed.
//
//  Every row is editable, not just your own: CloudKit reveals to each
//  participant only the names it's willing to (see `LedgerProfile`), so the
//  person showing as "Someone" is exactly the one who can't type their own
//  name in. Anyone filling in any name fixes it for everybody at once.
//

import PhotosUI
import SwiftUI

struct LedgerMembersView: View {
    let ledger: Ledger

    @State private var store = LedgerStore.shared
    @State private var editing: LedgerParticipant?
    @State private var shareTarget: LedgerShareTarget?
    @State private var isPreparingShare = false

    /// Re-read from the store: saving a profile changes this list underneath
    /// the value the screen was pushed with.
    private var current: Ledger {
        store.ledgers.first { $0.zoneName == ledger.zoneName } ?? ledger
    }

    var body: some View {
        List {
            Section {
                ForEach(current.participants) { participant in
                    Button {
                        editing = participant
                    } label: {
                        row(for: participant)
                    }
                }
            } footer: {
                Text("Names and pictures are stored on the ledger itself, so everyone on it sees the same ones. Anyone can fill in a name that's missing — iCloud only tells you the names of people you already share contacts with.")
                    .footerText()
            }
            .cardRowBackground()

            if current.isOwnedByCurrentUser {
                Section {
                    Button {
                        presentShare()
                    } label: {
                        Label(current.isShared ? "Manage Sharing" : "Invite", systemImage: "person.badge.plus")
                    }
                    .disabled(isPreparingShare)
                } footer: {
                    Text("Removing someone is done in iCloud's own sharing sheet — it's what controls who can open the ledger.")
                        .footerText()
                }
                .cardRowBackground()
            }
        }
        .themedList(background: .backgroundColor)
        .navigationTitle("Members")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.refresh(force: true) }
        .sheet(item: $editing) { participant in
            NavigationStack {
                LedgerProfileEditor(participant: participant, ledger: current)
            }
            .presentationBackground(Color.sheetBackgroundColor)
        }
        .sheet(item: $shareTarget) { target in
            LedgerShareSheet(target: target) {
                Task { await store.refresh(force: true) }
            }
        }
    }

    private func row(for participant: LedgerParticipant) -> some View {
        HStack(spacing: 12) {
            LedgerAvatar(participant: participant, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(participant.displayName)
                    .foregroundStyle(.primary)
                if let subtitle = subtitle(for: participant) {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
    }

    /// Whether they can see the ledger, and whether somebody chose the name.
    private func subtitle(for participant: LedgerParticipant) -> String? {
        if !participant.hasAccepted { return String(localized: "Hasn't accepted the invite yet") }
        if participant.isOwner && !participant.isCurrentUser { return String(localized: "Owner") }
        if !participant.hasProfile { return String(localized: "No name set") }
        return nil
    }

    private func presentShare() {
        guard !isPreparingShare else { return }
        isPreparingShare = true
        Task {
            defer { isPreparingShare = false }
            guard let (share, container) = try? await LedgerService.share(current) else { return }
            shareTarget = LedgerShareTarget(ledgerName: current.name, share: share, container: container)
        }
    }
}
