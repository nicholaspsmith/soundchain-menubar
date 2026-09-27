// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import Foundation

/// Works out which plugin crashed SoundChain. Before a risky step with a plugin
/// (loading it, restoring its saved settings, building its editor) the app calls
/// `begin`, and `end` once it is through. Both write to disk immediately, so the
/// marker survives a crash. At the next launch, if the last run ended uncleanly:
/// a plugin caught mid-load or mid-editor is disabled for good (never loaded again),
/// and one caught mid-restore is reported so its saved settings can be dropped
/// instead. A marker older than `markerLifetime` is expired by the app, so a step
/// that never finishes (a plugin that never answers) cannot blame it for a later,
/// unrelated crash.
public final class CrashBlame {
    public enum Step: String, Codable, Sendable { case load, restore, editor }

    public struct Result: Equatable {
        public var disabled: [ComponentID] = []
        public var badState: [ComponentID] = []
    }

    struct Marker: Codable, Equatable {
        var component: ComponentID
        var step: Step
        var started: Date
    }

    static let inProgressFile = "in-progress.json"
    static let disabledFile = "disabled.json"
    /// Loads and editor builds finish in well under this.
    public static let markerLifetime: TimeInterval = 20

    private let directory: URL
    private var inProgress: [Marker]
    public private(set) var disabled: Set<ComponentID>

    public init(directory: URL) {
        self.directory = directory
        inProgress = Self.read([Marker].self, directory.appendingPathComponent(Self.inProgressFile)) ?? []
        disabled = Set(Self.read([ComponentID].self, directory.appendingPathComponent(Self.disabledFile)) ?? [])
    }

    public func isDisabled(_ id: ComponentID) -> Bool { disabled.contains(id) }

    public func isInProgress(_ id: ComponentID, step: Step) -> Bool {
        inProgress.contains { $0.component == id && $0.step == step }
    }

    public func begin(_ id: ComponentID, step: Step = .load, at now: Date = Date()) {
        inProgress.append(Marker(component: id, step: step, started: now))
        writeInProgress()
    }

    public func end(_ id: ComponentID, step: Step = .load) {
        guard let i = inProgress.firstIndex(where: { $0.component == id && $0.step == step }) else { return }
        inProgress.remove(at: i)
        writeInProgress()
    }

    /// Drops markers that have been open longer than `age`.
    public func expire(olderThan age: TimeInterval, now: Date = Date()) {
        let kept = inProgress.filter { now.timeIntervalSince($0.started) < age }
        guard kept.count != inProgress.count else { return }
        inProgress = kept
        writeInProgress()
    }

    /// Takes a component off the disabled list.
    public func enable(_ id: ComponentID) {
        guard disabled.remove(id) != nil else { return }
        write(Array(disabled), Self.disabledFile)
    }

    /// Call once at launch. After an unclean exit, returns the components newly
    /// disabled and those whose saved settings were being restored.
    @discardableResult
    public func recordLaunch(lastExitUnclean: Bool) -> Result {
        var result = Result()
        if lastExitUnclean {
            for marker in inProgress {
                switch marker.step {
                case .restore:
                    if !result.badState.contains(marker.component) { result.badState.append(marker.component) }
                case .load, .editor:
                    if disabled.insert(marker.component).inserted { result.disabled.append(marker.component) }
                }
            }
            if !result.disabled.isEmpty { write(Array(disabled), Self.disabledFile) }
        }
        inProgress = []
        writeInProgress()
        return result
    }

    private func writeInProgress() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(inProgress).write(to: directory.appendingPathComponent(Self.inProgressFile), options: .atomic)
    }

    private func write(_ ids: [ComponentID], _ name: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(ids).write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    private static func read<T: Decodable>(_ type: T.Type, _ url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
