//
//  LedgerProfileEditor.swift
//  Relay
//
//  Name and picture for one person, plus the avatar used everywhere else.
//

import PhotosUI
import SwiftUI

struct LedgerAvatar: View {
    let participant: LedgerParticipant
    var size: CGFloat = 36

    var body: some View {
        Group {
            if let imageData = participant.imageData, let image = AvatarImageCache.image(for: imageData) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Text(participant.initials)
                    .font(.system(size: size * 0.4, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.accentColor.opacity(0.15))
            }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
    }
}

struct LedgerProfileEditor: View {
    let participant: LedgerParticipant
    let ledger: Ledger

    @State private var store = LedgerStore.shared
    @State private var name: String
    @State private var imageData: Data?
    @State private var pickedItem: PhotosPickerItem?
    @State private var isSaving = false
    @Environment(\.dismiss) private var dismiss

    init(participant: LedgerParticipant, ledger: Ledger) {
        self.participant = participant
        self.ledger = ledger
        // CloudKit's name included, so saving a picture alone doesn't blank it.
        _name = State(initialValue: participant.name ?? "")
        _imageData = State(initialValue: participant.imageData)
    }

    var body: some View {
        List {
            Section {
                HStack {
                    Spacer()
                    VStack(spacing: 12) {
                        LedgerAvatar(
                            participant: preview,
                            size: 88
                        )
                        let hasPhoto = imageData != nil
                        PhotosPicker(selection: $pickedItem, matching: .images, photoLibrary: .shared()) {
                            Text(hasPhoto ? "Change Photo" : "Add Photo")
                                .font(.subheadline)
                        }
                        if imageData != nil {
                            Button("Remove Photo", role: .destructive) {
                                imageData = nil
                                pickedItem = nil
                            }
                            .font(.subheadline)
                        }
                    }
                    Spacer()
                }
            }
            .listRowSeparator(.hidden)
            .listRowBackground(Color.backgroundColor)

            Section {
                TextField("Name", text: $name)
                    .textContentType(.name)
                    .autocorrectionDisabled()
            } footer: {
                Text(participant.isCurrentUser
                     ? "This is how you'll appear to everyone else on this ledger."
                     : "Everyone on the ledger sees this name.")
                    .footerText()
            }
            .cardRowBackground()
        }
        .themedList(background: .sheetBackgroundColor)
        .navigationTitle(participant.isCurrentUser ? String(localized: "You") : participant.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .disabled(isSaving)
            }
        }
        .onChange(of: pickedItem) { _, item in
            guard let item else { return }
            Task { imageData = await Self.profileImageData(from: item) }
        }
    }

    /// As they'd look once saved, so the circle tracks both fields.
    private var preview: LedgerParticipant {
        LedgerParticipant(
            id: participant.id,
            name: name.isEmpty ? participant.name : name,
            isCurrentUser: participant.isCurrentUser,
            hasAccepted: participant.hasAccepted,
            isOwner: participant.isOwner,
            imageData: imageData,
            hasProfile: participant.hasProfile
        )
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            defer { isSaving = false }
            let saved = await store.saveProfile(
                LedgerProfile(
                    participantID: participant.id,
                    displayName: trimmed.isEmpty ? nil : trimmed,
                    imageData: imageData
                ),
                in: ledger
            )
            if saved { dismiss() }
        }
    }

    /// Downscaled: every participant's picture is held in memory and written
    /// into the snapshot.
    nonisolated private static func profileImageData(from item: PhotosPickerItem) async -> Data? {
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else { return nil }
        let side = LedgerProfile.maxImageDimension
        let scale = min(1, side / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return resized.jpegData(compressionQuality: LedgerProfile.imageQuality)
    }
}
