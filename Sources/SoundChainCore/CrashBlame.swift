// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import Foundation

/// Works out which plugin crashed SoundChain. Before a risky step with a plugin
/// (loading it, opening its editor) the app calls `begin`, and `end` once it is
/// through. Both write to disk immediately, so the marker survives a crash. At the
/// next launch, if the last run ended uncleanly, every component still marked is
/// disabled for good; disabled components are never loaded again.
public final class CrashBlame {
    static let inProgressFile = "in-progress.json"
    static let disabledFile = "disabled.json"

    private let directory: URL
    private var inProgress: [ComponentID]
    public private(set) var disabled: Set<ComponentID>

    public init(directory: URL) {
        self.directory = directory
        inProgress = Self.read([ComponentID].self, directory.appendingPathComponent(Self.inProgressFile)) ?? []
        disabled = Set(Self.read([ComponentID].self, directory.appendingPathComponent(Self.disabledFile)) ?? [])
    }

    public func isDisabled(_ id: ComponentID) -> Bool { disabled.contains(id) }

    public func begin(_ id: ComponentID) {
        inProgress.append(id)
        writeInProgress()
    }

    public func end(_ id: ComponentID) {
        guard let i = inProgress.firstIndex(of: id) else { return }
        inProgress.remove(at: i)
        writeInProgress()
    }

    /// Call once at launch. Returns the components newly disabled (empty after a clean exit).
    @discardableResult
    public func recordLaunch(lastExitUnclean: Bool) -> [ComponentID] {
        var newlyDisabled: [ComponentID] = []
        if lastExitUnclean {
            for id in inProgress where disabled.insert(id).inserted { newlyDisabled.append(id) }
            if !newlyDisabled.isEmpty { write(Array(disabled), Self.disabledFile) }
        }
        inProgress = []
        writeInProgress()
        return newlyDisabled
    }

    private func writeInProgress() { write(inProgress, Self.inProgressFile) }

    private func write(_ ids: [ComponentID], _ name: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(ids).write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    private static func read<T: Decodable>(_ type: T.Type, _ url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
