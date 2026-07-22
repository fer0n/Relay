//
//  ContentView.swift
//  Relay
//

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var pendingQueue = PendingOperationQueue.shared
    @State private var draftRouter = DraftNotificationRouter.shared
    @State private var drafts = TransactionDraftStore.load()
    @State private var fileImportCount = Self.loadFileImportCount()
    @State private var history = TransactionHistoryStore.load()
    /// The configured default Splitwise friend's cached record (for their
    /// balance) — nil hides the balance card in favor of the plain logo.
    /// Loaded from disk instantly; refreshed live once in `mainList`'s
    /// `.task` and again on every pull-to-refresh of the transaction list.
    @State private var defaultSplitwiseFriend = Self.loadDefaultSplitwiseFriendFromCache()
    /// When `defaultSplitwiseFriend`'s balance was last actually fetched from
    /// Splitwise — shown on the balance card as "Last refreshed …".
    @State private var splitwiseFriendLastRefreshedAt = SplitwiseFriendCacheStore.lastFetchedAt
    @State private var path: [ContentRoute] = []
    @State private var continueDraft: TransactionDraft?
    @State private var manualDraft: TransactionDraft?
    /// Set alongside `manualDraft` by the "Re-add" context menu action so
    /// the manual-entry sheet opens pre-filled with that history entry's
    /// fields instead of blank. Nil (the "+" button's case) presents the
    /// usual empty form.
    @State private var manualPrefillEntry: TransactionHistoryEntry?
    @State private var selectedHistoryEntry: TransactionHistoryEntry?
    @State private var showSettings = false
    @State private var showOnboarding = false
    @Namespace private var settingsNamespace
    @Namespace private var addNamespace
    @State private var showAutomationTutorial = false
    /// Set by OnboardingView's "Setup" button, consumed once onboarding's
    /// sheet has actually finished dismissing — presenting the tutorial
    /// sheet immediately would race with the outgoing onboarding sheet.
    @State private var opensAutomationTutorialAfterOnboarding = false
    /// Set by Settings' "Show Tutorial" button, consumed once Settings'
    /// sheet has actually finished dismissing so we don't present a second
    /// sheet while Settings is still on screen.
    @State private var opensOnboardingAfterSettings = false
    /// Set by Settings' "Automation Setup" button, consumed once Settings'
    /// sheet has actually finished dismissing so we don't present a second
    /// sheet while Settings is still on screen.
    @State private var opensAutomationTutorialAfterSettings = false
    @State private var importSheetContent: ImportSheetContent?
    @Environment(\.scenePhase) private var scenePhase

    /// What the single file-import sheet should show — a just-shared file
    /// (`sharedFile`) or reopening an already-staged import (`review`).
    /// SharedFileImportView resolves the YNAB-vs-Splitwise destination
    /// itself (an inline picker, not a separate screen), so both cases
    /// route to the same view. Unifies the share-sheet flow and the main
    /// view's "File Import" row/Shortcut hand-off onto the same
    /// presentation so both can use the same "Done" button to close in one
    /// step.
    private enum ImportSheetContent: Identifiable, Hashable {
        case sharedFile(SharedStatementFile)
        case review

        var id: Self { self }
    }

    private static func loadFileImportCount() -> Int {
        FileImportStagingStore.load()?.rows.count ?? 0
    }

    private static func loadDefaultSplitwiseFriendFromCache() -> SplitwiseFriend? {
        guard let defaultId = SplitwiseDefaultFriendStore.load()?.id else { return nil }
        return SplitwiseFriendCacheStore.load()?.first { $0.id == defaultId }
    }

    /// Shared by every conditionally-shown row/section below so they
    /// animate in/out together instead of just popping.
    private static let rowTransition = AnyTransition.opacity.combined(with: .move(edge: .top))

    /// Most recently started 3 drafts — "Show All" links to the full list
    /// (TransactionDraftsView) for everything else.
    private var topDrafts: [TransactionDraft] {
        Array(drafts.sorted { $0.startedAt > $1.startedAt }.prefix(3))
    }

    // Split into `navigationContent` + two modifier-applying functions (rather
    // than one long chain hung directly off `body`) because the compiler
    // couldn't type-check the whole thing as a single expression in
    // reasonable time — each piece below is independently small enough to
    // solve on its own.
    var body: some View {
        withSheetsAndAlerts(withLifecycleHandlers(navigationContent))
    }

    private var navigationContent: some View {
        NavigationStack(path: $path) {
            mainList
                .navigationDestination(for: ContentRoute.self) { route in
                    switch route {
                    case .templates:
                        TemplatesView()
                    case .pendingQueue:
                        PendingQueueView()
                    case .transactionDrafts:
                        TransactionDraftsView()
                    case .splitwiseFriendTransactions:
                        if let defaultSplitwiseFriend {
                            SplitwiseFriendTransactionsView(friend: defaultSplitwiseFriend)
                        }
                    }
                }
                .safeAreaBar(edge: .bottom) {
                    HStack {
                        Button {
                            showSettings = true
                        } label: {
                            Image(systemName: "switch.2")
                                .fontWeight(.bold)
                                .padding(15)
                                .glassEffect()
                        }
                        .matchedTransitionSource(id: "settings", in: settingsNamespace)

                        Spacer()

                        Button {
                            startManualEntry(prefill: nil)
                        } label: {
                            Image(systemName: "plus")
                                .fontWeight(.bold)
                                .padding(15)
                                .glassEffect()
                        }
                        .matchedTransitionSource(id: "add", in: addNamespace)
                    }
                    .foregroundStyle(Color.secondary)
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

    private var mainList: some View {
        List {
            Section {
                if let defaultSplitwiseFriend {
                    SplitwiseBalanceGrid(friend: defaultSplitwiseFriend, lastRefreshedAt: splitwiseFriendLastRefreshedAt) {
                        path.append(.splitwiseFriendTransactions)
                    }
                    .padding(.vertical, 8)
                } else {
                    Image("Logo")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(.secondary)
                        .opacity(0.2)
                        .frame(maxWidth: 100, maxHeight: 100)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                }
            }
            .listRowSeparator(.hidden)
            .listRowBackground(Color.backgroundColor)

            Section {
                NavigationLink(value: ContentRoute.templates) {
                    RowLabel(title: "Templates", systemImage: "doc.on.doc")
                }
            }
            .cardRowBackground()

            if pendingQueue.operations.count > 0 {
                NavigationLink(value: ContentRoute.pendingQueue) {
                    RowLabel(title: "Pending", systemImage: "arrow.triangle.2.circlepath", badge: pendingQueue.operations.count)
                }
                .cardRowBackground()
                .transition(Self.rowTransition)
            }

            if fileImportCount > 0 {
                Button {
                    importSheetContent = .review
                } label: {
                    RowLabel(title: "File Import", systemImage: "doc.badge.plus", badge: fileImportCount)
                }
                .cardRowBackground()
                .transition(Self.rowTransition)
                .swipeActions {
                    Button("Delete", role: .destructive) {
                        FileImportStagingStore.clear()
                        withAnimation { fileImportCount = Self.loadFileImportCount() }
                    }
                }
            }

            if !drafts.isEmpty {
                Section("Drafts") {
                    ForEach(topDrafts) { draft in
                        Button {
                            continueDraft = draft
                        } label: {
                            TransactionSummaryRow(service: draft.service, date: draft.startedAt, title: draft.merchant, amount: draft.formattedAmount)
                        }
                        .cardRowBackground()
                        .swipeActions {
                            Button("Dismiss", role: .destructive) {
                                TransactionDraftGuard.complete(draft.id)
                                withAnimation {
                                    drafts.removeAll { $0.id == draft.id }
                                }
                            }
                        }
                    }
                    if drafts.count > topDrafts.count {
                        NavigationLink(value: ContentRoute.transactionDrafts) {
                            RowLabel(title: "Show All", systemImage: "square.and.pencil")
                        }
                        .cardRowBackground()
                    }
                }
                .transition(Self.rowTransition)
            }

            if !history.isEmpty {
                Section("Recent") {
                    ForEach(history) { entry in
                        Button {
                            selectedHistoryEntry = entry
                        } label: {
                            historyRow(for: entry)
                        }
                            .cardRowBackground()
                            .contextMenu {
                                Button {
                                    startManualEntry(prefill: entry)
                                } label: {
                                    Label("Re-add", systemImage: "arrow.clockwise")
                                }
                            }
                    }
                }
                .transition(Self.rowTransition)
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

    // Picks up a token invalidated by an App Intent (e.g. an expired YNAB
    // token found while running a Shortcut) while this view's
    // YNABAuthService instance was already alive, plus the other
    // notification/intent deep-link routes below.
    // Re-reads the file-backed stores that feed the main list. Called from
    // every lifecycle transition that can leave those snapshots stale:
    // foregrounding (scenePhase), first appearance, and popping back to the
    // root of the NavigationStack after a pushed detail dismisses itself.
    private func reloadMainListState() {
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

    @ViewBuilder
    private func withLifecycleHandlers<Content: View>(_ content: Content) -> some View {
        content
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    Task { await pendingQueue.flush() }
                    reloadMainListState()
                }
            }
            // A tapped draft notification opens the draft as a sheet,
            // resetting whatever else was on the stack first.
            .onChange(of: draftRouter.pendingDraftID) { _, newValue in
                guard let newValue else { return }
                path = []
                continueDraft = TransactionDraftStore.load().first { $0.id == newValue }
                draftRouter.pendingDraftID = nil
            }
            // Same deep-link pattern as the draft notification above.
            .onChange(of: draftRouter.pendingQueueReminderTapped) { _, tapped in
                guard tapped else { return }
                path = [.pendingQueue]
                draftRouter.pendingQueueReminderTapped = false
            }
            // A tapped wallet success notification opens the confirmed
            // transaction's detail view — same deep-link pattern, looking the
            // entry up by the id the notification carried. Falls back to just
            // clearing the signal if it's since been evicted from history.
            .onChange(of: draftRouter.pendingHistoryEntryID) { _, newValue in
                guard let newValue else { return }
                path = []
                let entries = TransactionHistoryStore.load()
                history = entries
                selectedHistoryEntry = entries.first { $0.id == newValue }
                draftRouter.pendingHistoryEntryID = nil
            }
            // ImportSplitwiseFileIntent brought Relay to the foreground
            // itself (see its supportedModes) specifically to land here —
            // same deep-link pattern, just triggered by the intent instead
            // of a tapped notification. Opens the same import sheet the
            // "File Import" row and the share-sheet flow use, instead of
            // pushing onto `path`, so all three entry points share one
            // "Done" button.
            .onChange(of: draftRouter.pendingSplitwiseImport) { _, pending in
                guard pending else { return }
                importSheetContent = .review
                draftRouter.pendingSplitwiseImport = false
            }
            // The Share Sheet's "Copy to Relay" action delivered a bank
            // statement file via the `.onOpenURL` below — presented as its
            // own sheet (rather than pushed onto `path`) so its "Done"
            // button can close the whole YNAB-vs-Splitwise flow in one step
            // regardless of how deep it navigated, instead of popping back
            // one screen at a time.
            .onChange(of: draftRouter.pendingSharedFile) { _, newValue in
                guard let newValue else { return }
                draftRouter.pendingSharedFile = nil
                importSheetContent = .sharedFile(newValue)
            }
            // Delivered when the user taps Relay's "Copy to Relay" action on
            // a CSV/QIF file in the Share Sheet (see CFBundleDocumentTypes in
            // Info.plist) — iOS copies the file into our sandbox's
            // Documents/Inbox and hands us its URL here.
            .onOpenURL { url in
                let didAccess = url.startAccessingSecurityScopedResource()
                defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url) else { return }
                draftRouter.pendingSharedFile = SharedStatementFile(
                    filename: url.lastPathComponent,
                    data: data,
                    type: UTType(filenameExtension: url.pathExtension)
                )
                // Apple's guidance: don't let Documents/Inbox accumulate
                // once we've read the file's contents into memory — but only
                // ever delete our own Inbox copy, never a URL pointing
                // anywhere else.
                let inboxURL = FileManager.default
                    .urls(for: .documentDirectory, in: .userDomainMask)
                    .first?
                    .appendingPathComponent("Inbox", isDirectory: true)
                    .standardizedFileURL
                if url.deletingLastPathComponent().standardizedFileURL == inboxURL {
                    try? FileManager.default.removeItem(at: url)
                }
            }
    }

    @ViewBuilder
    private func withSheetsAndAlerts<Content: View>(_ content: Content) -> some View {
        content
            .sheet(item: $continueDraft, onDismiss: reloadMainListState) { draft in
                NavigationStack {
                    TransactionDetailView(source: .draft(id: draft.id))
                }
                .presentationBackground(Color.sheetBackgroundColor)
            }
            .sheet(item: $manualDraft, onDismiss: reloadMainListState) { draft in
                // A re-add has no matched transition source (unlike the "+"
                // button) — zooming from the "+" button regardless of which
                // history row triggered it would look wrong, so that
                // transition only applies to a from-scratch entry.
                Group {
                    if manualPrefillEntry == nil {
                        NavigationStack {
                            ContinueWalletTransactionView(draft: draft, isManual: true, prefill: manualPrefillEntry)
                        }
                        .navigationTransition(.zoom(sourceID: "add", in: addNamespace))
                    } else {
                        NavigationStack {
                            ContinueWalletTransactionView(draft: draft, isManual: true, prefill: manualPrefillEntry)
                        }
                    }
                }
                .presentationBackground(Color.sheetBackgroundColor)
            }
            .sheet(item: $selectedHistoryEntry) { entry in
                NavigationStack {
                    TransactionDetailView(source: .history(entry))
                }
                .presentationBackground(Color.sheetBackgroundColor)
            }
            .sheet(item: $importSheetContent) { content in
                NavigationStack {
                    switch content {
                    case .sharedFile(let source):
                        SharedFileImportView(source: source) {
                            importSheetContent = nil
                            withAnimation { fileImportCount = Self.loadFileImportCount() }
                        }
                    case .review:
                        SharedFileImportView(source: nil) {
                            importSheetContent = nil
                            withAnimation { fileImportCount = Self.loadFileImportCount() }
                        }
                    }
                }
                .presentationBackground(Color.sheetBackgroundColor)
            }
            .sheet(isPresented: $showSettings, onDismiss: {
                if opensOnboardingAfterSettings {
                    opensOnboardingAfterSettings = false
                    showOnboarding = true
                }
                if opensAutomationTutorialAfterSettings {
                    opensAutomationTutorialAfterSettings = false
                    showAutomationTutorial = true
                }
            }) {
                SettingsView(
                    onRequestShowTutorial: {
                        opensOnboardingAfterSettings = true
                    },
                    onRequestAutomationSetup: {
                        opensAutomationTutorialAfterSettings = true
                    }
                )
                .navigationTransition(.zoom(sourceID: "settings", in: settingsNamespace))
                .presentationBackground(Color.sheetBackgroundColor)
            }
            .sheet(isPresented: $showOnboarding, onDismiss: {
                // Only reached via the last page's button (interactive
                // dismissal is disabled below), so this only fires once
                // onboarding has actually been completed — quitting the app
                // mid-onboarding leaves the flag unset, so it's shown again
                // in full on the next launch instead of silently skipped.
                UserDefaults.standard.set(true, forKey: Self.hasCompletedOnboardingKey)
                if opensAutomationTutorialAfterOnboarding {
                    opensAutomationTutorialAfterOnboarding = false
                    showAutomationTutorial = true
                }
            }) {
                OnboardingView(onRequestAutomationTutorial: {
                    opensAutomationTutorialAfterOnboarding = true
                })
                .interactiveDismissDisabled()
                .presentationBackground(Color.sheetBackgroundColor)
            }
            .sheet(isPresented: $showAutomationTutorial) {
                AutomationTutorialView()
                    .presentationBackground(Color.sheetBackgroundColor)
            }
            .onAppear {
                if !UserDefaults.standard.bool(forKey: Self.hasCompletedOnboardingKey) {
                    showOnboarding = true
                }
                reloadMainListState()
            }
    }

    private static let hasCompletedOnboardingKey = "hasLaunchedBefore"

    private func historyRow(for entry: TransactionHistoryEntry) -> some View {
        TransactionSummaryRow(
            service: entry.service,
            secondaryService: entry.secondaryService,
            date: entry.createdAt,
            title: entry.title,
            amount: entry.formattedAmount,
            detail: entry.detail
        )
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

    let friend = SplitwiseFriend(id: 1, firstName: "Alex", lastName: "Kim", balance: [SplitwiseBalance(currencyCode: "EUR", amount: "42.50")])
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
