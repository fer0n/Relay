//
//  DraftActionsSection.swift
//  Relay
//
//  The draft reminder's quick replies, offered in the draft screen too. Discard
//  is left to the screen's own DiscardSection.
//

import SwiftUI

struct DraftActionsSection: View {
    let draft: TransactionDraft
    /// Every outcome but `.needsApp`, which this section reports itself.
    let onOutcome: (DraftActionHandler.Outcome) -> Void

    @State private var runningAction: DraftAction?
    @State private var ownShareAction: DraftAction?
    @State private var ownShareText = ""
    @State private var needsForm = false

    private var actions: [DraftAction] {
        draft.notificationCategory.actions.filter { $0 != .discard }
    }

    var body: some View {
        if !actions.isEmpty {
            Section {
                ForEach(actions, id: \.self) { action in
                    Button {
                        if action.asksOwnShare {
                            ownShareText = ""
                            ownShareAction = action
                        } else {
                            run(action, reply: nil)
                        }
                    } label: {
                        HStack {
                            Text(action.title)
                            Spacer()
                            if runningAction == action {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(runningAction != nil)
                }
            } footer: {
                if needsForm {
                    Text("Couldn't finish automatically — complete it below.")
                        .foregroundStyle(.red)
                }
            }
            .cardRowBackground()
            .alert(
                ownShareAction?.title ?? "",
                isPresented: Binding(get: { ownShareAction != nil }, set: { if !$0 { ownShareAction = nil } }),
                presenting: ownShareAction
            ) { action in
                TextField(DraftAction.ownSharePlaceholder, text: $ownShareText)
                    .keyboardType(.decimalPad)
                Button(action.ownShareSubmitTitle) { run(action, reply: ownShareText) }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    private func run(_ action: DraftAction, reply: String?) {
        runningAction = action
        needsForm = false
        Task {
            let outcome = await DraftActionHandler.perform(action, on: draft, ownShareReply: reply)
            runningAction = nil
            if case .needsApp = outcome {
                needsForm = true
            } else {
                onOutcome(outcome)
            }
        }
    }
}
