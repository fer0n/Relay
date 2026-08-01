//
//  ContentView+Coordination.swift
//  Relay
//
//  ContentView's lifecycle/deep-link routing and sheet presentation. Kept as
//  methods on ContentView rather than separate views because they drive its own
//  @State; pulling them here keeps the main file to layout and state.
//

import SwiftUI
import UniformTypeIdentifiers

extension ContentView {
    static let hasCompletedOnboardingKey = "hasLaunchedBefore"

    // Picks up a token an App Intent invalidated while this view's
    // YNABAuthService instance was already alive, plus the deep-link routes below.
    @ViewBuilder
    func withLifecycleHandlers<Content: View>(_ content: Content) -> some View {
        content
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    Task { await pendingQueue.flush() }
                    reloadMainListState()
                    Task { await refreshDefaultSplitwiseFriend(force: false) }
                }
            }
            // `initial: true` covers the id being set before this view existed:
            // the intent sets it right after asking iOS to bring Relay forward,
            // which on a cold launch can beat the first render, and a plain
            // onChange would land the hand-off on the main screen.
            .onChange(of: draftRouter.pendingDraftID, initial: true) { _, newValue in
                guard let newValue else { return }
                path = []
                continueDraft = TransactionDraftStore.load().first { $0.id == newValue }
                draftRouter.pendingDraftID = nil
            }
            .onChange(of: draftRouter.pendingQueueReminderTapped) { _, tapped in
                guard tapped else { return }
                path = [.pendingQueue]
                draftRouter.pendingQueueReminderTapped = false
            }
            // Looks the entry up by the id the notification carried, clearing the
            // signal if it's since been evicted from history.
            .onChange(of: draftRouter.pendingHistoryEntryID) { _, newValue in
                guard let newValue else { return }
                path = []
                let entries = TransactionHistoryStore.load()
                history = entries
                selectedHistoryEntry = entries.first { $0.id == newValue }
                draftRouter.pendingHistoryEntryID = nil
            }
            // ImportSplitwiseFileIntent brought Relay forward itself to land here.
            // A sheet rather than a push onto `path`, so this, the "File Import"
            // row, and the share-sheet flow all share one "Done" button.
            .onChange(of: draftRouter.pendingSplitwiseImport) { _, pending in
                guard pending else { return }
                importSheetContent = .review
                draftRouter.pendingSplitwiseImport = false
            }
            // A statement file from the `.onOpenURL` below. A sheet for the same
            // reason as above: "Done" closes the whole flow in one step.
            .onChange(of: draftRouter.pendingSharedFile) { _, newValue in
                guard let newValue else { return }
                draftRouter.pendingSharedFile = nil
                importSheetContent = .sharedFile(newValue)
            }
            // The "New Transaction" quick action opens the same blank
            // manual-entry sheet as the "+" button.
            .onChange(of: draftRouter.pendingQuickActionNewTransaction) { _, pending in
                guard pending else { return }
                draftRouter.pendingQuickActionNewTransaction = false
                path = []
                startManualEntry(prefill: nil)
            }
            // "Copy to Relay" on a CSV/QIF file (see CFBundleDocumentTypes in
            // Info.plist): iOS copies it into Documents/Inbox and hands us the URL.
            .onOpenURL { url in
                let didAccess = url.startAccessingSecurityScopedResource()
                defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url) else { return }
                draftRouter.pendingSharedFile = SharedStatementFile(
                    filename: url.lastPathComponent,
                    data: data,
                    type: UTType(filenameExtension: url.pathExtension)
                )
                // Per Apple's guidance, don't let Documents/Inbox accumulate — but
                // only delete our own Inbox copy, never a URL pointing elsewhere.
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
            .sheet(item: $manualEntry, onDismiss: reloadMainListState) { entry in
                // A re-add has no matched transition source, and zooming from the
                // "+" button regardless of which row triggered it would look wrong.
                Group {
                    if entry.prefill == nil {
                        NavigationStack {
                            ContinueWalletTransactionView(draft: entry.draft, isManual: true, prefill: nil)
                        }
                        .navigationTransition(.zoom(sourceID: "add", in: addNamespace))
                    } else {
                        NavigationStack {
                            ContinueWalletTransactionView(draft: entry.draft, isManual: true, prefill: entry.prefill)
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
                // Only reached via the last page's button, since interactive
                // dismissal is disabled below — so quitting mid-onboarding leaves
                // the flag unset and shows it again in full next launch.
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
