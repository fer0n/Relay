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
    @State private var drafts = TransactionDraftStore.load()
    @State var fileImportCount = Self.loadFileImportCount()
    @State var history = TransactionHistoryStore.load()
    @State private var ledgerStore = LedgerStore.shared
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
        let friendOverride: SplitTargetEntity?

        var id: UUID { draft.id }
    }

    /// SharedFileImportView resolves the YNAB-vs-split destination itself, so
    /// both cases route to the same view — and both close with one "Done".
    enum ImportSheetContent: Identifiable, Hashable {
        case sharedFile(SharedStatementFile)
        case review

        var id: Self { self }
    }

    static func loadFileImportCount() -> Int {
        FileImportStagingStore.load()?.rows.count ?? 0
    }

    /// The ledger pinned at the top of the list — whichever the app-wide
    /// default split target names. Nil (showing the plain logo) when no
    /// default is set, or when the ledger it names is gone.
    private var defaultLedger: Ledger? {
        guard let zoneName = DefaultSplitTargetStore.load()?.zoneName else { return nil }
        return ledgerStore.ledgers.first { $0.zoneName == zoneName }
    }

    /// "Show All" links to TransactionDraftsView for everything else.
    private var topDrafts: [TransactionDraft] {
        Array(drafts.sorted { $0.startedAt > $1.startedAt }.prefix(3))
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
            onTapTarget: { startManualEntry(prefill: nil, friendOverride: $0) }
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
        case .ledgers:
            LedgersView()
        case .ledger(let zoneName):
            if let ledger = LedgerStore.shared.ledgers.first(where: { $0.zoneName == zoneName }) {
                LedgerDetailView(ledger: ledger)
            }
        case .ledgerMembers(let zoneName):
            if let ledger = LedgerStore.shared.ledgers.first(where: { $0.zoneName == zoneName }) {
                LedgerMembersView(ledger: ledger)
            }
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
        // Resolved once per pass and passed down: it was read four times
        // through `defaultLedger`, and each read went to disk for the
        // stored default.
        let pinnedLedger = defaultLedger
        return List {
            ContentBalanceHeaderSection(
                ledger: pinnedLedger,
                balances: pinnedLedger.map { ledgerStore.balances(in: $0) } ?? .empty,
                currentUserID: pinnedLedger?.currentUserID,
                lastRefreshedAt: ledgerStore.lastRefreshedAt
            ) {
                if let pinnedLedger {
                    path.append(.ledger(zoneName: pinnedLedger.zoneName))
                }
            }

            ContentQuickLinksSection()

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
        .task {
            await LedgerStore.shared.refresh(force: false)
            await AutomaticBackup.runIfNeeded()
        }
        .refreshable { await LedgerStore.shared.refresh(force: true) }
    }

    // Re-reads the file-backed stores that feed the main list, from every
    // lifecycle transition that can leave those snapshots stale.
    func reloadMainListState() {
        withAnimation {
            drafts = TransactionDraftStore.load()
            fileImportCount = Self.loadFileImportCount()
            history = TransactionHistoryStore.load()
        }
    }

    /// Blank for the "+" button and the quick action, or seeded from a history
    /// entry for "Re-add" — either way the user reviews before submitting.
    func startManualEntry(prefill: TransactionHistoryEntry?, friendOverride: SplitTargetEntity? = nil) {
        manualEntry = ManualEntry(
            draft: TransactionDraft(id: UUID(), startedAt: Date(), payload: .ynabWallet(merchant: "", amount: 0, card: "")),
            prefill: prefill,
            friendOverride: friendOverride
        )
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


    YNABCategoryCacheStore.save([
        YNABCategory(id: "cat-dining", name: "Dining Out", hidden: false, deleted: false),
        YNABCategory(id: "cat-groceries", name: "Groceries", hidden: false, deleted: false),
    ])
    YNABAccountCacheStore.save([YNABAccount(id: "acct-checking", name: "Checking", closed: false, deleted: false)])

    try? TransactionDraftStore.save([
        TransactionDraft(id: UUID(), startedAt: Date().addingTimeInterval(-1800), payload: .ynabWallet(merchant: "Coffee Shop", amount: 4.50, card: "Visa")),
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
        summary: "12.34 at Coffee Shop",
        payload: .ynabTransaction(YNABTransactionRequest(accountId: "acct-checking", date: "2026-07-20", amount: -12340, payeeName: "Coffee Shop", categoryId: "cat-groceries", cleared: Const.YNAB.cleared, approved: true))
    )
}
