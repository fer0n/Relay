//
//  LedgerProfile.swift
//  Relay
//
//  Names and pictures as data in the shared zone, so anyone on the ledger can
//  set anyone's. `CKShare.Participant.nameComponents` is filled in only
//  asymmetrically, and can't be fixed from the side that's missing the name.
//

import CloudKit
import Foundation

nonisolated struct LedgerProfile: Equatable, Hashable, Codable, Sendable {
    /// Also the record's name.
    let participantID: String
    /// Nil when the record exists only to carry a picture.
    var displayName: String?
    /// JPEG, downscaled to `maxImageDimension`.
    var imageData: Data?

    init(participantID: String, displayName: String? = nil, imageData: Data? = nil) {
        self.participantID = participantID
        self.displayName = displayName
        self.imageData = imageData
    }

    /// Every participant's picture rides along in memory and in the snapshot.
    static let maxImageDimension: CGFloat = 256
    static let imageQuality: CGFloat = 0.8
}
