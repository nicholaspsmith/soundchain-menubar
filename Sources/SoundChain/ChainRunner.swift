// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import AudioToolbox
import Foundation
import SoundChainCore

/// Main-thread owner of the loaded plugins. Turns a `Chain` into RenderChain
/// snapshots and publishes them to the audio thread through `source`.
final class ChainRunner {
    /// Replaced snapshots are freed after this long, far more than any IO cycle.
    static let retireDelay: TimeInterval = 1.0

    let source = SnapshotSource.make()
    /// Called after every publish and whenever errors change.
    var onChange: (() -> Void)?

    private(set) var format: RenderFormat?
    /// Components that failed to load this session, for flagging in the Add picker.
    private(set) var componentFailures: [ComponentID: String] = [:]

    private var chain = Chain()
    private var plugins: [UUID: LoadedPlugin] = [:]
    private var loading: Set<UUID> = []
    private var loadErrors: [UUID: String] = [:]
    private var renderErrors: [UUID: String] = [:]
    private var retired: [(chain: RenderChain, at: Date)] = []
    private var current: RenderChain?

    var isLoading: Bool { !loading.isEmpty }
    /// Effects actually running in the published snapshot.
    var activeCount: Int { current?.stageCount ?? 0 }
    var retiredCount: Int { retired.count }

    func plugin(for id: UUID) -> LoadedPlugin? { plugins[id] }
    func error(for id: UUID) -> String? { loadErrors[id] ?? renderErrors[id] }
    func captureState(for id: UUID) -> Data? { plugins[id]?.captureState() }

    /// Makes the running chain match `newChain`: releases removed plugins, loads new
    /// ones (restoring saved state), then publishes a new snapshot.
    func sync(to newChain: Chain) {
        chain = newChain
        let ids = Set(newChain.slots.map(\.id))
        for id in plugins.keys where !ids.contains(id) { plugins[id] = nil }
        loadErrors = loadErrors.filter { ids.contains($0.key) }
        renderErrors = renderErrors.filter { ids.contains($0.key) }
        for slot in newChain.slots
        where plugins[slot.id] == nil && !loading.contains(slot.id) && loadErrors[slot.id] == nil {
            load(slot)
        }
        publish()
    }

    /// Re-prepares every plugin for a new format. Precondition: no IO proc is running
    /// (TapEngine calls this between teardown and start). The published snapshot is
    /// withdrawn first anyway, so no plugin is re-prepared while it could be rendering.
    func setFormat(_ newFormat: RenderFormat) {
        guard newFormat != format else { return }
        if let old = source.swap(nil) { retired.append((old, Date())) }
        current = nil
        format = newFormat
        for (id, plugin) in plugins {
            do {
                try plugin.prepare(newFormat)
            } catch {
                plugins[id] = nil
                if let slot = chain.slot(id: id) { recordLoadFailure(slot, error) }
            }
        }
        publish()
    }

    /// Main thread, about once a second: frees retired snapshots and turns render
    /// errors reported by the audio thread into slot errors (rebuilding without those
    /// slots). Returns true when new errors appeared.
    @discardableResult
    func tick(now: Date = Date()) -> Bool {
        retired.removeAll { now.timeIntervalSince($0.at) >= Self.retireDelay }
        let failed = (current?.failedSlotIDs() ?? []).filter { renderErrors[$0] == nil }
        guard !failed.isEmpty else { return false }
        for id in failed { renderErrors[id] = "Stopped: the plugin reported a render error" }
        publish()
        return true
    }

    // MARK: Private

    private func load(_ slot: ChainSlot) {
        loading.insert(slot.id)
        LoadedPlugin.load(slot.component) { [weak self] result in
            guard let self else { return }
            self.loading.remove(slot.id)
            guard let latest = self.chain.slot(id: slot.id) else { return }   // removed while loading
            switch result {
            case .success(let plugin):
                if let state = latest.state {
                    do {
                        try plugin.restoreState(state)
                    } catch {
                        NSLog("SoundChain: %@ kept its default settings: %@", latest.name, error.localizedDescription)
                    }
                }
                if let format = self.format {
                    do {
                        try plugin.prepare(format)
                    } catch {
                        self.recordLoadFailure(latest, error)
                        self.publish()
                        return
                    }
                }
                self.plugins[slot.id] = plugin
            case .failure(let error):
                self.recordLoadFailure(latest, error)
            }
            self.publish()
        }
    }

    private func recordLoadFailure(_ slot: ChainSlot, _ error: Error) {
        let message = error.localizedDescription
        loadErrors[slot.id] = message
        componentFailures[slot.component] = message
    }

    private func publish() {
        guard let format else { onChange?(); return }
        let stages: [(slotID: UUID, unit: AUAudioUnit)] = chain.masterBypass ? [] : chain.slots.compactMap { slot in
            guard !slot.bypassed, renderErrors[slot.id] == nil, let plugin = plugins[slot.id] else { return nil }
            return (slotID: slot.id, unit: plugin.unit)
        }
        let next = RenderChain(stages: stages, maxFrames: format.maxFrames)
        if let old = source.swap(next) { retired.append((old, Date())) }
        current = next
        onChange?()
    }
}
