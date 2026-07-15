//
//  SplitwiseTemplateOption.swift
//  Hazel
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

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Splitwise Template Option"
    static let caseDisplayRepresentations: [SplitwiseTemplateOption: DisplayRepresentation] = [
        .always: "Split Equally",
        .manual: "Split Manually",
        .ask: "Ask Each Time",
        .never: "Don't Split",
    ]
}
