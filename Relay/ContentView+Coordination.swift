//
//  ContentView+Coordination.swift
//  Relay
//
//  ContentView's cross-cutting plumbing, split out from the main view file:
//  the lifecycle/deep-link routing that reacts to scene-phase changes,
//  notification taps, and opened files, and the sheet/alert presentation for
//  drafts, history, manual entry, file import, onboarding, and the tutorial.
//  Kept as methods on ContentView (rather than separate views) because they
//  drive ContentView's own @State; pulling them here just keeps the main file
//  focused on layout and state declarations.
//

import SwiftUI
import UniformTypeIdentifiers

extension ContentView {
    static let hasCompletedOnboardingKey = "hasLaunchedBefore"

    // Picks up a token invalidated by an App Intent (e.g. an expired YNAB
    // token found while running a Shortcut) while this view's
    // YNABAuthService instance was already alive, plus the other
    // notification/intent deep-link routes below.
    @ViewBuilder
    func withLifecycleHandlers<Content: View>(_ content: Content) -> some View {
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
            // The "New Transaction" Home Screen quick action — same
            // deep-link pattern, opening the same blank manual-entry sheet
            // as the "+" button.
            .onChange(of: draftRouter.pendingQuickActionNewTransaction) { _, pending in
                guard pending else { return }
                draftRouter.pendingQuickActionNewTransaction = false
                path = []
                startManualEntry(prefill: nil)
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
    func withSheetsAndAlerts<Content: View>(_ content: Content) -> some View {
        content
            .sheet(item: $continueDraft, onDismiss: reloadMainListState) { draft in
                NavigationStack {
                    TransactionDetailView(source: .draft(id: draft.id))
                }
                .navigationTransition(.zoom(sourceID: draft.id, in: detailNamespace))
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
                .navigationTransition(.zoom(sourceID: entry.id, in: detailNamespace))
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
            .onChange(of: opensOnboardingAfterSettings) { _, newValue in
                if newValue {
                    opensOnboardingAfterSettings = false
                    showOnboarding = true
                }
            }
            .onChange(of: opensAutomationTutorialAfterSettings) { _, newValue in
                if newValue {
                    opensAutomationTutorialAfterSettings = false
                    showAutomationTutorial = true
                }
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
}
