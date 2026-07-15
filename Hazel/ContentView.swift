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
            VStack(spacing: 16) {
                NavigationLink(value: ContentRoute.templates) {
                    HStack {
                        Text("Templates")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)

                NavigationLink(value: ContentRoute.pendingQueue) {
                    HStack {
                        Text("Pending Queue")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Spacer()
                        if !pendingQueue.operations.isEmpty {
                            Text("\(pendingQueue.operations.count)")
                                .font(.caption.bold())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(.orange, in: Capsule())
                                .foregroundStyle(.white)
                        }
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)

                NavigationLink(value: ContentRoute.transactionDrafts) {
                    HStack {
                        Text("Transaction Drafts")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Spacer()
                        if draftCount > 0 {
                            Text("\(draftCount)")
                                .font(.caption.bold())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(.orange, in: Capsule())
                                .foregroundStyle(.white)
                        }
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)

                Spacer()
            }
            .padding()
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
                    Label("Settings", systemImage: "gearshape")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .padding(.horizontal)
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
