//
//  SplitTemplateOption.swift
//  Relay
//
//  The persisted, per-merchant-template counterpart to
//  `SplitOption`. Mirrors the original "Transaction → YNAB"
//  shortcut's per-bucket "Use Splitwise?" setting: `always`/
//  `never`/`ask`, saved on the template and reused for every future
//  transaction that matches it. Unlike `SplitOption` (a one-shot,
//  per-invocation choice where Shortcuts' native "Ask Each Time" already
//  covers live prompting), this value is read from storage on every run,
//  so "ask" has to be a real, storable case — that's the whole point of
//  a template that should keep prompting forever.
//

import AppIntents

nonisolated enum SplitTemplateOption: String, AppEnum, Codable {
    case always
    case manual
    case ask
    case never

    static let typeDisplayRepresentation: TypeDisplayRepresentation = TypeDisplayRepresentation(name: LocalizedStringResource("Split Template Option"))
    static let caseDisplayRepresentations: [SplitTemplateOption: DisplayRepresentation] = [
        .always: DisplayRepresentation(title: LocalizedStringResource("Split Equally")),
        .manual: DisplayRepresentation(title: LocalizedStringResource("Split Manually")),
        .ask: DisplayRepresentation(title: LocalizedStringResource("Ask Each Time")),
        .never: DisplayRepresentation(title: LocalizedStringResource("Don't Split")),
    ]

    /// The one-shot runtime choice this stored template option resolves to —
    /// `.ask` becomes `nil` (no fixed answer, so the UI must still prompt),
    /// everything else maps to its `SplitOption` counterpart.
    var splitRuntimeChoice: SplitOption? {
        switch self {
        case .always: .always
        case .manual: .manual
        case .never: .never
        case .ask: nil
        }
    }

    /// The template option a one-shot runtime choice should be persisted as —
    /// `nil` (nothing chosen) is stored as `.never`.
    init(splitRuntimeChoice: SplitOption?) {
        switch splitRuntimeChoice {
        case .always: self = .always
        case .manual: self = .manual
        case .never, nil: self = .never
        }
    }
}
