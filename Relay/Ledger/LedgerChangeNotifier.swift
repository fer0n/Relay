//
//  LedgerChangeNotifier.swift
//  Relay
//
//  CloudKit only knows "the shared database changed", so the subscription
//  asks for a silent push and this posts the local notification once the
//  change is fetched. Needs Push Notifications and the background mode;
//  without them ledgers stay refresh-on-open.
//

import CloudKit
import Foundation
import UserNotifications
import os

@MainActor
enum LedgerChangeNotifier {
    private static let logger = Logger(subsystem: Const.loggerSubsystem, category: "LedgerChangeNotifier")

    // Stable ids: CloudKit rejects the duplicate, which is what's wanted.
    private static let sharedSubscriptionID = "ledger-shared-changes"
    private static let privateSubscriptionID = "ledger-private-changes"

    static let categoryIdentifier = "LEDGER_EXPENSE_ADDED"

    /// Shared for ledgers others own, private for this user's own that
    /// someone else writes into.
    static func subscribeIfNeeded() async {
        guard (try? await LedgerService.accountStatus()) == .available else { return }
        let container = LedgerService.container
        await subscribe(id: privateSubscriptionID, in: container.privateCloudDatabase)
        await subscribe(id: sharedSubscriptionID, in: container.sharedCloudDatabase)

        // First run here: what's already there is history, not news.
        if LedgerSeenExpenseStore.load().isEmpty {
            await LedgerStore.shared.refresh(force: false)
            markEverythingSeen()
        }
    }

    /// Not at launch: a prompt with no context behind it gets denied for good.
    static func requestAuthorizationIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        guard await center.notificationSettings().authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    private static func subscribe(id: String, in database: CKDatabase) async {
        let subscription = CKDatabaseSubscription(subscriptionID: id)
        let info = CKSubscription.NotificationInfo()
        // Silent: the payload wakes the app; the banner comes later.
        info.shouldSendContentAvailable = true
        subscription.notificationInfo = info
        do {
            _ = try await database.modifySubscriptions(saving: [subscription], deleting: [])
        } catch let error as CKError where error.code == .serverRejectedRequest {
            // Already subscribed — expected after the first launch.
        } catch {
            logger.error("Ledger subscription failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Announces what other people added since last time. Returns whether
    /// anything changed, for the background-fetch result.
    static func handleRemoteNotification() async -> Bool {
        let store = LedgerStore.shared
        let before = LedgerSeenExpenseStore.load()
        // A deleted expense is gone from CloudKit; only the local copy knows.
        let previous = expensesByID(in: store)
        await store.refresh(force: true)

        // Nothing recorded yet: seed rather than announce.
        guard !before.isEmpty else {
            LedgerSeenExpenseStore.save(currentExpenseIDs(in: store))
            return false
        }

        let containerUserID = store.currentUserID
        var announced = 0
        for ledger in store.ledgers {
            // `createdBy` is container-level; the ledger's own id can differ.
            let mine = Set([containerUserID, ledger.currentUserID].compactMap { $0 })
            for expense in store.expenses(in: ledger) where !before.contains(expense.id) {
                // Only other people's writes.
                guard let createdBy = expense.createdBy, !mine.contains(createdBy) else { continue }
                await notify(expense: expense, in: ledger, currentUserID: ledger.currentUserID ?? containerUserID ?? "")
                announced += 1
            }
        }

        announced += await announceDeletions(previous: previous, seen: before, in: store)
        LedgerSeenExpenseStore.save(currentExpenseIDs(in: store))
        return announced > 0
    }

    /// Expenses gone since last time — only already-announced ones, and only
    /// on ledgers that still exist, since leaving one removes them all at once.
    /// Nobody is named: a deletion arrives as a bare record id.
    private static func announceDeletions(
        previous: [String: (expense: LedgerExpense, zoneName: String)],
        seen: Set<String>,
        in store: LedgerStore
    ) async -> Int {
        let liveZones = Set(store.ledgers.map(\.zoneName))
        let current = currentExpenseIDs(in: store)
        var announced = 0
        for (id, entry) in previous where !current.contains(id) && seen.contains(id) {
            guard liveZones.contains(entry.zoneName),
                  let ledger = store.ledgers.first(where: { $0.zoneName == entry.zoneName }) else { continue }
            await notifyDeleted(expense: entry.expense, in: ledger)
            announced += 1
        }
        return announced
    }

    /// Seeds the "already seen" set without announcing anything.
    static func markEverythingSeen() {
        LedgerSeenExpenseStore.save(currentExpenseIDs(in: LedgerStore.shared))
    }

    /// What a deletion is looked up in: the feed reports only a record id.
    private static func expensesByID(in store: LedgerStore) -> [String: (expense: LedgerExpense, zoneName: String)] {
        var result: [String: (expense: LedgerExpense, zoneName: String)] = [:]
        for ledger in store.ledgers {
            for expense in store.expenses(in: ledger) {
                result[expense.id] = (expense, ledger.zoneName)
            }
        }
        return result
    }

    /// Saving the *old* set instead would re-announce on every later push.
    private static func currentExpenseIDs(in store: LedgerStore) -> Set<String> {
        Set(store.ledgers.flatMap { store.expenses(in: $0).map(\.id) })
    }

    /// What it cost, then who owes what. The ledger's name isn't the title:
    /// it's the same every time, and the split already says which ledger.
    private static func notify(expense: LedgerExpense, in ledger: Ledger, currentUserID: String) async {
        let who = expense.createdBy.flatMap { ledger.participant(id: $0)?.firstName }
            ?? LedgerParticipant.unknownName
        let amount = amountText(expense.costCents, currencyCode: expense.currencyCode)

        guard !expense.isSettlement else {
            // A payment has no split to break down, so there's room for the
            // ledger's name instead.
            let recipient = expense.debtors.first.flatMap { ledger.participant(id: $0.participantID) }
            await post(
                title: recipient?.isCurrentUser == true
                    ? String(localized: "\(who) paid you \(amount)")
                    : String(localized: "\(who) recorded a \(amount) payment"),
                body: ledger.name,
                expenseID: expense.id
            )
            return
        }
        await post(
            title: expense.title.isEmpty ? amount : String(localized: "\(amount) at \(expense.title)"),
            body: splitSummary(of: expense, in: ledger, currentUserID: currentUserID),
            expenseID: expense.id
        )
    }

    /// Reuses the add's identifier, so a still-sitting banner is replaced
    /// rather than contradicted.
    private static func notifyDeleted(expense: LedgerExpense, in ledger: Ledger) async {
        let amount = amountText(expense.costCents, currencyCode: expense.currencyCode)
        await post(
            title: expense.title.isEmpty
                ? String(localized: "Deleted: \(amount)")
                : String(localized: "Deleted: \(amount) at \(expense.title)"),
            body: ledger.name,
            expenseID: expense.id
        )
    }

    /// Keyed by expense, so the same write arriving twice replaces itself.
    private static func post(title: String, body: String, expenseID: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = categoryIdentifier
        // The haptic rides on the sound; without it there's no vibration.
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "ledger-expense-\(expenseID)",
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    /// "You: 1,50 € • Michaela: 1,50 €", reader first then largest. Debtors
    /// only, or a payer at zero pushes the real shares off the line.
    static func splitSummary(
        of expense: LedgerExpense,
        in ledger: Ledger,
        currentUserID: String
    ) -> String {
        expense.debtors
            .sorted { lhs, rhs in
                if (lhs.participantID == currentUserID) != (rhs.participantID == currentUserID) {
                    return lhs.participantID == currentUserID
                }
                return lhs.owedCents > rhs.owedCents
            }
            .map { share in
                let name = ledger.participant(id: share.participantID)?.shortName
                    ?? LedgerParticipant.unknownName
                return "\(name): \(amountText(share.owedCents, currencyCode: expense.currencyCode))"
            }
            .joined(separator: " • ")
    }

    /// Without the ",00" on a whole amount, which makes the line unreadable.
    private static func amountText(_ cents: Int, currencyCode: String) -> String {
        (Double(cents) / Const.centsPerUnit)
            .formatted(.currency(code: currencyCode).precision(.fractionLength(0...2)))
    }
}

/// On disk: it has to survive being killed between two silent pushes.
nonisolated enum LedgerSeenExpenseStore {
    private static let fileURL = ApplicationSupportFile.url("ledger-seen-expenses.json")

    static func load() -> Set<String> {
        guard let data = try? Data(contentsOf: fileURL),
              let ids = try? JSONDecoder().decode(Set<String>.self, from: data) else { return [] }
        return ids
    }

    static func save(_ ids: Set<String>) {
        guard let data = try? JSONEncoder().encode(ids) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
