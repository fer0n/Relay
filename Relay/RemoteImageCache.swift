//
//  RemoteImageCache.swift
//  Relay
//
//  Memory + disk cache for small remote images (currently just Splitwise
//  friend avatars — see SplitwiseAvatarView). Disk-backed so avatars don't
//  re-download every launch; kept out of ApplicationSupportFile's durable
//  storage since these are re-downloadable and don't need a backup (see
//  CachesDirectoryFile).
//

import CryptoKit
import Foundation

actor RemoteImageCache {
    static let shared = RemoteImageCache()

    private var memory: [URL: Data] = [:]
    /// Collapses concurrent requests for the same URL (e.g. the same friend's
    /// avatar rendered in both ContentView's card and SplitwiseBalancesView's
    /// grid) into a single download instead of racing two.
    private var inFlight: [URL: Task<Data, Error>] = [:]

    private init() {}

    func data(for url: URL) async throws -> Data {
        if let cached = memory[url] { return cached }
        if let existing = inFlight[url] { return try await existing.value }

        let task = Task<Data, Error> {
            if let onDisk = try? Data(contentsOf: Self.fileURL(for: url)) {
                return onDisk
            }
            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw URLError(.badServerResponse)
            }
            try? data.write(to: Self.fileURL(for: url), options: .atomic)
            return data
        }
        inFlight[url] = task
        defer { inFlight[url] = nil }

        let data = try await task.value
        memory[url] = data
        return data
    }

    /// SHA256 of the URL rather than e.g. `lastPathComponent`, so different
    /// friends' avatars can't collide and the filename stays stable across
    /// launches (unlike Swift's randomized `String.hashValue`).
    private static func fileURL(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return CachesDirectoryFile.url("avatar-\(hex)")
    }
}
