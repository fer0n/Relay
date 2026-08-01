//
//  ContentView.swift
//  Relay
//

import SwiftUI

struct ContentView: View {
    // State is `internal`, not `private`, so the same-type extension in
    // ContentView+Coordination.swift can see it.
    @State var pendingQueue = PendingOperationQueue.shared
    @State var draftRouter = DraftNotificationRouter.shared
    @State private var splitwiseAuth = SplitwiseAuthService()
    @State private var drafts = TransactionDraftStore.load()
    @State var fileImportCount = Self.loadFileImportCount()
    @State var history = TransactionHistoryStore.load()
    /// nil hides the balance card in favor of the plain logo.
    @State private var defaultSplitwiseFriend = Self.loadDefaultSplitwiseFriendFromCache()
    /// Shown on the balance card as "Last refreshed …".
    @State private var splitwiseFriendLastRefreshedAt = SplitwiseFriendCacheStore.lastFetchedAt
    @State var path: [ContentRoute] = []
    @State var continueDraft: TransactionDraft?
    @State var manualEntry: ManualEntry?
    @State var selectedHistoryEntry: TransactionHistoryEntry?
    @State var showOnboarding = false
    @Namespace var addNamespace
    /// Shared by every row that opens `TransactionDetailView`, so the sheet zooms
    /// in from whichever row was tapped.
    @Namespace var detailNamespace
    @State var showAutomationTutorial = false
    // Each is consumed only once the presenting sheet has finished dismissing —
    // presenting immediately would race with the outgoing sheet.
    @State var opensAutomationTutorialAfterOnboarding = false
    @State var opensOnboardingAfterSettings = false
    @State var opensAutomationTutorialAfterSettings = false
    @State var importSheetContent: ImportSheetContent?
    @Environment(\.scenePhase) var scenePhase

    /// `prefill` travels *inside* the sheet's item rather than in a `@State` of
    /// its own: the sheet's content closure captured that separate state before
    /// "Re-add" had set it, so the first re-add after launch opened blank and
    /// every later one reused the *previous* entry.
    struct ManualEntry: Identifiable {
        let draft: TransactionDraft
        let prefill: TransactionHistoryEntry?
        let friendOverride: SplitwiseFriendEntity?

        var id: UUID { draft.id }
    }

    /// SharedFileImportView resolves the YNAB-vs-Splitwise destination itself, so
    /// both cases route to the same view — and both close with one "Done".
    enum ImportSheetContent: Identifiable, Hashable {
        case sharedFile(SharedStatementFile)
        case review

        var id: Self { self }
    }

    static func loadFileImportCount() -> Int {
        FileImportStagingStore.load()?.rows.count ?? 0
    }

    private static func loadDefaultSplitwiseFriendFromCache() -> SplitwiseFriend? {
        guard let defaultId = SplitwiseDefaultFriendStore.load()?.id else { return nil }
        return SplitwiseFriendCacheStore.load()?.first { $0.id == defaultId }
    }

    /// "Show All" links to TransactionDraftsView for everything else.
    private var topDrafts: [TransactionDraft] {
        Array(drafts.sorted { $0.startedAt > $1.startedAt }.prefix(3))
    }

    /// `defaultSplitwiseFriend`, but only while connected — otherwise the disk
    /// cache from a previous sign-in would keep showing a stale balance card
    /// after signing out in Settings.
    private var visibleSplitwiseFriend: SplitwiseFriend? {
        splitwiseAuth.isAuthenticated ? defaultSplitwiseFriend : nil
    }

    // Split into `navigationContent` + two modifier-applying functions (in
    // ContentView+Coordination.swift) because the compiler couldn't type-check
    // one long chain in reasonable time.
    var body: some View {
        withSheetsAndAlerts(withLifecycleHandlers(navigationContent))
    }

    private var navigationContent: some View {
        NavigationStack(path: $path) {
            mainList
                .navigationDestination(for: ContentRoute.self) { route in
                    destination(for: route)
                }
        }
        .floatingAddButton(
            path: path,
            namespace: addNamespace,
            onTapDefault: { startManualEntry(prefill: nil) },
            onTapFriend: { addTransaction(withFriend: $0) }
        )
        // Popping back to the root never fires the scenePhase or root onAppear
        // handlers, so reload whenever the stack empties — that's how a
        // just-completed draft leaves the list.
        .onChange(of: path) { _, newPath in
            if newPath.isEmpty {
                reloadMainListState()
            }
        }
    }

    @ViewBuilder
    private func destination(for route: ContentRoute) -> some View {
        switch route {
        case .templates:
            TemplatesView()
        case .pendingQueue:
            PendingQueueView()
        case .transactionDrafts:
            TransactionDraftsView()
        case .splitwiseFriendTransactions(let friendId):
            if let friend = SplitwiseFriendCacheStore.load()?.first(where: { $0.id == friendId }) {
                SplitwiseFriendTransactionsView(friend: friend)
            }
        case .splitwiseBalances:
            SplitwiseBalancesView()
        case .splitwiseActivity:
            SplitwiseActivityView()
        case .settings:
            SettingsView(
                onRequestShowTutorial: {
                    opensOnboardingAfterSettings = true
                },
                onRequestAutomationSetup: {
                    opensAutomationTutorialAfterSettings = true
                }
            )
        case .howRelayWorks:
            HowRelayWorksView()
        }
    }

    private var mainList: some View {
        List {
            ContentBalanceHeaderSection(friend: visibleSplitwiseFriend, lastRefreshedAt: splitwiseFriendLastRefreshedAt) {
                if let visibleSplitwiseFriend {
                    path.append(.splitwiseFriendTransactions(friendId: visibleSplitwiseFriend.id))
                }
            }

            ContentQuickLinksSection(splitwiseConnected: splitwiseAuth.isAuthenticated)

            if pendingQueue.operations.count > 0 {
                NavigationLink(value: ContentRoute.pendingQueue) {
                    RowLabel(title: "Pending", systemImage: Const.Symbol.pending, badge: pendingQueue.operations.count)
                }
                .cardRowBackground()
                .transition(.contentRow)
            }

            if fileImportCount > 0 {
                Button {
                    importSheetContent = .review
                } label: {
                    RowLabel(title: "File Import", systemImage: Const.Symbol.fileImport, badge: fileImportCount)
                }
                .cardRowBackground()
                .transition(.contentRow)
                .swipeActions {
                    Button("Delete", role: .destructive) {
                        FileImportStagingStore.clear()
                        withAnimation { fileImportCount = Self.loadFileImportCount() }
                    }
                }
            }

            if !drafts.isEmpty {
                ContentDraftsSection(
                    drafts: topDrafts,
                    hasMore: drafts.count > topDrafts.count,
                    namespace: detailNamespace,
                    onContinue: { continueDraft = $0 },
                    onDismiss: { draft in
                        TransactionDraftGuard.complete(draft.id)
                        withAnimation { drafts.removeAll { $0.id == draft.id } }
                    }
                )
                .transition(.contentRow)
            }

            if !history.isEmpty {
                ContentRecentSection(
                    history: history,
                    namespace: detailNamespace,
                    onSelect: { selectedHistoryEntry = $0 },
                    onReAdd: { startManualEntry(prefill: $0) },
                    onDelete: { entry in
                        TransactionHistoryStore.delete(id: entry.id)
                        withAnimation { history.removeAll { $0.id == entry.id } }
                    }
                )
                .transition(.contentRow)
            }
        }
        .themedList(background: .backgroundColor)
        .statusBarBackground()
        // Once per launch rather than on every appearance —
        // reloadMainListState() covers those from the disk cache, and
        // foregrounding live-refreshes via withLifecycleHandlers.
        .task { await refreshDefaultSplitwiseFriend(force: false) }
        .refreshable { await refreshDefaultSplitwiseFriend(force: true) }
    }

    // Re-reads the file-backed stores that feed the main list, from every
    // lifecycle transition that can leave those snapshots stale.
    func reloadMainListState() {
        // Picks up a sign-in/out from Settings' own SplitwiseAuthService instance,
        // which this one can't see otherwise.
        splitwiseAuth.refreshFromKeychain()
        withAnimation {
            drafts = TransactionDraftStore.load()
            fileImportCount = Self.loadFileImportCount()
            history = TransactionHistoryStore.load()
            defaultSplitwiseFriend = Self.loadDefaultSplitwiseFriendFromCache()
            splitwiseFriendLastRefreshedAt = SplitwiseFriendCacheStore.lastFetchedAt
        }
    }

    /// `force` is false for `.task` and foregrounding, leaving a recent cache
    /// (and its "Last refreshed …" timestamp) untouched, and true for
    /// pull-to-refresh so pulling down always re-fetches.
    func refreshDefaultSplitwiseFriend(force: Bool) async {
        guard force || SplitwiseFriendCacheStore.isStale else { return }
        guard let defaultId = SplitwiseDefaultFriendStore.load()?.id,
              let token = SplitwiseAuthService.currentAccessToken else { return }
        if let fetched = try? await SplitwiseFriendCacheStore.fetch(token: token) {
            defaultSplitwiseFriend = fetched.first { $0.id == defaultId }
            splitwiseFriendLastRefreshedAt = SplitwiseFriendCacheStore.lastFetchedAt
        }
    }

    /// Blank for the "+" button and the quick action, or seeded from a history
    /// entry for "Re-add" — either way the user reviews before submitting.
    func startManualEntry(prefill: TransactionHistoryEntry?, friendOverride: SplitwiseFriendEntity? = nil) {
        manualEntry = ManualEntry(
            draft: TransactionDraft(id: UUID(), startedAt: Date(), payload: .ynabWallet(merchant: "", amount: 0, card: "")),
            prefill: prefill,
            friendOverride: friendOverride
        )
    }

    /// Splitwise's "Add Transaction" button on a friend's page — opens the
    /// same manual-entry sheet pre-scoped to that friend.
    func addTransaction(withFriend friend: SplitwiseFriend) {
        startManualEntry(prefill: nil, friendOverride: SplitwiseFriendEntity(friend: friend))
    }
}

#Preview {
    let _ = seedPreviewData()
    ContentView()
}

/// Seeds every store ContentView reads from so the preview shows all of its
/// sections at once. The `let _ = seedPreviewData()` line above runs this
/// synchronously before `ContentView()` is constructed, so its `@State`
/// initializers pick up the seeded data instead of starting empty.
private func seedPreviewData() {
    UserDefaults.standard.set(true, forKey: "hasLaunchedBefore")

    let friend = SplitwiseFriend(id: 1, firstName: "Alex", lastName: "Kim", balance: [SplitwiseBalance(currencyCode: Const.currencyCode, amount: "42.50")], picture: nil)
    SplitwiseFriendCacheStore.save([friend])
    try? SplitwiseDefaultFriendStore.save(SplitwiseDefaultFriend(id: friend.id, firstName: friend.firstName, fullName: friend.fullName))

    YNABCategoryCacheStore.save([
        YNABCategory(id: "cat-dining", name: "Dining Out", hidden: false, deleted: false),
        YNABCategory(id: "cat-groceries", name: "Groceries", hidden: false, deleted: false),
    ])
    YNABAccountCacheStore.save([YNABAccount(id: "acct-checking", name: "Checking", closed: false, deleted: false)])

    try? TransactionDraftStore.save([
        TransactionDraft(id: UUID(), startedAt: Date().addingTimeInterval(-1800), payload: .ynabWallet(merchant: "Coffee Shop", amount: 4.50, card: "Visa")),
        TransactionDraft(id: UUID(), startedAt: Date().addingTimeInterval(-3600), payload: .splitwiseWallet(merchant: "Groceries", amount: 32.10)),
    ])

    try? FileImportStagingStore.save(FileImportStaging(
        destination: .ynab,
        rows: [FileImportRow(id: "row1", date: Date(), payeeName: "Electric Co", memo: nil, amount: -54.20)],
        selectedIDs: ["row1"],
        sourceFilename: "statement.csv",
        importedAt: Date()
    ))

    try? PendingOperationQueueStore.save([
        PendingOperation(
            id: UUID(),
            queuedAt: Date().addingTimeInterval(-600),
            summary: "12.00 at Bakery",
            attemptCount: 1,
            lastError: "No connection — will retry automatically.",
            payload: .ynabTransaction(YNABTransactionRequest(accountId: "acct-checking", date: "2026-07-22", amount: -12000, payeeName: "Bakery", categoryId: "cat-dining", cleared: Const.YNAB.cleared, approved: true)),
            groupId: nil
        ),
    ])

    let groupId = UUID()
    TransactionHistoryStore.record(
        summary: "45.00 at Restaurant",
        payload: .ynabTransaction(YNABTransactionRequest(accountId: "acct-checking", date: "2026-07-21", amount: -45000, payeeName: "Restaurant", categoryId: "cat-dining", cleared: Const.YNAB.cleared, approved: true)),
        groupId: groupId
    )
    TransactionHistoryStore.record(
        summary: "Alex: 22.50 €",
        payload: .splitwiseExpense(SplitwiseExpenseRequest(costCents: 4500, description: "Restaurant", currencyCode: Const.currencyCode, payerUserId: 999, payerOwedCents: 2250, friendUserId: friend.id, friendOwedCents: 2250, date: nil)),
        groupId: groupId
    )
    TransactionHistoryStore.record(
        summary: "12.34 at Coffee Shop",
        payload: .ynabTransaction(YNABTransactionRequest(accountId: "acct-checking", date: "2026-07-20", amount: -12340, payeeName: "Coffee Shop", categoryId: "cat-groceries", cleared: Const.YNAB.cleared, approved: true))
    )
}
