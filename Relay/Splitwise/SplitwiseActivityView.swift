//
//  SplitwiseActivityView.swift
//  Relay
//
//  The `get_notifications` feed, i.e. the same list the Splitwise app shows under
//  "Activity". Read-only apart from one action: a "deleted expense" entry offers
//  "Restore", which is the only place in Relay a deleted expense can be brought
//  back — the friend transaction lists filter them out entirely.
//

import SwiftUI

struct SplitwiseActivityView: View {
    @State private var items = SplitwiseActivityItem.items(for: SplitwiseNotificationCacheStore.load() ?? [])
    @State private var lastRefreshedAt = SplitwiseNotificationCacheStore.lastFetchedAt
    @State private var loadError: String?
    @State private var restoreError: String?
    /// Which expenses have a `undelete_expense` call in flight, so reopening
    /// the context menu mid-restore can't fire a second one.
    @State private var restoringExpenseIds: Set<Int> = []

    var body: some View {
        List {
            if items.isEmpty, let loadError {
                Text(loadError)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .cardRowBackground()
            }

            ForEach(items) { item in
                // Attached only where there's an action, rather than as one modifier
                // with a conditional body: an empty menu still lifts the row on
                // long-press, which reads as a broken control.
                if let expenseId = item.restorableExpenseId {
                    SplitwiseActivityRow(item: item)
                        .cardRowBackground()
                        .transition(.contentRow)
                        .contextMenu {
                            Button {
                                Task { await restore(expenseId: expenseId) }
                            } label: {
                                Label("Restore", systemImage: "arrow.uturn.backward")
                            }
                            .disabled(restoringExpenseIds.contains(expenseId))
                        }
                } else {
                    SplitwiseActivityRow(item: item)
                        .cardRowBackground()
                        .transition(.contentRow)
                }
            }

            // A plain centered row rather than a Section footer, which would need a
            // section to hang off — and the rows above aren't wrapped in one.
            if let lastRefreshedAt {
                Section {
                    FuzzyDateText(date: lastRefreshedAt)
                        .footerText()
                        .frame(maxWidth: .infinity)
                }
                .listRowSeparator(.hidden)
                .listRowBackground(Color.backgroundColor)
            }
        }
        .themedListStyle()
        .background {
            Color.backgroundColor
            if items.isEmpty {
                EmptyListBackground(systemName: "bell")
            }
        }
        .navigationTitle("Activity")
        .refreshable { await load(force: true) }
        .task { await load(force: false) }
        .alert("Couldn't Restore", isPresented: .init(get: { restoreError != nil }, set: { if !$0 { restoreError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            if let restoreError {
                Text(restoreError)
            }
        }
    }

    private func load(force: Bool) async {
        guard let token = SplitwiseAuthService.currentAccessToken else {
            loadError = "Not connected to Splitwise."
            return
        }
        guard force || SplitwiseNotificationCacheStore.isStale else { return }
        do {
            let fetched = SplitwiseActivityItem.items(for: try await SplitwiseNotificationCacheStore.fetch(token: token))
            withAnimation { items = fetched }
            lastRefreshedAt = SplitwiseNotificationCacheStore.lastFetchedAt
            loadError = nil
        } catch {
            loadError = "Couldn't load activity."
        }
    }

    /// Re-fetches the feed afterwards so the "restored" entry appears and this row
    /// stops offering "Restore". Clears every friend's expense cache, not just
    /// one: the feed knows the expense id but not whose history it belongs to.
    private func restore(expenseId: Int) async {
        guard !restoringExpenseIds.contains(expenseId) else { return }
        guard let token = SplitwiseAuthService.currentAccessToken else {
            restoreError = "Not connected to Splitwise."
            return
        }
        restoringExpenseIds.insert(expenseId)
        defer { restoringExpenseIds.remove(expenseId) }
        do {
            try await SplitwiseService.undeleteExpense(id: expenseId, token: token)
        } catch SplitwiseAPIError.validation(let message) {
            restoreError = message
            return
        } catch {
            restoreError = "Please check your connection and try again."
            return
        }
        SplitwiseExpenseCacheStore.invalidateAll()
        _ = try? await SplitwiseFriendCacheStore.fetch(token: token)
        await load(force: true)
    }
}

/// A feed entry with its HTML already parsed and its icon resolved — a separate
/// type from `SplitwiseNotification` so neither happens inside a view body, where
/// it would re-scan the HTML for all 50 rows on every pass.
struct SplitwiseActivityItem: Identifiable {
    let id: Int
    let createdAt: Date
    let systemImage: String
    let content: AttributedString
    /// Non-nil only for a deleted expense that hasn't since been restored —
    /// drives the "Restore" context menu.
    let restorableExpenseId: Int?

    static func items(for notifications: [SplitwiseNotification]) -> [SplitwiseActivityItem] {
        let latestRestoreDates = notifications.latestRestoreDates
        return notifications.map { notification in
            // A delete entry stays in the feed after a restore, so it's only
            // restorable while no *later* restore exists. Comparing dates rather
            // than just checking for one handles delete → restore → delete again.
            let restorableExpenseId = notification.restorableExpenseId.flatMap { expenseId in
                (latestRestoreDates[expenseId] ?? .distantPast) > notification.createdAt ? nil : expenseId
            }
            return SplitwiseActivityItem(
                id: notification.id,
                createdAt: notification.createdAt,
                systemImage: notification.kind?.systemImage ?? Const.Symbol.activity,
                content: SplitwiseNotificationContent.attributedString(from: notification.content),
                restorableExpenseId: restorableExpenseId
            )
        }
    }
}

/// One feed entry, laid out like `RowLabel`/`TransactionSummaryRow`.
private struct SplitwiseActivityRow: View {
    let item: SplitwiseActivityItem

    var body: some View {
        // Baseline-aligned rather than `.top` so the icon lines up with the
        // first line of a wrapping entry instead of its ascender box.
        HStack(alignment: .center, spacing: 7) {
            Image(systemName: item.systemImage)
                .fontWeight(.bold)
                .foregroundStyle(.secondary)
                .frame(width: 35, alignment: .center)
                .font(.title2)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.content)
                    .font(.body)
                    // Splitwise writes these as full sentences, so they wrap — which
                    // a List row won't make room for on its own.
                    .fixedSize(horizontal: false, vertical: true)
                FuzzyDateText(date: item.createdAt)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    let notifications = [
        SplitwiseNotification(
            id: 1,
            type: SplitwiseNotificationKind.expenseAdded.rawValue,
            createdAt: Date().addingTimeInterval(-300),
            content: "<strong>You</strong> added <strong>&quot;Groceries&quot;</strong> in <strong>Non-group expenses</strong>.<br><small>You get back <font color=\"#5bc5a7\">21.25 €</font></small>",
            source: .init(type: "Expense", id: 10)
        ),
        SplitwiseNotification(
            id: 2,
            type: SplitwiseNotificationKind.expenseDeleted.rawValue,
            createdAt: Date().addingTimeInterval(-3600),
            content: "<strong>Alex K.</strong> deleted <strike><strong>Dinner</strong></strike>.",
            source: .init(type: "Expense", id: 11)
        ),
        SplitwiseNotification(
            id: 3,
            type: SplitwiseNotificationKind.commentAdded.rawValue,
            createdAt: Date().addingTimeInterval(-86400 * 2),
            content: "<strong>Alex K.</strong> commented on <strong>Dinner</strong>:<br><small>split this next time?</small>",
            source: .init(type: "Expense", id: 11)
        ),
    ]
    SplitwiseNotificationCacheStore.save(notifications)
    return NavigationStack {
        SplitwiseActivityView()
    }
}
