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
                }
                .listRowSeparator(.hidden)
                .listRowBackground(Color.backgroundColor)

                NavigationLink(value: ContentRoute.pendingQueue) {
                    HStack {
                        Text("Pending Queue")
                        Spacer()
                        if !pendingQueue.operations.isEmpty {
                            Text("\(pendingQueue.operations.count)")
                                .font(.caption.bold())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(.orange, in: Capsule())
                                .foregroundStyle(.white)
                        }
                    }
                }
                .listRowBackground(Color.sheetInsetColor)

                NavigationLink(value: ContentRoute.transactionDrafts) {
                    HStack {
                        Text("Transaction Drafts")
                        Spacer()
                        if draftCount > 0 {
                            Text("\(draftCount)")
                                .font(.caption.bold())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(.orange, in: Capsule())
                                .foregroundStyle(.white)
                        }
                    }
                }
                .listRowBackground(Color.sheetInsetColor)

                Section {
                    NavigationLink(value: ContentRoute.templates) {
                        Text("Templates")
                    }
                }
                .listRowBackground(Color.sheetInsetColor)
            }
            .scrollContentBackground(.hidden)
            .background(Color.backgroundColor)
            .font(.system(size: 18))
            .fontWeight(.medium)
            .foregroundStyle(Color.foregroundColor)
            .listRowSeparatorTint(Color.secondary.opacity(0.15))
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
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
    }
}

#Preview {
    ContentView()
}
