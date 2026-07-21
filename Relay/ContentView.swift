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
    @State private var readdAlert: ReaddAlert?
    @State private var path: [ContentRoute] = []
    @State private var continueDraft: TransactionDraft?
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

    private struct ReaddAlert: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

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
                            // TODO: add functionality
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
                Image("Logo")
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 240, maxHeight: 180)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                    .opacity(0.8)
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
                    RowLabel(title: "Pending Queue", systemImage: "arrow.triangle.2.circlepath", badge: pendingQueue.operations.count)
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
                                    readd(entry)
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
            }
            .sheet(item: $selectedHistoryEntry) { entry in
                NavigationStack {
                    TransactionDetailView(source: .history(entry))
                }
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
            }
            .sheet(isPresented: $showAutomationTutorial) {
                AutomationTutorialView()
            }
            .onAppear {
                if !UserDefaults.standard.bool(forKey: Self.hasCompletedOnboardingKey) {
                    showOnboarding = true
                }
                reloadMainListState()
            }
            .alert(
                readdAlert?.title ?? "",
                isPresented: Binding(get: { readdAlert != nil }, set: { if !$0 { readdAlert = nil } }),
                presenting: readdAlert
            ) { _ in
                Button("OK", role: .cancel) { }
            } message: { alert in
                Text(alert.message)
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

    private func readd(_ entry: TransactionHistoryEntry) {
        Task {
            do {
                let outcome = try await entry.readd()
                withAnimation {
                    history = TransactionHistoryStore.load()
                }
                if case .queued = outcome {
                    readdAlert = ReaddAlert(
                        title: "Queued",
                        message: "You're offline — this will sync automatically once you're back online."
                    )
                }
            } catch {
                let message = (error as? YNABIntentError).map { String(localized: $0.localizedStringResource) }
                    ?? (error as? SplitwiseIntentError).map { String(localized: $0.localizedStringResource) }
                    ?? "Couldn't re-add the transaction."
                readdAlert = ReaddAlert(title: "Couldn't Re-add", message: message)
            }
        }
    }
}

#Preview {
    ContentView()
}
