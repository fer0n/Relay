//
//  ContentView.swift
//  Relay
//

import SwiftUI

struct ContentView: View {
    // State is `internal` rather than `private` because the lifecycle/deep-link
    // routing and sheet presentation live in ContentView+Coordination.swift —
    // a same-type extension in another file, which can't see `private` members.
    @State var pendingQueue = PendingOperationQueue.shared
    @State var draftRouter = DraftNotificationRouter.shared
    @State private var splitwiseAuth = SplitwiseAuthService()
    @State private var drafts = TransactionDraftStore.load()
    @State var fileImportCount = Self.loadFileImportCount()
    @State var history = TransactionHistoryStore.load()
    /// The configured default Splitwise friend's cached record (for their
    /// balance) — nil hides the balance card in favor of the plain logo.
    /// Loaded from disk instantly; refreshed live once in `mainList`'s
    /// `.task` and again on every pull-to-refresh of the transaction list.
    @State private var defaultSplitwiseFriend = Self.loadDefaultSplitwiseFriendFromCache()
    /// When `defaultSplitwiseFriend`'s balance was last actually fetched from
    /// Splitwise — shown on the balance card as "Last refreshed …".
    @State private var splitwiseFriendLastRefreshedAt = SplitwiseFriendCacheStore.lastFetchedAt
    @State var path: [ContentRoute] = []
    @State var continueDraft: TransactionDraft?
    @State var manualDraft: TransactionDraft?
    /// Set alongside `manualDraft` by the "Re-add" context menu action so
    /// the manual-entry sheet opens pre-filled with that history entry's
    /// fields instead of blank. Nil (the "+" button's case) presents the
    /// usual empty form.
    @State var manualPrefillEntry: TransactionHistoryEntry?
    @State var selectedHistoryEntry: TransactionHistoryEntry?
    @State var showOnboarding = false
    @Namespace var addNamespace
    @State var showAutomationTutorial = false
    /// Set by OnboardingView's "Setup" button, consumed once onboarding's
    /// sheet has actually finished dismissing — presenting the tutorial
    /// sheet immediately would race with the outgoing onboarding sheet.
    @State var opensAutomationTutorialAfterOnboarding = false
    /// Set by Settings' "Show Tutorial" button, consumed once Settings'
    /// sheet has actually finished dismissing so we don't present a second
    /// sheet while Settings is still on screen.
    @State var opensOnboardingAfterSettings = false
    /// Set by Settings' "Automation Setup" button, consumed once Settings'
    /// sheet has actually finished dismissing so we don't present a second
    /// sheet while Settings is still on screen.
    @State var opensAutomationTutorialAfterSettings = false
    @State var importSheetContent: ImportSheetContent?
    @Environment(\.scenePhase) var scenePhase

    /// What the single file-import sheet should show — a just-shared file
    /// (`sharedFile`) or reopening an already-staged import (`review`).
    /// SharedFileImportView resolves the YNAB-vs-Splitwise destination
    /// itself (an inline picker, not a separate screen), so both cases
    /// route to the same view. Unifies the share-sheet flow and the main
    /// view's "File Import" row/Shortcut hand-off onto the same
    /// presentation so both can use the same "Done" button to close in one
    /// step.
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

    /// Most recently started 3 drafts — "Show All" links to the full list
    /// (TransactionDraftsView) for everything else.
    private var topDrafts: [TransactionDraft] {
        Array(drafts.sorted { $0.startedAt > $1.startedAt }.prefix(3))
    }

    /// `defaultSplitwiseFriend`, but only once Splitwise is actually
    /// connected — otherwise the disk cache from a previous sign-in would
    /// keep showing a stale balance card (and its "Balances"/friend
    /// transactions routes) after signing out in Settings.
    private var visibleSplitwiseFriend: SplitwiseFriend? {
        splitwiseAuth.isAuthenticated ? defaultSplitwiseFriend : nil
    }

    // Split into `navigationContent` + two modifier-applying functions (rather
    // than one long chain hung directly off `body`) because the compiler
    // couldn't type-check the whole thing as a single expression in
    // reasonable time — each piece below is independently small enough to
    // solve on its own. Both functions live in ContentView+Coordination.swift.
    var body: some View {
        withSheetsAndAlerts(withLifecycleHandlers(navigationContent))
    }

    private var navigationContent: some View {
        NavigationStack(path: $path) {
            mainList
                .navigationDestination(for: ContentRoute.self) { route in
                    destination(for: route)
                }
                .safeAreaInset(edge: .bottom) {
                    Button {
                        startManualEntry(prefill: nil)
                    } label: {
                        Image(systemName: "plus")
                            .font(.title2)
                            .fontWeight(.bold)
                            .padding(18)
                            .glassEffect(.regular.tint(Color.accentColor).interactive())
                    }
                    .foregroundStyle(Color.backgroundColor)
                    .matchedTransitionSource(id: "add", in: addNamespace)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.horizontal, 30)
                }
        }
        // Popping back to the root (e.g. a pushed TransactionDetailView dismissing
        // itself after completing a draft) never fires the scenePhase or root
        // onAppear handlers, so reload here whenever the stack empties to drop
        // the just-completed draft from the list.
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
        case .splitwiseFriendTransactions:
            if let visibleSplitwiseFriend {
                SplitwiseFriendTransactionsView(friend: visibleSplitwiseFriend)
            }
        case .splitwiseBalances:
            SplitwiseBalancesView()
        case .settings:
            SettingsView(
                onRequestShowTutorial: {
                    opensOnboardingAfterSettings = true
                },
                onRequestAutomationSetup: {
                    opensAutomationTutorialAfterSettings = true
                }
            )
        }
    }

    private var mainList: some View {
        List {
            ContentBalanceHeaderSection(friend: visibleSplitwiseFriend, lastRefreshedAt: splitwiseFriendLastRefreshedAt) {
                path.append(.splitwiseFriendTransactions)
            }

            ContentQuickLinksSection(splitwiseConnected: splitwiseAuth.isAuthenticated)

            if pendingQueue.operations.count > 0 {
                NavigationLink(value: ContentRoute.pendingQueue) {
                    RowLabel(title: "Pending", systemImage: "arrow.triangle.2.circlepath", badge: pendingQueue.operations.count)
                }
                .cardRowBackground()
                .transition(.contentRow)
            }

            if fileImportCount > 0 {
                Button {
                    importSheetContent = .review
                } label: {
                    RowLabel(title: "File Import", systemImage: "doc.badge.plus", badge: fileImportCount)
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
                    onSelect: { selectedHistoryEntry = $0 },
                    onReAdd: { startManualEntry(prefill: $0) }
                )
                .transition(.contentRow)
            }
        }
        .themedList(background: .backgroundColor)
        .statusBarBackground()
        // Runs once for this view's lifetime (mainList is only ever created
        // once per app launch) rather than on every foreground/appearance —
        // reloadMainListState() already re-reads the disk cache cheaply for
        // those; this is the one place that automatically calls the
        // Splitwise API, to keep the balance card fresh without hammering
        // it. Pull-to-refresh below can still trigger it again on demand.
        .task { await refreshDefaultSplitwiseFriend(force: false) }
        .refreshable { await refreshDefaultSplitwiseFriend(force: true) }
    }

    // Re-reads the file-backed stores that feed the main list. Called from
    // every lifecycle transition that can leave those snapshots stale:
    // foregrounding (scenePhase), first appearance, and popping back to the
    // root of the NavigationStack after a pushed detail dismisses itself.
    func reloadMainListState() {
        // Picks up a sign-in/out that happened in Settings' own
        // SplitwiseAuthService instance while this one was already alive —
        // same reasoning as YNABAuthService's refreshFromKeychain() call
        // sites for App Intent-invalidated tokens.
        splitwiseAuth.refreshFromKeychain()
        withAnimation {
            drafts = TransactionDraftStore.load()
            fileImportCount = Self.loadFileImportCount()
            history = TransactionHistoryStore.load()
            defaultSplitwiseFriend = Self.loadDefaultSplitwiseFriendFromCache()
            splitwiseFriendLastRefreshedAt = SplitwiseFriendCacheStore.lastFetchedAt
        }
    }

    /// Live-fetches the friend list and updates the balance card from it —
    /// shared by `mainList`'s `.task` and its pull-to-refresh. `force` is
    /// false for `.task` (which re-runs on every navigation back to the
    /// root) so a recent cache is left untouched — keeping the "Last
    /// refreshed …" timestamp stable rather than resetting it on each
    /// visit — and true for pull-to-refresh so pulling down always
    /// re-fetches regardless of how fresh the cache is.
    private func refreshDefaultSplitwiseFriend(force: Bool) async {
        guard force || SplitwiseFriendCacheStore.isStale else { return }
        guard let defaultId = SplitwiseDefaultFriendStore.load()?.id,
              let token = SplitwiseAuthService.currentAccessToken else { return }
        if let fetched = try? await SplitwiseFriendCacheStore.fetch(token: token) {
            defaultSplitwiseFriend = fetched.first { $0.id == defaultId }
            splitwiseFriendLastRefreshedAt = SplitwiseFriendCacheStore.lastFetchedAt
        }
    }

    /// Opens the manual-entry sheet, blank for the "+" button (`prefill:
    /// nil`) or seeded with a history entry's fields for "Re-add" — either
    /// way the user reviews/edits before it's actually submitted.
    private func startManualEntry(prefill: TransactionHistoryEntry?) {
        manualPrefillEntry = prefill
        manualDraft = TransactionDraft(id: UUID(), startedAt: Date(), payload: .ynabWallet(merchant: "", amount: 0, card: ""))
    }
}

#Preview {
    let _ = seedPreviewData()
    ContentView()
}

/// Seeds every store ContentView reads from so the preview shows all of its
/// sections (balance card, pending, file import, drafts, recent) at once,
/// and marks onboarding as already completed so its sheet doesn't cover the
/// list. The `let _ = seedPreviewData()` line above runs this synchronously
/// before `ContentView()` is constructed, so its `@State` initializers
/// (which load from these same files) pick up the seeded data instead of
/// starting empty.
private func seedPreviewData() {
    UserDefaults.standard.set(true, forKey: "hasLaunchedBefore")

    let friend = SplitwiseFriend(id: 1, firstName: "Alex", lastName: "Kim", balance: [SplitwiseBalance(currencyCode: "EUR", amount: "42.50")], picture: nil)
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
            payload: .ynabTransaction(YNABTransactionRequest(accountId: "acct-checking", date: "2026-07-22", amount: -12000, payeeName: "Bakery", categoryId: "cat-dining", cleared: "cleared", approved: true)),
            groupId: nil
        ),
    ])

    let groupId = UUID()
    TransactionHistoryStore.record(
        summary: "45.00 at Restaurant",
        payload: .ynabTransaction(YNABTransactionRequest(accountId: "acct-checking", date: "2026-07-21", amount: -45000, payeeName: "Restaurant", categoryId: "cat-dining", cleared: "cleared", approved: true)),
        groupId: groupId
    )
    TransactionHistoryStore.record(
        summary: "Alex: 22.50 €",
        payload: .splitwiseExpense(SplitwiseExpenseRequest(costCents: 4500, description: "Restaurant", currencyCode: "EUR", payerUserId: 999, payerOwedCents: 2250, friendUserId: friend.id, friendOwedCents: 2250, date: nil)),
        groupId: groupId
    )
    TransactionHistoryStore.record(
        summary: "12.34 at Coffee Shop",
        payload: .ynabTransaction(YNABTransactionRequest(accountId: "acct-checking", date: "2026-07-20", amount: -12340, payeeName: "Coffee Shop", categoryId: "cat-groceries", cleared: "cleared", approved: true))
    )
}
