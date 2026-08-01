//
//  CacheStore.swift
//  Relay
//

import Foundation

nonisolated enum CacheStore {
    /// Below this age a re-run `.task` shows the cache instead of re-fetching,
    /// keeping navigation cheap and staying under the API rate limits.
    /// Pull-to-refresh bypasses it.
    static let refreshInterval: TimeInterval = 5 * 60

    static func isStale(_ lastFetchedAt: Date?, interval: TimeInterval = refreshInterval) -> Bool {
        guard let lastFetchedAt else { return true }
        return Date().timeIntervalSince(lastFetchedAt) > interval
    }

    /// Live fetch, updating the cache on success and falling back to it on
    /// failure — only rethrowing when the cache is empty too.
    static func fetch<T>(
        load: () -> T?,
        save: (T) -> Void,
        remote: () async throws -> T
    ) async throws -> T {
        do {
            let fresh = try await remote()
            save(fresh)
            return fresh
        } catch {
            if let cached = load() { return cached }
            throw error
        }
    }
}

/// A file-backed cache of a single `Codable` value plus the timestamp of its last
/// successful live fetch, so every call site throttles re-fetching the same way.
/// (The expense cache stays separate — it's a slot keyed by friend id.)
nonisolated struct FileCache<Value: Codable> {
    private let fileURL: URL
    private let lastFetchedKey: String
    private let memo = Memo()

    init(fileName: String) {
        fileURL = ApplicationSupportFile.url(fileName)
        lastFetchedKey = "cache.\(fileName).lastFetchedAt"
    }

    /// `load()` is called from view bodies — every row of ContentView's "Recent"
    /// list resolves a name through it — so a read plus full decode per call meant
    /// a dozen file reads per body pass, and dropped frames while scrolling.
    ///
    /// Keyed on the file's modification date rather than invalidated by `save()`:
    /// that costs one stat instead of a decode, and stays honest if the file is
    /// replaced by something other than this instance.
    private final class Memo: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value?
        private var modifiedAt: Date?

        /// Only successful decodes are stored, so nil is unambiguously a miss
        /// rather than a cached failure.
        func value(modifiedAt date: Date) -> Value? {
            lock.lock()
            defer { lock.unlock() }
            return modifiedAt == date ? value : nil
        }

        func store(_ newValue: Value, modifiedAt date: Date) {
            lock.lock()
            defer { lock.unlock() }
            value = newValue
            modifiedAt = date
        }
    }

    /// A fresh stat every call — `FileManager` doesn't cache these the way
    /// `URL.resourceValues` can, and this is what tells the memo the file changed.
    private static func modificationDate(of url: URL) -> Date? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false)) else { return nil }
        return attributes[.modificationDate] as? Date
    }

    func load() -> Value? {
        let modifiedAt = Self.modificationDate(of: fileURL)
        if let modifiedAt, let memoized = memo.value(modifiedAt: modifiedAt) {
            return memoized
        }
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(Value.self, from: data) else { return nil }
        if let modifiedAt {
            memo.store(decoded, modifiedAt: modifiedAt)
        }
        return decoded
    }

    func save(_ value: Value) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        let didWrite = (try? data.write(to: fileURL, options: .atomic)) != nil
        // Only memo a value that reached disk — otherwise it'd be filed under the
        // *previous* file's modification date and served as its contents.
        if didWrite, let modifiedAt = Self.modificationDate(of: fileURL) {
            memo.store(value, modifiedAt: modifiedAt)
        }
        UserDefaults.standard.set(Date(), forKey: lastFetchedKey)
    }

    /// The last successful live fetch — shown as "… ago" on the balance card.
var lastFetchedAt: Date? {
        UserDefaults.standard.object(forKey: lastFetchedKey) as? Date
    }

var isStale: Bool { CacheStore.isStale(lastFetchedAt) }

func fetch(remote: () async throws -> Value) async throws -> Value {
        try await CacheStore.fetch(load: load, save: save, remote: remote)
    }

    /// For signing out, so nothing read through an API outlives the token that
    /// fetched it. The in-memory memo needs no separate clearing: `load()` stats
    /// the file before consulting it, so a deleted file can't be served from it.
    func delete() {
        try? FileManager.default.removeItem(at: fileURL)
        UserDefaults.standard.removeObject(forKey: lastFetchedKey)
    }
}
