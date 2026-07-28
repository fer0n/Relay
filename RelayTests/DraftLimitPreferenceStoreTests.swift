//
//  DraftLimitPreferenceStoreTests.swift
//  RelayTests
//
//  Covers the "Max Drafts Kept" preference's storage rules: what it reads
//  back before the user has ever touched it, and that a value UserDefaults
//  hands back which isn't one of the picker's own options (unset, or a
//  leftover from a removed option) falls back to the default rather than
//  being treated as a real limit.
//
//  Reads/writes go through the real `UserDefaults.standard` key, same as
//  the store itself does — each test restores whatever was there
//  beforehand so a run here can't leak into another test or a later launch.
//

import Foundation
import Testing
@testable import Relay

@MainActor
struct DraftLimitPreferenceStoreTests {
    private static let key = "drafts.maxKept"

    private func restoringPreviousValue(_ body: () -> Void) {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: Self.key)
        defer {
            if let previous {
                defaults.set(previous, forKey: Self.key)
            } else {
                defaults.removeObject(forKey: Self.key)
            }
        }
        body()
    }

    @Test
    func defaultsTo30WhenNeverSet() {
        restoringPreviousValue {
            UserDefaults.standard.removeObject(forKey: Self.key)
            #expect(DraftLimitPreferenceStore.limit == 30)
        }
    }

    @Test
    func offersExactlyTheFiveOptionsWith30Default() {
        #expect(DraftLimitPreferenceStore.options == [5, 10, 20, 30, 50])
        #expect(DraftLimitPreferenceStore.defaultLimit == 30)
        #expect(DraftLimitPreferenceStore.options.contains(DraftLimitPreferenceStore.defaultLimit))
    }

    @Test
    func roundTripsEveryOption() {
        restoringPreviousValue {
            for option in DraftLimitPreferenceStore.options {
                DraftLimitPreferenceStore.limit = option
                #expect(DraftLimitPreferenceStore.limit == option)
            }
        }
    }

    /// A value that isn't one of the picker's own options — e.g. a stale
    /// number left behind if the option set is ever changed later — is
    /// treated as unset rather than trusted as a real limit.
    @Test
    func fallsBackToDefaultForAnUnrecognizedStoredValue() {
        restoringPreviousValue {
            UserDefaults.standard.set(999, forKey: Self.key)
            #expect(DraftLimitPreferenceStore.limit == DraftLimitPreferenceStore.defaultLimit)
        }
    }
}
