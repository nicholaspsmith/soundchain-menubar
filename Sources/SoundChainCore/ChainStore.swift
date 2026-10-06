// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import Foundation

public struct ChainLoad: Equatable {
    public var chain: Chain
    /// Where an unreadable chain file was moved, when that happened.
    public var corruptBackup: URL?
    /// Set when the file exists but could not be read (permissions, I/O). If it
    /// also could not be moved aside (`corruptBackup` is nil), the file is still
    /// in place and must not be saved over.
    public var readError: String?

    public init(chain: Chain, corruptBackup: URL?, readError: String? = nil) {
        self.chain = chain
        self.corruptBackup = corruptBackup
        self.readError = readError
    }

    /// The chain file is still there, unread: saving would overwrite the user's chain.
    public var mustNotSave: Bool { readError != nil && corruptBackup == nil }
}

/// Reads and writes the chain as JSON. Writes are atomic (temp file, then rename).
public struct ChainStore {
    public let url: URL

    public init(url: URL) { self.url = url }

    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("SoundChain", isDirectory: true).appendingPathComponent("chain.json")
    }

    /// A missing file gives an empty chain. An unreadable one, or one written by a
    /// newer version, is moved aside to `chain.json.corrupt-<UTC timestamp>` and an
    /// empty chain is returned, so nothing is lost and the app still starts. A file
    /// that cannot even be read or moved is left alone and reported in `readError`.
    public func load(now: Date = Date()) -> ChainLoad {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            if Self.isMissingFile(error) { return ChainLoad(chain: Chain(), corruptBackup: nil) }
            let why = error.localizedDescription
            return ChainLoad(chain: Chain(), corruptBackup: moveAside(now: now), readError: why)
        }
        if let chain = try? JSONDecoder().decode(Chain.self, from: data), chain.version <= Chain.currentVersion {
            return ChainLoad(chain: chain, corruptBackup: nil)
        }
        let backup = moveAside(now: now)
        return ChainLoad(chain: Chain(), corruptBackup: backup,
                         readError: backup == nil ? "it could not be moved aside" : nil)
    }

    /// Moves the chain file to `chain.json.corrupt-<UTC timestamp>`; nil if that failed.
    private func moveAside(now: Date) -> URL? {
        let backup = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).corrupt-\(Self.stamp(now))")
        do {
            try FileManager.default.moveItem(at: url, to: backup)
            return backup
        } catch {
            return nil
        }
    }

    static func isMissingFile(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && ns.code == NSFileReadNoSuchFileError { return true }
        return ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOENT)
    }

    public func save(_ chain: Chain) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(chain).write(to: url, options: .atomic)
    }

    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}
