//
//  LedgerShareSheet.swift
//  Relay
//
//  Apple's share sheet is the ledger's entire invite flow.
//  `UICloudSharingController` is UIKit-only, hence this wrapper.
//
//  Presented from a `.sheet` rather than pushed: it manages its own dismissal,
//  and as a navigation destination it fights the stack over who pops.
//

import CloudKit
import SwiftUI
import UIKit

/// Share and container as one value, so `.sheet(item:)` can't be triggered
/// with only half of what the controller needs.
nonisolated struct LedgerShareTarget: Identifiable {
    let ledgerName: String
    let share: CKShare
    let container: CKContainer

    var id: String { share.recordID.recordName + share.recordID.zoneID.zoneName }
}

struct LedgerShareSheet: UIViewControllerRepresentable {
    let target: LedgerShareTarget
    /// Fired after the sheet changes the share.
    var onChange: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(target: target, onChange: onChange) }

    func makeUIViewController(context: Context) -> UICloudSharingController {
        let controller = UICloudSharingController(share: target.share, container: target.container)
        // No read-only option: a ledger everyone can see but only one person can
        // add to isn't a shared expense list, it's a report.
        controller.availablePermissions = [.allowReadWrite, .allowPrivate]
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: UICloudSharingController, context: Context) {}

    final class Coordinator: NSObject, UICloudSharingControllerDelegate {
        private let target: LedgerShareTarget
        private let onChange: () -> Void

        init(target: LedgerShareTarget, onChange: @escaping () -> Void) {
            self.target = target
            self.onChange = onChange
        }

        func itemTitle(for controller: UICloudSharingController) -> String? {
            target.ledgerName
        }

        /// Without this the sheet shows a document icon, which reads as
        /// sending a file rather than inviting someone to a list.
        func itemThumbnailData(for controller: UICloudSharingController) -> Data? {
            Self.thumbnail
        }

        /// Nil rather than a plausible UTI: a ledger is not a document.
        func itemType(for controller: UICloudSharingController) -> String? {
            nil
        }

        /// The invite is the first thing the other person sees of Relay.
        private static let thumbnail: Data? = {
            let size = CGSize(width: 180, height: 180)
            let renderer = UIGraphicsImageRenderer(size: size)
            let image = renderer.image { context in
                UIColor(named: "AccentColor")?.setFill()
                context.fill(CGRect(origin: .zero, size: size))
                guard let logo = UIImage(named: "Logo") else { return }
                let inset = size.width * 0.22
                logo.withTintColor(.white, renderingMode: .alwaysOriginal)
                    .draw(in: CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset))
            }
            return image.pngData()
        }()

        func cloudSharingControllerDidSaveShare(_ controller: UICloudSharingController) {
            onChange()
        }

        func cloudSharingControllerDidStopSharing(_ controller: UICloudSharingController) {
            onChange()
        }

        /// Required, and a failed save may still have changed the share.
        func cloudSharingController(_ controller: UICloudSharingController, failedToSaveShareWithError error: Error) {
            onChange()
        }
    }
}
