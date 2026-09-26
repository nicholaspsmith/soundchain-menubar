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

    public init(chain: Chain, corruptBackup: URL?) {
        self.chain = chain
        self.corruptBackup = corruptBackup
    }
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
    /// empty chain is returned, so nothing is lost and the app still starts.
    public func load(now: Date = Date()) -> ChainLoad {
        guard let data = try? Data(contentsOf: url) else { return ChainLoad(chain: Chain(), corruptBackup: nil) }
        if let chain = try? JSONDecoder().decode(Chain.self, from: data), chain.version <= Chain.currentVersion {
            return ChainLoad(chain: chain, corruptBackup: nil)
        }
        let backup = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).corrupt-\(Self.stamp(now))")
        try? FileManager.default.moveItem(at: url, to: backup)
        return ChainLoad(chain: Chain(), corruptBackup: backup)
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
