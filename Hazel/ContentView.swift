//
//  ContentView.swift
//  Hazel
//

import SwiftUI

struct ContentView: View {
    @State private var pendingQueue = PendingOperationQueue.shared
    @State private var draftRouter = DraftNotificationRouter.shared
    @State private var draftCount = TransactionDraftStore.load().count
    @State private var path: [ContentRoute] = []
    @State private var showSettings = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack(path: $path) {
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

                NavigationLink(value: ContentRoute.pendingQueue) {
                    RowLabel(title: "Pending Queue", systemImage: "arrow.triangle.2.circlepath", badge: pendingQueue.operations.count)
                }
                .cardRowBackground()

                NavigationLink(value: ContentRoute.transactionDrafts) {
                    RowLabel(title: "Transaction Drafts", systemImage: "square.and.pencil", badge: draftCount)
                }
                .cardRowBackground()

                Section {
                    NavigationLink(value: ContentRoute.templates) {
                        RowLabel(title: "Templates", systemImage: "doc.on.doc")
                    }
                }
                .cardRowBackground()
            }
            .themedList(background: .backgroundColor)
            .navigationDestination(for: ContentRoute.self) { route in
                switch route {
                case .templates:
                    TemplatesView()
                case .pendingQueue:
                    PendingQueueView()
                case .transactionDrafts:
                    TransactionDraftsView()
                case .continueDraft(let draftId):
                    ContinueDraftView(draftId: draftId)
                }
            }
            .safeAreaBar(edge: .bottom) {
                Button {
                    showSettings = true
                } label: {
                    Text("Settings")
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .themedText()
                }
                .buttonStyle(.glass)
            }
        }
        // Picks up a token invalidated by an App Intent (e.g. an expired
        // YNAB token found while running a Shortcut) while this view's
        // YNABAuthService instance was already alive.
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                Task { await pendingQueue.flush() }
                draftCount = TransactionDraftStore.load().count
            }
        }
        // A tapped draft notification always jumps straight to that draft's
        // continue flow, resetting whatever else was on the stack — it's a
        // deliberate, deep-linked destination, not just "open the app".
        .onChange(of: draftRouter.pendingDraftID) { _, newValue in
            guard let newValue else { return }
            path = [.continueDraft(newValue)]
            draftRouter.pendingDraftID = nil
        }
        // Same deep-link pattern as the draft notification above.
        .onChange(of: draftRouter.pendingQueueReminderTapped) { _, tapped in
            guard tapped else { return }
            path = [.pendingQueue]
            draftRouter.pendingQueueReminderTapped = false
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .onAppear {
            if !UserDefaults.standard.bool(forKey: Self.hasLaunchedBeforeKey) {
                UserDefaults.standard.set(true, forKey: Self.hasLaunchedBeforeKey)
                showSettings = true
            }
        }
    }

    private static let hasLaunchedBeforeKey = "hasLaunchedBefore"
}

#Preview {
    ContentView()
}
