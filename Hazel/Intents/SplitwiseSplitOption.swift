//
//  SplitwiseSplitOption.swift
//  Hazel
//
//  Mirrors the original "Add YNAB Expense" shortcut's "splitwise" field —
//  fixed to "always" (split equally, no prompt) or "never", or left to
//  show a live "Ja"/"Manuell"/"Nein" (yes-equal/manual-share/no) menu
//  otherwise (see YNAB Toolkit.txt). Here, choosing live each run is just
//  Shortcuts' native "Ask Each Time" on this parameter, so there's no
//  separate "ask" case to model — Shortcuts prompts with these same cases.
//

import AppIntents

nonisolated enum SplitwiseSplitOption: String, AppEnum, Codable {
    case always
    case manual
    case never

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Splitwise Split Option"
    static let caseDisplayRepresentations: [SplitwiseSplitOption: DisplayRepresentation] = [
        .always: "Split Equally",
        .manual: "Split — Manual Share",
        .never: "Don't Split",
    ]
}
