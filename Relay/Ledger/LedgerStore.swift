//
//  LedgerStore.swift
//  Relay
//
//  The app's single view of its ledgers, and the one place that talks to
//  `LedgerService`. Adds a shared observable snapshot, so the list and a
//  detail screen can't drift apart, plus a copy on disk purely so the first
//  frame after launch has something to draw.
//

import CloudKit
import Foundation
import Observation
import os
import SwiftUI

/// What became of a write. `.queued` is a success from the user's side: the
/// expense is on the ledger on this device and `PendingOperationQueue` owns
/// getting it to CloudKit.
nonisolated enum LedgerWriteOutcome {
    case saved
    case queued
    case failed
}

/// What a write should leave in "Recent" — passed only by the callers whose
/// writes record history when they succeed online, so a queued one records
/// the same thing and nothing more when it eventually syncs.
nonisolated struct LedgerWriteHistory {
    let summary: String
    var groupId: UUID?
    var merchant: String?

    init(summary: String, groupId: UUID? = nil, merchant: String? = nil) {
        self.summary = summary
        self.groupId = groupId
        self.merchant = merchant
    }
}

@MainActor
@Observable
final class LedgerStore {
    static let shared = LedgerStore()

    private(set) var ledgers: [Ledger] = []
    /// Keyed by zone name, which survives an owner-name difference between
    /// the private and shared database views of a zone.
    private(set) var expenses: [String: [LedgerExpense]] = [:]
    /// Derived from `expenses` and kept in step with it by `setExpenses`,
    /// never assigned from outside: the balance card and the settle-up plan
    /// are read from a view body, and deriving them there re-walked every
    /// expense on every invalidation.
    private(set) var balances: [String: LedgerBalances] = [:]
    private(set) var currentUserID: String?
    private(set) var accountStatus: CKAccountStatus = .couldNotDetermine
    private(set) var isRefreshing = false
    /// Cleared by the next successful refresh.
    private(set) var lastError: String?

    private(set) var lastRefreshedAt: Date?
    private let logger = Logger(subsystem: Const.loggerSubsystem, category: "LedgerStore")
    private let cache = FileCache<LedgerSnapshot>(fileName: "ledgers.json")
    private var hasRefreshedThisLaunch = false

    private init() {
        guard let snapshot = cache.load() else { return }
        ledgers = snapshot.ledgers.map(\.ledger)
        setExpenses(snapshot.expenses)
        currentUserID = snapshot.currentUserID
        lastRefreshedAt = cache.lastFetchedAt
        // Nothing is cached until a refresh confirmed the account, so the
        // last thing known is that it was there. `.couldNotDetermine` would
        // flash "iCloud Unavailable" on every launch.
        accountStatus = .available
    }

    var isAvailable: Bool { accountStatus == .available }

    func expenses(in ledger: Ledger) -> [LedgerExpense] {
        expenses[ledger.zoneName] ?? []
    }

    func balances(in ledger: Ledger) -> LedgerBalances {
        balances[ledger.zoneName] ?? .empty
    }

    /// The only way `expenses` changes, so a balance can't go stale behind
    /// it. Deriving costs one walk per changed zone, against the many a
    /// view body would do.
    private func setExpenses(_ updated: [String: [LedgerExpense]]) {
        expenses = updated
        balances = updated.mapValues(LedgerBalances.init(expenses:))
    }

    /// Nil removes the zone, for a ledger that's just been deleted or left.
    private func setExpenses(_ updated: [LedgerExpense]?, inZone zoneName: String) {
        expenses[zoneName] = updated
        balances[zoneName] = updated.map(LedgerBalances.init(expenses:))
    }

    /// One nobody else is on has nobody to bill.
    var sharedLedgers: [Ledger] { ledgers.filter(\.isShared) }

    /// A server fetch can't see an expense that never reached the server, so
    /// anything still in the pending queue is folded back in — otherwise an
    /// offline add would disappear on the next refresh and reappear when it
    /// synced. Only zones that came back are touched: a queued expense for a
    /// ledger this device has lost access to stays gone.
    private func mergingQueued(_ fetched: [String: [LedgerExpense]]) -> [String: [LedgerExpense]] {
        var merged = fetched
        for zoneName in fetched.keys {
            merged[zoneName] = mergingQueued(fetched[zoneName] ?? [], inZone: zoneName)
        }
        return merged
    }

    private func mergingQueued(_ fetched: [LedgerExpense], inZone zoneName: String) -> [LedgerExpense] {
        let queued = PendingOperationQueue.shared.pendingLedgerExpenses
            .filter { $0.zoneName == zoneName }
        guard !queued.isEmpty else { return fetched }
        // A queued *edit* to an expense that's already on the server wins:
        // it's the newer of the two, and it's what the screen has been
        // showing since the edit was made.
        let queuedIDs = Set(queued.map(\.expenseID))
        return (fetched.filter { !queuedIDs.contains($0.id) } + queued.map(\.asExpense))
            .sorted { $0.date > $1.date }
    }

    private func persistSnapshot() {
        cache.save(LedgerSnapshot(ledgers: ledgers, expenses: expenses, currentUserID: currentUserID))
    }

    /// `force` is false for an appear/foreground pass, true for
    /// pull-to-refresh.
    func refresh(force: Bool) async {
        // `hasRefreshedThisLaunch` because the restored snapshot carries its
        // own fetch timestamp: the cache fills the first frame, it doesn't
        // stand in for a sync.
        guard force || !hasRefreshedThisLaunch || CacheStore.isStale(lastRefreshedAt) else { return }
        guard !isRefreshing else { return }
        isRefreshing = true
        hasRefreshedThisLaunch = true
        defer { isRefreshing = false }

        do {
            accountStatus = try await LedgerService.accountStatus()
            guard accountStatus == .available else {
                // Not an error: signing out is a choice, and the views have
                // an empty state for it. The cache goes too — a signed-out
                // device shouldn't draw a ledger it lost access to.
                ledgers = []
                setExpenses([:])
                cache.delete()
                lastError = nil
                return
            }
            currentUserID = try await LedgerService.currentUserID()
            var fetched = try await LedgerService.fetchLedgers()
            // One zone walk per ledger, in parallel; accumulated rather than
            // assigned zone by zone, which would animate the list rebuilding
            // itself one ledger at a time.
            let userID = currentUserID
            let contents = try await withThrowingTaskGroup(
                of: (String, [LedgerExpense], [String: LedgerProfile]).self
            ) { group in
                for ledger in fetched {
                    group.addTask {
                        let contents = try await LedgerService.fetchContents(in: ledger, currentUserID: userID)
                        return (ledger.zoneName, contents.expenses, contents.profiles)
                    }
                }
                var byZone: [String: ([LedgerExpense], [String: LedgerProfile])] = [:]
                for try await (zoneName, expenses, profiles) in group {
                    byZone[zoneName] = (expenses, profiles)
                }
                return byZone
            }
            var fetchedExpenses: [String: [LedgerExpense]] = [:]
            for index in fetched.indices {
                guard let (expenses, profiles) = contents[fetched[index].zoneName] else { continue }
                fetchedExpenses[fetched[index].zoneName] = expenses
                fetched[index] = fetched[index].applyingProfiles(profiles)
            }
            // Animated: an expense someone else added arrives here rather
            // than through a local write. Assigned only after a successful
            // pass, so a failed refresh doesn't empty a live screen.
            withAnimation {
                ledgers = fetched
                setExpenses(mergingQueued(fetchedExpenses))
            }
            SplitAvailability.recordHasSharedLedger(fetched.contains(where: \.isShared))
            persistSnapshot()
            lastError = nil
            lastRefreshedAt = Date()
        } catch {
            logger.error("Ledger refresh failed: \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
        }
    }

    func refreshExpenses(in ledger: Ledger) async {
        do {
            let contents = try await LedgerService.fetchContents(in: ledger, currentUserID: currentUserID)
            withAnimation {
                setExpenses(mergingQueued(contents.expenses, inZone: ledger.zoneName), inZone: ledger.zoneName)
                if let index = ledgers.firstIndex(where: { $0.zoneName == ledger.zoneName }) {
                    ledgers[index] = ledgers[index].applyingProfiles(contents.profiles)
                }
            }
            lastError = nil
        } catch {
            logger.error("Ledger expense refresh failed: \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
        }
    }

    @discardableResult
    func createLedger(name: String, currencyCode: String = Const.currencyCode) async -> Ledger? {
        do {
            let ledger = try await LedgerService.createLedger(name: name, currencyCode: currencyCode)
            ledgers.append(ledger)
            setExpenses([], inZone: ledger.zoneName)
            lastError = nil
            return ledger
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    /// Optimistic, like every other edit here: the new name is on screen
    /// before the round trip, and put back if the write fails.
    @discardableResult
    func rename(_ ledger: Ledger, to name: String) async -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ledger.name else { return false }
        guard let index = ledgers.firstIndex(where: { $0.zoneName == ledger.zoneName }) else { return false }
        let previous = ledgers[index]
        withAnimation { ledgers[index].name = trimmed }
        do {
            try await LedgerService.rename(ledger, to: trimmed)
            persistSnapshot()
            lastError = nil
            return true
        } catch {
            restore(previous)
            lastError = error.localizedDescription
            return false
        }
    }

    /// Optimistic like `rename`, and worth being so: the balances on screen
    /// redraw under the toggle rather than after the round trip.
    @discardableResult
    func setSimplifiesDebts(_ simplifies: Bool, in ledger: Ledger) async -> Bool {
        guard let index = ledgers.firstIndex(where: { $0.zoneName == ledger.zoneName }),
              ledgers[index].simplifiesDebts != simplifies else { return false }
        let previous = ledgers[index]
        withAnimation { ledgers[index].simplifiesDebts = simplifies }
        do {
            try await LedgerService.setSimplifiesDebts(simplifies, in: ledger)
            persistSnapshot()
            lastError = nil
            return true
        } catch {
            restore(previous)
            lastError = error.localizedDescription
            return false
        }
    }

    /// Puts one ledger back the way it was, found by zone rather than by the
    /// index it had before the write: a refresh landing mid-flight can drop a
    /// ledger someone deleted elsewhere, and the stale index then points past
    /// the end of the list — or at somebody else's ledger.
    private func restore(_ ledger: Ledger) {
        guard let index = ledgers.firstIndex(where: { $0.zoneName == ledger.zoneName }) else { return }
        withAnimation { ledgers[index] = ledger }
    }

    /// Optimistic: a CloudKit round-trip is slow enough that waiting for it
    /// before showing the row is noticeable.
    ///
    /// Offline the optimistic row *stays* and the write goes to
    /// `PendingOperationQueue` — CloudKit doesn't hold an unsent
    /// `modifyRecords` anywhere, it fails the call outright, and rolling back
    /// would mean an expense simply can't be added away from a network. Every
    /// other failure still rolls back: a rejected write won't start working.
    @discardableResult
    func save(
        _ expense: LedgerExpense,
        in ledger: Ledger,
        history: LedgerWriteHistory? = nil
    ) async -> LedgerWriteOutcome {
        let key = ledger.zoneName
        let previous = expenses[key] ?? []
        var updated = previous.filter { $0.id != expense.id }
        updated.append(expense)
        withAnimation { setExpenses(updated.sorted { $0.date > $1.date }, inZone: key) }
        do {
            try await LedgerService.save(expense, in: ledger)
            // An edit that reached CloudKit makes the queued copy of the same
            // expense a stale write waiting to undo it.
            PendingOperationQueue.shared.cancelLedgerExpense(id: expense.id)
            lastError = nil
            return .saved
        } catch let error where error.isConnectivityFailure {
            PendingOperationQueue.shared.enqueue(
                .ledgerExpense(LedgerExpenseRequest(expense: expense, ledger: ledger)),
                summary: history?.summary ?? queueSummary(for: expense, in: ledger),
                groupId: history?.groupId,
                merchant: history?.merchant,
                recordsHistory: history != nil
            )
            persistSnapshot()
            lastError = nil
            return .queued
        } catch {
            withAnimation { setExpenses(previous, inZone: key) }
            lastError = error.localizedDescription
            return .failed
        }
    }

    /// The pending row's own wording, for a write whose caller doesn't record
    /// history — a settlement, an edit.
    private func queueSummary(for expense: LedgerExpense, in ledger: Ledger) -> String {
        let amount = (Double(expense.costCents) / Const.centsPerUnit).asMoneyString
        let title = expense.title.isEmpty ? String(localized: "Expense") : expense.title
        return "\(amount) for \(title) on \(ledger.name)"
    }

    /// Takes a queued expense back off the ledger — the user deleted its
    /// pending operation, so the write it was standing in for is never
    /// happening.
    func discardQueued(expenseID: String, zoneName: String) {
        guard let current = expenses[zoneName] else { return }
        withAnimation { setExpenses(current.filter { $0.id != expenseID }, inZone: zoneName) }
        persistSnapshot()
    }

    func delete(_ expense: LedgerExpense, in ledger: Ledger) async {
        let key = ledger.zoneName
        let previous = expenses[key] ?? []
        withAnimation { setExpenses(previous.filter { $0.id != expense.id }, inZone: key) }
        // Nothing was ever written, so dropping the queued write *is* the
        // deletion — and going to CloudKit for it would fail offline, which
        // is exactly where a pending expense gets deleted.
        if PendingOperationQueue.shared.isPending(expenseID: expense.id) {
            PendingOperationQueue.shared.cancelLedgerExpense(id: expense.id)
            persistSnapshot()
            lastError = nil
            return
        }
        do {
            try await LedgerService.delete(expense, in: ledger)
            lastError = nil
        } catch {
            withAnimation { setExpenses(previous, inZone: key) }
            lastError = error.localizedDescription
        }
    }

    /// Deletes when the user owns it, leaves when someone else does.
    func remove(_ ledger: Ledger) async {
        do {
            if ledger.isOwnedByCurrentUser {
                try await LedgerService.deleteLedger(ledger)
            } else {
                try await LedgerService.leave(ledger)
            }
            withAnimation { ledgers.removeAll { $0.zoneID == ledger.zoneID } }
            setExpenses(nil, inZone: ledger.zoneName)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Optimistic: the person editing is looking straight at the row.
    func saveProfile(_ profile: LedgerProfile, in ledger: Ledger) async -> Bool {
        guard let index = ledgers.firstIndex(where: { $0.zoneName == ledger.zoneName }) else { return false }
        let previous = ledgers[index]
        ledgers[index] = previous.applyingProfiles([profile.participantID: profile])
        do {
            try await LedgerService.saveProfile(profile, in: ledger)
            lastError = nil
            return true
        } catch {
            restore(previous)
            lastError = error.localizedDescription
            return false
        }
    }

    /// An accepted share arrives outside any refresh cycle.
    func reloadAfterAcceptingShare() async {
        await refresh(force: true)
    }
}
