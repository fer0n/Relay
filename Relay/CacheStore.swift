//
//  CacheStore.swift
//  Relay
//

import Foundation

nonisolated enum CacheStore {
    /// Shared throttle for the on-disk caches: below this age, a view's
    /// re-run `.task` (or a picker re-opening) shows the cache instead of
    /// re-fetching — keeping navigation cheap and staying well under the
    /// YNAB/Splitwise rate limits. Pull-to-refresh bypasses it. Kept here so
    /// the stores can't drift out of sync.
    static let refreshInterval: TimeInterval = 5 * 60

    /// True once `interval` has passed since `lastFetchedAt`, or there's
    /// never been a fetch (nil).
    static func isStale(_ lastFetchedAt: Date?, interval: TimeInterval = refreshInterval) -> Bool {
        guard let lastFetchedAt else { return true }
        return Date().timeIntervalSince(lastFetchedAt) > interval
    }

    /// Live fetch, updating the cache on success; falls back to the cache
    /// on failure, only rethrowing when the cache is also empty. Shared by
    /// every "fetch live, fall back to disk cache" store (YNAB accounts/
    /// categories, Splitwise friends).
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

/// A file-backed cache of a single `Codable` value plus the timestamp of its
/// last successful live fetch. Collapses the YNAB category/account and
/// Splitwise friend caches — previously identical `load`/`save`/`fetch`
/// boilerplate — into one type, and gives them all a uniform `isStale` so
/// every call site can throttle re-fetching the same way. (The expense cache
/// stays separate: it's a single slot keyed by friend id, not a plain list.)
nonisolated struct FileCache<Value: Codable> {
    private let fileURL: URL
    private let lastFetchedKey: String
    private let memo = Memo()

    init(fileName: String) {
        fileURL = ApplicationSupportFile.url(fileName)
        lastFetchedKey = "cache.\(fileName).lastFetchedAt"
    }

    /// In-memory copy of the last decoded value, so repeated `load()`s don't
    /// re-read and re-decode the whole file. `load()` is called from view
    /// bodies — every row of ContentView's "Recent" list resolves a category
    /// or friend name through it (see `PendingOperation.Payload.detail`) — so
    /// a fresh read plus a full decode per call meant a dozen file reads per
    /// body pass, which showed up as dropped frames while scrolling.
    ///
    /// Keyed on the file's modification date rather than only being
    /// invalidated by `save()`: that costs one stat instead of a decode, and
    /// stays honest if the file is ever replaced by something other than
    /// this instance (a restore, a future intent) instead of silently
    /// serving a stale value.
    private final class Memo: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value?
        private var modifiedAt: Date?

        /// The memoized value, or nil when there isn't one for `date` and the
        /// caller should decode. Only successful decodes are stored, so a nil
        /// return is unambiguously a miss rather than a cached failure.
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
    /// `URL.resourceValues` can, which matters since this is exactly what
    /// tells the memo the file changed underneath it.
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
        // Only memo a value that actually reached disk — otherwise it'd be
        // filed under the *previous* file's modification date and served as
        // though it were the file's contents.
        if didWrite, let modifiedAt = Self.modificationDate(of: fileURL) {
            memo.store(value, modifiedAt: modifiedAt)
        }
        UserDefaults.standard.set(Date(), forKey: lastFetchedKey)
    }

    /// When `save` last ran (i.e. the last successful live fetch), or nil if
    /// never — e.g. shown as "… ago" on ContentView's balance card.
    var lastFetchedAt: Date? {
        UserDefaults.standard.object(forKey: lastFetchedKey) as? Date
    }

    /// True once `CacheStore.refreshInterval` has passed since the last live
    /// fetch, or there's never been one.
    var isStale: Bool { CacheStore.isStale(lastFetchedAt) }

    /// Live fetch through `CacheStore.fetch`: updates the cache + timestamp
    /// on success, falls back to disk on failure.
    func fetch(remote: () async throws -> Value) async throws -> Value {
        try await CacheStore.fetch(load: load, save: save, remote: remote)
    }
}
