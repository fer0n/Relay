//
//  SplitwiseTemplateOption.swift
//  Relay
//
//  The persisted, per-merchant-template counterpart to
//  `SplitwiseSplitOption`. Mirrors the original "Transaction → YNAB"
//  shortcut's per-bucket "Use Splitwise?" setting exactly: `always`/
//  `never`/`ask`, saved on the template and reused for every future
//  transaction that matches it. Unlike `SplitwiseSplitOption` (a one-shot,
//  per-invocation choice where Shortcuts' native "Ask Each Time" already
//  covers live prompting), this value is read from storage on every run,
//  so "ask" has to be a real, storable case — that's the whole point of
//  a template that should keep prompting forever.
//

import AppIntents

nonisolated enum SplitwiseTemplateOption: String, AppEnum, Codable {
    case always
    case manual
    case ask
    case never

    static let typeDisplayRepresentation: TypeDisplayRepresentation = TypeDisplayRepresentation(name: LocalizedStringResource("Splitwise Template Option", table: "AppShortcuts"))
    static let caseDisplayRepresentations: [SplitwiseTemplateOption: DisplayRepresentation] = [
        .always: DisplayRepresentation(title: LocalizedStringResource("Split Equally", table: "AppShortcuts")),
        .manual: DisplayRepresentation(title: LocalizedStringResource("Split Manually", table: "AppShortcuts")),
        .ask: DisplayRepresentation(title: LocalizedStringResource("Ask Each Time", table: "AppShortcuts")),
        .never: DisplayRepresentation(title: LocalizedStringResource("Don't Split", table: "AppShortcuts")),
    ]

    /// The one-shot runtime choice this stored template option resolves to —
    /// `.ask` becomes `nil` (no fixed answer, so the UI must still prompt),
    /// everything else maps to its `SplitwiseSplitOption` counterpart.
    var splitRuntimeChoice: SplitwiseSplitOption? {
        switch self {
        case .always: .always
        case .manual: .manual
        case .never: .never
        case .ask: nil
        }
    }

    /// The template option a one-shot runtime choice should be persisted as —
    /// `nil` (nothing chosen) is stored as `.never`.
    init(splitRuntimeChoice: SplitwiseSplitOption?) {
        switch splitRuntimeChoice {
        case .always: self = .always
        case .manual: self = .manual
        case .never, nil: self = .never
        }
    }
}
