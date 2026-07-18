//
//  StatementFileSource.swift
//  Relay
//
//  Lets StatementFileResolver accept either an AppIntents IntentFile (the
//  two Shortcuts) or a plain file read from a share-sheet onOpenURL delivery
//  (SharedStatementFile) without the resolver knowing which one it got.
//

import AppIntents
import Foundation
import UniformTypeIdentifiers

protocol StatementFileSource {
    var filename: String { get }
    var data: Data { get }
    var type: UTType? { get }
}

extension IntentFile: StatementFileSource {}

/// Built from a file delivered to Relay via the Share Sheet's "Copy to
/// Relay" action (see ContentView's `.onOpenURL`), as opposed to an
/// AppIntents `IntentFile` handed in by Shortcuts. Identifiable so
/// ContentView can present the whole import flow via `.sheet(item:)`.
struct SharedStatementFile: StatementFileSource, Hashable, Identifiable {
    let filename: String
    let data: Data
    let type: UTType?

    var id: Self { self }
}
