//
//  UsageStore.swift
//  Relay
//

import Foundation

nonisolated enum UsageStore {
    /// Most-recently-used first, keyed by `key`; items with no recorded
    /// usage keep their original relative order, appended after all used
    /// ones. Shared by YNABCategoryUsageStore and SplitwiseFriendUsageStore.
    static func sorted<T>(_ items: [T], lastUsed: [String: Date], key: (T) -> String) -> [T] {
        items.enumerated()
            .sorted { lhs, rhs in
                let lhsDate = lastUsed[key(lhs.element)]
                let rhsDate = lastUsed[key(rhs.element)]
                switch (lhsDate, rhsDate) {
                case let (l?, r?): return l > r
                case (.some, nil): return true
                case (nil, .some): return false
                case (nil, nil): return lhs.offset < rhs.offset
                }
            }
            .map(\.element)
    }
}
