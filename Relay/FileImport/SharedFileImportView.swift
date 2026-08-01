//
//  SharedFileImportView.swift
//  Relay
//
//  Every file-import entry point lands here: a freshly shared file (`source`
//  set) auto-parses on appear; reopening an already-staged import starts with
//  `source` nil and loads the staged rows from disk.
//
//  YNAB and Splitwise are two destinations of ONE flow. Parsing produces a
//  single destination-independent list of rows that both sides show and select
//  from identically — the "Import To" picker only changes the top settings, the
//  button's label, and what submit does. Flipping it never re-parses, so the
//  list never disappears, and there's no per-destination "Parse File" step.
//

import SwiftUI
import os

private let logger = Logger(subsystem: Const.loggerSubsystem, category: "SharedFileImportView")

struct SharedFileImportView: View {
    /// Set when reached fresh from the Share Sheet; nil when reopening an
    /// already-staged import, which loads from disk instead of parsing.
    let source: SharedStatementFile?
    /// Closes the whole share-sheet import flow.
    let onDone: () -> Void

    @State private var destination: FileImportDestination
    /// Until this is true the destination picker shows by default, rather than
    /// flashing away a moment after appearing.
    @State private var connectivityChecked = false

    /// nil before the first parse, and again once every row is submitted or gone.
    @State private var staging: FileImportStaging?
    /// Distinguishes "not parsed yet" (empty state) from "fully reviewed" (Done
    /// summary), both of which leave `staging` nil.
    @State private var hasStaged = false
    /// Row ids already handled for the active destination (see
    /// FileImportHistoryStore), so the "already imported/split" badge is a set
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
    /// The initial `.task` and a foreground re-entry can both reach
    /// maybeAutoParse, so guard against a second concurrent parse.
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

    /// So the post-parse sections animate in instead of popping into the list.
    private static let sectionTransition = AnyTransition.opacity.combined(with: .move(edge: .top))

    /// So reopening defaults back to the last destination rather than an
    /// arbitrary tie-break.
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
            // Fresh from the Share Sheet — the last-picked destination is the best
            // guess until `.task` learns both connection states.
            _destination = State(initialValue: Self.loadLastDestination() ?? (SplitwiseAuthService.currentAccessToken != nil ? .splitwise : .ynab))
        }
    }

    // MARK: - Derived state

    /// Hides the "Import To" picker when only one service is connected, so
    /// there's no real choice to make.
    private var showDestinationPicker: Bool {
        guard connectivityChecked else { return true }
        return !splitwiseNotAuthenticated && !ynabNotAuthenticated
    }

    private var activeNotAuthenticated: Bool {
        destination == .splitwise ? splitwiseNotAuthenticated : ynabNotAuthenticated
    }

    /// Whether the active destination has enough picked to submit. Parsing needs
    /// neither an account nor a friend.
    private var isActiveTargetResolved: Bool {
        destination == .splitwise ? selectedFriendId != nil : selectedAccountId != nil
    }

    private var rowIDs: [String] { staging?.rows.map(\.id) ?? [] }

    /// The parse found nothing, or every staged row was submitted or deleted.
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

    /// Writes through to the staged selection, so a dismiss/reopen keeps the
    /// checklist state.
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
            // A Shortcut import may have written staging while this already-open
            // screen was backgrounded. Only load when we have nothing yet, so an
            // in-progress review is never clobbered.
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
            // Keeps the staged target/settings in sync so a reopen restores them.
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

    /// Reopened with nothing staged at all, e.g. from a stale badge count.
    private var emptyList: some View {
        List {}
            .themedList(background: .sheetBackgroundColor)
            .overlay {
                EmptyListBackground(systemName: Const.Symbol.fileImport)
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
                    DraftDetailRow(icon: Const.Symbol.titleField, title: "Include Memos") {
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
                // Destructive actions go in a "…" menu so they aren't a mis-tap
                // from Select All, the everyday action.
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
            icon: Const.Symbol.account,
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

    private var bottomButtonLabel: LocalizedStringKey {
        if isDone { return "Done" }
        let count = selectedIDs.wrappedValue.count
        return destination == .splitwise
            ? "Split \(count) Selected"
            : "Import \(count) Selected"
    }

    private var bottomButtonDisabled: Bool {
        if isDone { return false }
        guard staging != nil else { return true }
        return selectedIDs.wrappedValue.isEmpty || !isActiveTargetResolved || isSubmitting
    }

    /// One shared row for both destinations.
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
            Text(row.amount, format: .currency(code: Const.currencyCode))
                .font(.body)
                .monospacedDigit()
        }
        .padding(.vertical, 4)
    }

    /// Date, plus "Already imported"/"Already split" when this row overlaps a
    /// previous import. The orange lives on the badge icon next to the price, so
    /// this stays a plain secondary string.
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

    /// Drops the selected rows from the import — statement lines that were never
    /// meant to be submitted, as opposed to submit()'s "yes, do these".
    private func deleteSelected() {
        removeRows(ids: selectedIDs.wrappedValue)
    }

    /// Abandons every staged row, not just the selected ones, and closes.
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
        // Only hit the network when the cache is stale, so re-opening this sheet
        // doesn't re-fetch. Selection validation still runs either way.
        if SplitwiseFriendCacheStore.isStale {
            isLoadingFriends = friends.isEmpty
            defer { isLoadingFriends = false }
            do {
                friends = SplitwiseFriendUsageStore.sorted(try await SplitwiseFriendCacheStore.fetch(token: token))
            } catch {
                logger.error("failed to load friends: \(String(describing: error), privacy: .public)")
            }
        }
        // A default friend removed or blocked since being set would otherwise
        // leave the picker pointing at nothing.
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
        if YNABAccountCacheStore.isStale {
            isLoadingAccounts = accounts.isEmpty
            defer { isLoadingAccounts = false }
            do {
                accounts = try await YNABAccountCacheStore.fetch(token: token)
            } catch {
                logger.error("failed to load accounts: \(String(describing: error), privacy: .public)")
            }
        }
        if let selectedAccountId, !accounts.contains(where: { $0.id == selectedAccountId }) {
            self.selectedAccountId = nil
        }
        // One account to choose from, so don't make the user confirm the obvious.
        if selectedAccountId == nil, accounts.count == 1 {
            selectedAccountId = accounts[0].id
        }
    }

    // MARK: - Parsing

    /// Parsing is destination- and target-independent, so this runs on appear
    /// rather than waiting on an account/friend to be picked.
    private func maybeAutoParse() async {
        guard source != nil, staging == nil, noRowsMessage == nil, !isParseInFlight else { return }
        isParseInFlight = true
        defer { isParseInFlight = false }
        await parseFile()
    }

    private func parseFile() async {
        guard let source else { return }
        errorMessage = nil
        // Most parses resolve fast enough that flashing a spinner is just noise.
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

        // The common case is "handle the whole statement", minus the odd row.
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

    /// Splitwise has no bulk endpoint, so this goes sequentially with 300ms
    /// pacing (same as PendingOperationQueue.flush). Only rows that succeeded are
    /// removed, so a failure leaves them to retry.
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

    /// YNAB's bulk-create endpoint takes every selected row in one request, and
    /// accounts for each as created or a server-side duplicate — so success
    /// clears them all, and a throw leaves them all for retry.
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

    /// Clears the whole import once nothing's left, keeping `hasStaged` true so
    /// the Done summary shows rather than the empty-state watermark.
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
