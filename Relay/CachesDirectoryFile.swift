//
//  CachesDirectoryFile.swift
//  Relay
//
//  Sibling to ApplicationSupportFile, but for OS-purgeable, re-downloadable
//  blobs (e.g. RemoteImageCache's avatar files) rather than durable app
//  state — Library/Caches isn't backed up and the system may clear it under
//  disk pressure, which is fine since anything stored here can just be
//  re-fetched.
//

import Foundation

nonisolated enum CachesDirectoryFile {
    static func url(_ filename: String) -> URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(filename)
    }
}
