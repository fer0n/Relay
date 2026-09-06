//
//  LedgerShareSheet.swift
//  Relay
//
//  Apple's share sheet is the whole invite flow. Presented from a `.sheet`,
//  not pushed: it manages its own dismissal and fights the stack over popping.
//

import CloudKit
import SwiftUI
import UIKit

/// One value, so `.sheet(item:)` can't fire with half of what's needed.
nonisolated struct LedgerShareTarget: Identifiable {
    let ledgerName: String
    let share: CKShare
    let container: CKContainer

    var id: String { share.recordID.recordName + share.recordID.zoneID.zoneName }
}

/// The flag stops a double tap starting two round trips.
@MainActor
@Observable
final class LedgerSharePresenter {
    var target: LedgerShareTarget?
    private(set) var isPreparing = false

    func present(_ ledger: Ledger) {
        guard !isPreparing else { return }
        isPreparing = true
        Task {
            defer { isPreparing = false }
            guard let (share, container) = try? await LedgerService.share(ledger) else { return }
            target = LedgerShareTarget(ledgerName: ledger.name, share: share, container: container)
        }
    }
}

struct LedgerShareSheet: UIViewControllerRepresentable {
    let target: LedgerShareTarget
    /// Fired after the sheet changes the share.
    var onChange: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(target: target, onChange: onChange) }

    func makeUIViewController(context: Context) -> UICloudSharingController {
        let controller = UICloudSharingController(share: target.share, container: target.container)
        // No read-only: a list only one person can add to is a report.
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

        /// Otherwise the sheet shows a document icon, which reads as sending
        /// a file rather than inviting someone.
        func itemThumbnailData(for controller: UICloudSharingController) -> Data? {
            Self.thumbnail
        }

        /// A ledger is not a document.
        func itemType(for controller: UICloudSharingController) -> String? {
            nil
        }

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
