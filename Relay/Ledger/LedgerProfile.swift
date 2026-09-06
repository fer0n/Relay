//
//  LedgerProfile.swift
//  Relay
//
//  What someone calls themselves on a ledger, one record per person in the
//  ledger's zone. It exists because `CKShare.Participant.nameComponents` is
//  filled in only for people the reader may discover, asymmetrically — and
//  nobody can fix that from the side that's missing the name. A profile is
//  data in the shared zone instead, so anyone on the ledger can set anyone's.
//

import CloudKit
import Foundation

nonisolated struct LedgerProfile: Equatable, Hashable, Codable, Sendable {
    /// The participant's user record name, which is also the record's name.
    let participantID: String
    /// Nil when the record exists only to carry a picture.
    var displayName: String?
    /// JPEG, already downscaled to `maxImageDimension`.
    var imageData: Data?

    init(participantID: String, displayName: String? = nil, imageData: Data? = nil) {
        self.participantID = participantID
        self.displayName = displayName
        self.imageData = imageData
    }

    /// Sharp on the largest avatar drawn, small enough that every
    /// participant's picture rides along in memory and in the snapshot.
    static let maxImageDimension: CGFloat = 256
    static let imageQuality: CGFloat = 0.8
}
