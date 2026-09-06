//
//  ICloudBackupSection.swift
//  Relay
//

import SwiftUI

struct ICloudBackupSection: View {
    @State private var isEnabled = AutomaticBackupPreference.isEnabled
    @State private var latest: BackupFileInfo?
    @State private var backupCount = 0
    @State private var isWorking = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?

    var body: some View {
        Section {
            Toggle("iCloud Backups", isOn: $isEnabled)
                .onChange(of: isEnabled) { _, newValue in
                    AutomaticBackupPreference.isEnabled = newValue
                    if newValue {
                        Task { await backUpNow() }
                    }
                }

            if let latest {
                LabeledContent("Last Backup") {
                    FuzzyDateText(date: latest.date)
                }
            }

            Button("Back Up Now") {
                Task { await backUpNow() }
            }
            .disabled(isWorking)

            Button("Verify Backup") {
                Task { await verify() }
            }
            .disabled(isWorking || latest == nil)

            if isWorking {
                ProgressView()
            }
            if let statusMessage {
                Text(statusMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Backups")
        } footer: {
            Text("Relay keeps a daily backup in its own iCloud Drive folder, including a copy of your ledgers and their expenses that can be checked against the live data. Older backups are thinned out over time; only the ones you make yourself are kept forever.")
                .footerText()
        }
        .tint(.accentColor)
        .cardRowBackground()
        .task { await reload() }
    }

    private func reload() async {
        let files = await Task.detached(priority: .utility) { ICloudBackupService.backupFiles() }.value
        latest = files.first
        backupCount = files.count
    }

    private func backUpNow() async {
        errorMessage = nil
        statusMessage = nil
        isWorking = true
        defer { isWorking = false }
        do {
            try await AutomaticBackup.run(manual: true)
            await reload()
            statusMessage = String(localized: "Backed up. \(backupCount) backup(s) stored.")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func verify() async {
        errorMessage = nil
        statusMessage = nil
        isWorking = true
        defer { isWorking = false }
        guard let verification = await AutomaticBackup.verifyLatestBackup() else {
            errorMessage = String(localized: "Couldn't read the latest backup.")
            return
        }
        if verification.isValid {
            statusMessage = verification.summary
        } else {
            errorMessage = verification.summary
        }
    }
}
