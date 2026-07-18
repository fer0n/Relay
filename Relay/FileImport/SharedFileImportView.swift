//
//  SharedFileImportView.swift
//  Relay
//
//  Every file-import entry point lands here: a freshly shared file
//  (`source` set) auto-parses on appear; reopening an already-staged import
//  (from the main view's "File Import" row, or ImportSplitwiseFileIntent
//  bringing Relay to the foreground) starts with `source` nil and loads the
//  staged rows from disk.
//
//  YNAB and Splitwise are two destinations of ONE flow. Parsing produces a
//  single destination-independent list of rows (FileImportRow) that both
//  sides show and select from identically — the "Import To" picker only
//  changes the top settings (account + memos vs. friend), the bottom
//  button's label, and what submit does. Flipping it never re-parses or
//  rebuilds, so the list never disappears; there is no per-destination
//  "Parse File" step, because parsing doesn't depend on which destination or
//  target is chosen (only submitting does). See FileImportStagingStore /
//  FileImportModels.
//
//  Uses native List(selection:) + edit mode (iOS) for the checklist rather
//  than a custom checkmark row: it's a full-width tap target and an
//  unanimated toggle for free, with no extra work.
//

import SwiftUI
import os

private let logger = Logger(subsystem: "com.octabits.relay", category: "SharedFileImportView")

struct SharedFileImportView: View {
    /// Set when reached fresh from the Share Sheet; nil when reopening an
    /// already-staged import, in which case staging is loaded from disk
    /// instead of being produced by parsing a file here.
    let source: SharedStatementFile?
    /// Closes the whole share-sheet import flow.
    let onDone: () -> Void

    @State private var destination: FileImportDestination
    /// True once both YNAB/Splitwise connection state is known — before
    /// that, default to showing the destination picker rather than
    /// flashing it away a moment after appearing.
    @State private var connectivityChecked = false

    /// The one pending import, shared by both destinations. nil before the
    /// first parse, and again once every row has been submitted or removed.
    @State private var staging: FileImportStaging?
    /// True once staging has ever held rows this run — distinguishes "not
    /// parsed/reopened yet" (show empty state) from "fully reviewed, nothing
    /// left" (show the Done summary), both of which leave `staging` nil.
    @State private var hasStaged = false
    /// Row ids already handled for the active destination (see
    /// FileImportHistoryStore) — refreshed on load and whenever the
    /// destination flips, so the "already imported/split" badge is a set
    /// lookup rather than a disk read per row.
    @State private var handledIDs: Set<String> = []

    @State private var ynabAuth = YNABAuthService()
    @State private var splitwiseAuth = SplitwiseAuthService()

    @State private var ynabNotAuthenticated = false
    @State private var accounts: [YNABAccount] = []
    @State private var isLoadingAccounts = false
    @State private var selectedAccountId: String?
    @State private var includeMemos = true

    @State private var splitwiseNotAuthenticated = false
    @State private var friends: [SplitwiseFriend] = []
    @State private var isLoadingFriends = false
    @State private var selectedFriendId: Int?

    @State private var isParsing = false
    /// Guards maybeAutoParse against a second concurrent parse of the same
    /// file (the initial .task and a foreground re-entry can both reach it).
    @State private var isParseInFlight = false
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    /// Set only on the "no transactions found" parse outcome — a terminal
    /// state that never produces staging.
    @State private var noRowsMessage: String?
    @State private var totalCreated = 0
    /// Splitwise: queued-offline count. YNAB: duplicate-import count.
    @State private var totalSecondary = 0
    @State private var totalFailed = 0
    #if !os(macOS)
    @State private var editMode: EditMode = .active
    #endif
    @State private var prompt = ColumnMappingPrompt()
    @Environment(\.scenePhase) private var scenePhase

    /// Applied to the sections that appear once parsing finishes so they
    /// animate in instead of popping straight into the list.
    private static let sectionTransition = AnyTransition.opacity.combined(with: .move(edge: .top))

    /// Remembers which destination the picker was last left on, so
    /// reopening/re-sharing defaults back to it instead of an arbitrary
    /// tie-break — same lightweight UserDefaults-scalar pattern ContentView
    /// uses for its onboarding flag.
    private static let lastDestinationKey = "lastFileImportDestination"

    private static func loadLastDestination() -> FileImportDestination? {
        UserDefaults.standard.string(forKey: lastDestinationKey).flatMap(FileImportDestination.init(rawValue:))
    }

    private static func saveLastDestination(_ destination: FileImportDestination) {
        UserDefaults.standard.set(destination.rawValue, forKey: lastDestinationKey)
    }

    init(source: SharedStatementFile?, onDone: @escaping () -> Void) {
        self.source = source
        self.onDone = onDone
        // An app-wide default friend pre-fills the picker; overwritten by the
        // originally-staged friend once reopening loads one, below.
        _selectedFriendId = State(initialValue: SplitwiseDefaultFriendStore.load()?.id)

        if source == nil {
            // Reopening — load the staged import and land back on whatever
            // destination/targets it was left on.
            let staged = FileImportStagingStore.load()
            _staging = State(initialValue: staged)
            if let staged {
                _destination = State(initialValue: staged.destination)
                _selectedAccountId = State(initialValue: staged.accountId)
                _includeMemos = State(initialValue: staged.includeMemos)
                if let friendId = staged.friendId {
                    _selectedFriendId = State(initialValue: friendId)
                }
            } else {
                _destination = State(initialValue: Self.loadLastDestination() ?? .splitwise)
            }
        } else {
            // Fresh from the Share Sheet — refined once both connection
            // states are known in .task; the last-picked destination is the
            // best guess meanwhile.
            _destination = State(initialValue: Self.loadLastDestination() ?? (SplitwiseAuthService.currentAccessToken != nil ? .splitwise : .ynab))
        }
    }

    // MARK: - Derived state

    /// Hides the "Import To" picker once it's clear there's no real choice
    /// to make — only one of YNAB/Splitwise is actually connected. Defaults
    /// to showing it until the connectivity check completes.
    private var showDestinationPicker: Bool {
        guard connectivityChecked else { return true }
        return !splitwiseNotAuthenticated && !ynabNotAuthenticated
    }

    private var activeNotAuthenticated: Bool {
        destination == .splitwise ? splitwiseNotAuthenticated : ynabNotAuthenticated
    }

    /// Whether the active destination has enough picked to submit — an
    /// account for YNAB, a friend for Splitwise. Parsing needs neither.
    private var isActiveTargetResolved: Bool {
        destination == .splitwise ? selectedFriendId != nil : selectedAccountId != nil
    }

    private var rowIDs: [String] { staging?.rows.map(\.id) ?? [] }

    /// True once there's nothing left to review — either the parse found
    /// nothing, or every staged row has been submitted or deleted.
    private var isDone: Bool {
        noRowsMessage != nil || (hasStaged && staging == nil)
    }

    private var submitSummaryText: String? {
        var parts: [String] = []
        if totalCreated > 0 {
            parts.append("\(totalCreated) \(destination == .splitwise ? "split" : "imported")")
        }
        if totalSecondary > 0 {
            parts.append("\(totalSecondary) \(destination == .splitwise ? "queued offline" : "duplicates")")
        }
        if totalFailed > 0 { parts.append("\(totalFailed) failed") }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// Reads/writes through to the shared staging's selection, persisting it
    /// so a dismiss/reopen keeps the checklist state.
    private var selectedIDs: Binding<Set<String>> {
        Binding(
            get: { staging?.selectedIDs ?? [] },
            set: { newValue in
                guard var staging else { return }
                staging.selectedIDs = newValue
                self.staging = staging
                try? FileImportStagingStore.save(staging)
            }
        )
    }

    var body: some View {
        content
            .navigationTitle("File Import")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .task {
                if staging != nil { hasStaged = true }
                handledIDs = FileImportHistoryStore.handledIDs(destination: destination)
                async let ynabTokenTask = YNABAuthService.validAccessToken()
                let splitwiseConnected = SplitwiseAuthService.currentAccessToken != nil
                let ynabConnected = await ynabTokenTask != nil
                splitwiseNotAuthenticated = !splitwiseConnected
                ynabNotAuthenticated = !ynabConnected
                connectivityChecked = true
                // Only one connected — that's the only real destination.
                if ynabConnected, !splitwiseConnected {
                    destination = .ynab
                } else if splitwiseConnected, !ynabConnected {
                    destination = .splitwise
                }
                await loadActiveTarget()
                await maybeAutoParse()
            }
            // Only when reopening (no source of our own): a Shortcut import
            // (ImportSplitwiseFileIntent) may have written staging while this
            // already-open screen was backgrounded. Load it only if we have
            // nothing yet, so an in-progress review is never clobbered.
            .onChange(of: scenePhase) { _, newPhase in
                guard newPhase == .active, source == nil, staging == nil, !hasStaged, noRowsMessage == nil else { return }
                guard let reloaded = FileImportStagingStore.load() else { return }
                staging = reloaded
                hasStaged = true
                destination = reloaded.destination
                selectedAccountId = selectedAccountId ?? reloaded.accountId
                selectedFriendId = selectedFriendId ?? reloaded.friendId
                includeMemos = reloaded.includeMemos
                handledIDs = FileImportHistoryStore.handledIDs(destination: destination)
                Task { await loadActiveTarget() }
            }
            .onChange(of: destination) { _, newValue in
                Self.saveLastDestination(newValue)
                if var staging {
                    staging.destination = newValue
                    self.staging = staging
                    try? FileImportStagingStore.save(staging)
                }
                handledIDs = FileImportHistoryStore.handledIDs(destination: newValue)
                Task { await loadActiveTarget() }
            }
            // Keep the staged import's remembered target/settings in sync as
            // the user changes them, so a reopen restores the same choices.
            .onChange(of: selectedAccountId) { syncStagingTargets() }
            .onChange(of: selectedFriendId) { syncStagingTargets() }
            .onChange(of: includeMemos) { syncStagingTargets() }
            .onAuthenticated(ynabAuth.isAuthenticated) {
                ynabNotAuthenticated = false
                Task { await loadActiveTarget() }
            }
            .onAuthenticated(splitwiseAuth.isAuthenticated) {
                splitwiseNotAuthenticated = false
                Task { await loadActiveTarget() }
            }
            .columnMappingPrompt(prompt)
    }

    @ViewBuilder
    private var content: some View {
        if staging == nil, noRowsMessage == nil, !hasStaged, source == nil {
            emptyList
        } else {
            mainList
        }
    }

    /// Same "big faint watermark icon behind an empty List" convention as
    /// TransactionDraftsView/PendingQueueView — reopened with nothing staged
    /// at all (e.g. a stale badge count).
    private var emptyList: some View {
        List {}
            .themedList(background: .sheetBackgroundColor)
            .overlay {
                EmptyListBackground(systemName: "doc.badge.plus")
            }
    }

    private var mainList: some View {
        List(selection: selectedIDs) {
            Section {
                if showDestinationPicker {
                    DraftDetailRow(icon: "arrow.triangle.branch", title: "Import To") {
                        MenuPickerField(selection: $destination.animation(.default), label: destination.label) {
                            Text("YNAB").tag(FileImportDestination.ynab)
                            Text("Splitwise").tag(FileImportDestination.splitwise)
                        }
                    }
                    .cardRowBackground()
                }

                if activeNotAuthenticated {
                    NotConnectedRow(service: destination.label) {
                        destination == .splitwise ? splitwiseAuth.signIn() : ynabAuth.signIn()
                    }
                    .cardRowBackground()
                } else if destination == .splitwise {
                    SplitwiseFriendPickerRow(
                        resolvedFriendName: nil,
                        isLoading: isLoadingFriends,
                        friends: friends,
                        selectedFriendId: $selectedFriendId,
                        isIncomplete: staging != nil && selectedFriendId == nil
                    )
                } else {
                    accountRow
                    DraftDetailRow(icon: "text.alignleft", title: "Include Memos") {
                        Toggle("Include Memos", isOn: $includeMemos)
                            .labelsHidden()
                    }
                    .cardRowBackground()
                }
            }

            if let staging {
                Section {
                    ForEach(staging.rows) { row in
                        rowContent(row)
                            .cardRowBackground()
                    }
                }
                .transition(Self.sectionTransition)
            }

            if isParsing || isSubmitting || noRowsMessage != nil || submitSummaryText != nil {
                Section {
                    if isParsing || isSubmitting {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                    } else if let noRowsMessage {
                        Text(noRowsMessage)
                    } else if let submitSummaryText {
                        Text(submitSummaryText)
                    }
                }
                .cardRowBackground()
                .transition(Self.sectionTransition)
            }

            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red)
                }
                .listRowBackground(Color.sheetBackgroundColor)
            }
        }
        .themedList(background: .sheetBackgroundColor)
        #if !os(macOS)
        .environment(\.editMode, $editMode)
        #endif
        .toolbar {
            if staging != nil {
                // The destructive actions (delete the selected rows, or
                // discard the whole import) are tucked into a "…" menu so the
                // top bar isn't crowded and the two aren't a mis-tap apart —
                // Select All, the everyday action, stays out on its own.
                ToolbarItem(placement: .cancellationAction) {
                    Menu {
                        Button(role: .destructive) {
                            deleteSelected()
                        } label: {
                            Label("Delete Selected", systemImage: "trash")
                        }
                        .disabled(selectedIDs.wrappedValue.isEmpty)

                        Button(role: .destructive) {
                            discardActive()
                        } label: {
                            Label("Close Import", systemImage: "xmark")
                        }
                    } label: {
                        Label("More", systemImage: "ellipsis")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(selectedIDs.wrappedValue.count == rowIDs.count ? "Deselect All" : "Select All") {
                        toggleSelectAll()
                    }
                }
            }
        }
        .safeAreaBar(edge: .bottom) {
            BottomBarActionButton(
                title: bottomButtonLabel,
                isLoading: isParsing || isSubmitting || (staging == nil && !isDone),
                isDisabled: bottomButtonDisabled
            ) {
                if isDone {
                    onDone()
                } else if staging != nil {
                    Task { await submit() }
                }
            }
        }
    }

    private var accountRow: some View {
        DraftDetailRow(
            icon: "creditcard.fill",
            title: "Account",
            isIncomplete: staging != nil && selectedAccountId == nil
        ) {
            if isLoadingAccounts {
                ProgressView()
            } else {
                MenuPickerField(
                    selection: $selectedAccountId,
                    label: accounts.first { $0.id == selectedAccountId }?.name ?? "None"
                ) {
                    Text("None").tag(String?.none)
                    ForEach(accounts, id: \.id) { account in
                        Text(account.name).tag(Optional(account.id))
                    }
                }
            }
        }
        .cardRowBackground()
    }

    private var bottomButtonLabel: String {
        if isDone { return "Done" }
        let verb = destination == .splitwise ? "Split" : "Import"
        return "\(verb) \(selectedIDs.wrappedValue.count) Selected"
    }

    private var bottomButtonDisabled: Bool {
        if isDone { return false }
        guard staging != nil else { return true }
        return selectedIDs.wrappedValue.isEmpty || !isActiveTargetResolved || isSubmitting
    }

    /// One shared row for both destinations: payee, date (plus an "already
    /// handled" note on a re-import), and the signed statement amount.
    private func rowContent(_ row: FileImportRow) -> some View {
        let handled = handledIDs.contains(row.id)
        return HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(row.payeeName).font(.body)
                Text(rowSubtitle(for: row, handled: handled))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if handled {
                Image(systemName: "circle.fill")
                    .font(.system(size: 6))
                    .foregroundStyle(.orange)
            }
            Text(row.amount, format: .currency(code: "EUR"))
                .font(.body)
                .monospacedDigit()
        }
        .padding(.vertical, 4)
    }

    /// Date, plus "Already imported"/"Already split" when this row overlaps a
    /// previous import — dot-separated inline. The orange color lives on the
    /// badge icon next to the price, so this stays a plain secondary string.
    private func rowSubtitle(for row: FileImportRow, handled: Bool) -> String {
        var parts = [row.date.formatted(date: .abbreviated, time: .omitted)]
        if handled {
            parts.append(destination == .splitwise ? "Already split" : "Already imported")
        }
        return parts.joined(separator: " · ")
    }

    private func toggleSelectAll() {
        if selectedIDs.wrappedValue.count == rowIDs.count {
            selectedIDs.wrappedValue.removeAll()
        } else {
            selectedIDs.wrappedValue = Set(rowIDs)
        }
    }

    /// Discards the selected rows from this pending import entirely — for
    /// statement lines that were never meant to be submitted, as opposed to
    /// submit(), the "yes, do these" path.
    private func deleteSelected() {
        removeRows(ids: selectedIDs.wrappedValue)
    }

    /// Abandons the entire pending import — every staged row, not just the
    /// selected ones — and closes the sheet.
    private func discardActive() {
        FileImportStagingStore.clear()
        onDone()
    }

    // MARK: - Target loading

    private func loadActiveTarget() async {
        switch destination {
        case .splitwise: await loadFriends()
        case .ynab: await loadAccounts()
        }
    }

    private func loadFriends() async {
        guard let token = SplitwiseAuthService.currentAccessToken else {
            splitwiseNotAuthenticated = true
            return
        }
        if let cached = SplitwiseFriendCacheStore.load() {
            friends = SplitwiseFriendUsageStore.sorted(cached)
        }
        isLoadingFriends = friends.isEmpty
        defer { isLoadingFriends = false }
        do {
            friends = SplitwiseFriendUsageStore.sorted(try await SplitwiseFriendCacheStore.fetch(token: token))
        } catch {
            logger.error("failed to load friends: \(String(describing: error), privacy: .public)")
        }
        // A stale default friend (removed/blocked since being set) would
        // otherwise leave the friend picker pointing at nothing.
        if let selectedFriendId, !friends.contains(where: { $0.id == selectedFriendId }) {
            self.selectedFriendId = nil
        }
    }

    private func loadAccounts() async {
        guard let token = await YNABAuthService.validAccessToken() else {
            ynabNotAuthenticated = true
            return
        }
        if let cached = YNABAccountCacheStore.load() {
            accounts = cached
        }
        isLoadingAccounts = accounts.isEmpty
        defer { isLoadingAccounts = false }
        do {
            accounts = try await YNABAccountCacheStore.fetch(token: token)
        } catch {
            logger.error("failed to load accounts: \(String(describing: error), privacy: .public)")
        }
        if let selectedAccountId, !accounts.contains(where: { $0.id == selectedAccountId }) {
            self.selectedAccountId = nil
        }
        // Only one account to choose from — pick it so the user doesn't have
        // to confirm the obvious before submitting.
        if selectedAccountId == nil, accounts.count == 1 {
            selectedAccountId = accounts[0].id
        }
    }

    // MARK: - Parsing

    /// Parses the shared file as soon as it appears — parsing is destination-
    /// and target-independent, so there's no manual "Parse File" step and no
    /// waiting on an account/friend to be picked first.
    private func maybeAutoParse() async {
        guard source != nil, staging == nil, noRowsMessage == nil, !isParseInFlight else { return }
        isParseInFlight = true
        defer { isParseInFlight = false }
        await parseFile()
    }

    private func parseFile() async {
        guard let source else { return }
        errorMessage = nil
        // Only show the spinner once it's been running a while — most parses
        // resolve fast enough that flashing one would just be noise.
        let spinnerTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            withAnimation { isParsing = true }
        }
        defer {
            spinnerTask.cancel()
            withAnimation { isParsing = false }
        }

        var config = FileImportConfigStore.load()
        let rows: [ImportedStatementRow]
        do {
            rows = try await prompt.resolveRows(file: source, config: &config)
        } catch is CancellationError {
            return
        } catch {
            errorMessage = destination == .splitwise
                ? SplitwiseIntentError.message(for: error)
                : YNABIntentError.message(for: error)
            return
        }

        let built = FileImportRowBuilder.build(from: rows)
        guard !built.isEmpty else {
            withAnimation { noRowsMessage = "No transactions found to import from \(source.filename)." }
            return
        }

        // Pre-select everything: the common case for both destinations is
        // "handle the whole statement", with the odd row deselected.
        let newStaging = FileImportStaging(
            destination: destination,
            rows: built,
            selectedIDs: Set(built.map(\.id)),
            sourceFilename: source.filename,
            importedAt: Date(),
            accountId: selectedAccountId,
            includeMemos: includeMemos,
            friendId: selectedFriendId,
            friendFirstName: friends.first { $0.id == selectedFriendId }?.firstName,
            friendFullName: friends.first { $0.id == selectedFriendId }?.fullName
        )
        do {
            try FileImportStagingStore.save(newStaging)
        } catch {
            errorMessage = "Couldn't stage the import. Please try again."
            return
        }
        hasStaged = true
        handledIDs = FileImportHistoryStore.handledIDs(destination: destination)
        withAnimation { staging = newStaging }
    }

    // MARK: - Submit

    private func submit() async {
        switch destination {
        case .splitwise: await submitSplitwise()
        case .ynab: await submitYNAB()
        }
    }

    /// Splits only the currently-selected rows with the picked friend.
    /// Sequential with 300ms pacing (same "don't hammer" approach as
    /// PendingOperationQueue.flush), since Splitwise has no bulk endpoint.
    /// Only rows that actually succeeded are removed and recorded, so a
    /// failure leaves them to retry.
    private func submitSplitwise() async {
        guard let staging else { return }
        guard let friendId = selectedFriendId, let friend = friends.first(where: { $0.id == friendId }) else { return }

        errorMessage = nil
        isSubmitting = true
        defer { isSubmitting = false }

        let friendEntity = SplitwiseFriendEntity(id: friend.id, firstName: friend.firstName, fullName: friend.fullName)
        let ids = selectedIDs.wrappedValue
        let selectedRows = staging.rows.filter { ids.contains($0.id) }

        var createdCount = 0
        var queuedCount = 0
        var failedCount = 0
        var doneIds: [String] = []

        for row in selectedRows {
            do {
                let outcome = try await SplitwiseExpenseHelper.addExpense(
                    amount: row.splitAmount,
                    description: row.payeeName,
                    friend: friendEntity,
                    ownShare: nil,
                    date: row.date
                )
                switch outcome {
                case .created: createdCount += 1
                case .queued: queuedCount += 1
                }
                doneIds.append(row.id)
            } catch {
                failedCount += 1
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }

        if !doneIds.isEmpty {
            FileImportHistoryStore.record(doneIds, destination: .splitwise)
        }
        totalCreated += createdCount
        totalSecondary += queuedCount
        totalFailed += failedCount
        removeRows(ids: Set(doneIds))
    }

    /// YNAB's bulk-create endpoint takes every selected row in one request.
    /// A successful response accounts for every submitted row as created or a
    /// server-side dedup ("duplicate"), so on success every selected row is
    /// done, recorded, and removed; a thrown error means the whole batch
    /// failed and every selected row stays put for retry.
    private func submitYNAB() async {
        guard let staging else { return }
        guard let accountId = selectedAccountId else { return }
        guard let token = await YNABAuthService.validAccessToken() else {
            ynabNotAuthenticated = true
            return
        }

        errorMessage = nil
        isSubmitting = true
        defer { isSubmitting = false }

        let ids = selectedIDs.wrappedValue
        let selectedRows = staging.rows.filter { ids.contains($0.id) }
        guard !selectedRows.isEmpty else { return }

        let transactions = selectedRows.map { $0.ynabTransaction(accountId: accountId, includeMemos: includeMemos) }

        do {
            let bulkResult = try await YNABService.createTransactions(transactions, token: token)
            totalCreated += bulkResult.transactions.count
            totalSecondary += bulkResult.duplicateImportIds.count
            FileImportHistoryStore.record(selectedRows.map(\.id), destination: .ynab)
            removeRows(ids: Set(selectedRows.map(\.id)))
        } catch {
            totalFailed += selectedRows.count
            errorMessage = YNABIntentError.message(for: error)
        }
    }

    // MARK: - Staging mutation

    /// Removes rows from the shared staging (submitted or deleted), clearing
    /// the whole import once nothing's left. Keeps `hasStaged` true so the
    /// Done summary shows rather than the empty-state watermark.
    private func removeRows(ids: Set<String>) {
        guard var staging, !ids.isEmpty else { return }
        let remaining = staging.rows.filter { !ids.contains($0.id) }
        if remaining.isEmpty {
            FileImportStagingStore.clear()
            withAnimation { self.staging = nil }
        } else {
            staging.rows = remaining
            staging.selectedIDs.subtract(ids)
            try? FileImportStagingStore.save(staging)
            withAnimation { self.staging = staging }
        }
    }

    private func syncStagingTargets() {
        guard var staging else { return }
        staging.accountId = selectedAccountId
        staging.includeMemos = includeMemos
        staging.friendId = selectedFriendId
        staging.friendFirstName = friends.first { $0.id == selectedFriendId }?.firstName
        staging.friendFullName = friends.first { $0.id == selectedFriendId }?.fullName
        self.staging = staging
        try? FileImportStagingStore.save(staging)
    }
}

#Preview {
    NavigationStack {
        SharedFileImportView(source: SharedStatementFile(filename: "Statement.csv", data: Data(), type: nil)) {}
    }
}
