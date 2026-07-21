//
//  SplitwiseSplitOption.swift
//  Relay
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

    static let typeDisplayRepresentation: TypeDisplayRepresentation = TypeDisplayRepresentation(name: LocalizedStringResource("Splitwise Split Option", table: "AppShortcuts"))
    static let caseDisplayRepresentations: [SplitwiseSplitOption: DisplayRepresentation] = [
        .always: DisplayRepresentation(title: LocalizedStringResource("Split Equally", table: "AppShortcuts")),
        .manual: DisplayRepresentation(title: LocalizedStringResource("Split Manually", table: "AppShortcuts")),
        .never: DisplayRepresentation(title: LocalizedStringResource("Don't Split", table: "AppShortcuts")),
    ]
}
