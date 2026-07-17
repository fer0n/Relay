//
//  StatementModels.swift
//  Hazel
//
//  Shared types for the bank/CSV/QIF statement import flow (see
//  ImportYNABFileIntent). Ports the data shape produced by the original
//  "YNAB Toolkit" Shortcut's Pythonista script (~/Downloads/YNAB Toolkit.txt).
//

import Foundation

/// One transaction parsed from a statement file, before any destination-
/// specific shaping. FileImportRowBuilder turns these into the reviewable,
/// destination-independent FileImportRow list.
struct ImportedStatementRow: Codable {
    let date: Date
    let payeeName: String
    let memo: String?
    /// Sign preserved from the statement (unlike the manual "Add
    /// Transaction" intent, which always negates a positive UI entry).
    let amount: Double
}

nonisolated enum StatementFileKind {
    case csv
    case qif

    init?(filename: String) {
        switch (filename as NSString).pathExtension.lowercased() {
        case "csv", "txt": self = .csv
        case "qif": self = .qif
        default: return nil
        }
    }
}
