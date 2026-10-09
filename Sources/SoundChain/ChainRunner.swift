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
    /// Replaced snapshots are kept at least this long, and until every IO cycle that
    /// began before the swap has finished (a stalled plugin can hold one for seconds).
    static let retireDelay: TimeInterval = 1.0

    let source = SnapshotSource.make()
    /// Called after every publish and whenever errors change.
    var onChange: (() -> Void)?
    /// Components that crashed SoundChain before; they are never loaded.
    var isDisabled: (ComponentID) -> Bool = { _ in false }
    /// Bracket each risky step with a plugin (load, restore), so a crash during one
    /// can be blamed on it.
    var willStep: (ComponentID, CrashBlame.Step) -> Void = { _, _ in }
    var didStep: (ComponentID, CrashBlame.Step) -> Void = { _, _ in }
    static let disabledMessage = "Disabled: it crashed SoundChain"
    /// Slots whose hardware is missing (a UAD-2 plugin with no Apollo attached). They
    /// are not loaded, and a loaded one is released and taken out of the chain at
    /// once, before it can fail on a DSP that is gone. `sync` loads them again when
    /// this says false.
    var isSuspended: (ChainSlot) -> Bool = { _ in false }

    private(set) var format: RenderFormat?
    /// Components that failed to load this session, for flagging in the Add picker.
    private(set) var componentFailures: [ComponentID: String] = [:]

    private var chain = Chain()
    private var plugins: [UUID: LoadedPlugin] = [:]
    private var loading: Set<UUID> = []
    /// Loads run one at a time (so a crash is blamed on the right plugin).
    private var loadQueue: [UUID] = []
    private var activeLoad: UUID?
    private var loadErrors: [UUID: String] = [:]
    private var renderErrors: [UUID: String] = [:]
    private var retired: [(chain: RenderChain, at: Date, cycles: Int64)] = []
    private var current: RenderChain?
    /// A publish requested while plugins were loading; done when the queue drains.
    private var publishPending = false

    /// Precondition: no IO proc still reads `source` (in the app the runner lives as
    /// long as the process; --selftest makes and drops several). Retired snapshots
    /// are freed with `retired`; the published one is released here.
    deinit {
        source.destroy()
    }

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
        for slot in newChain.slots where isSuspended(slot) { plugins[slot.id] = nil }
        loadErrors = loadErrors.filter { ids.contains($0.key) }
        // A slot the user bypassed gets a fresh start when re-enabled.
        renderErrors = renderErrors.filter { id, _ in newChain.slot(id: id).map { !$0.bypassed } ?? false }
        for slot in newChain.slots
        where plugins[slot.id] == nil && !loading.contains(slot.id) && loadErrors[slot.id] == nil
            && !isSuspended(slot) {
            if isDisabled(slot.component) {
                loadErrors[slot.id] = Self.disabledMessage
                continue
            }
            loading.insert(slot.id)
            loadQueue.append(slot.id)
        }
        startNextLoad()
        publish()
    }

    /// Re-prepares every plugin for a new format. Precondition: no IO proc is running
    /// (TapEngine calls this between teardown and start). The published snapshot is
    /// withdrawn first anyway, so no plugin is re-prepared while it could be rendering.
    func setFormat(_ newFormat: RenderFormat) {
        guard newFormat != format else { return }
        retire(source.swap(nil))
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
        let finished = source.cyclesFinished
        retired.removeAll { now.timeIntervalSince($0.at) >= Self.retireDelay && finished >= $0.cycles }
        let failed = (current?.failedSlotIDs() ?? []).filter { renderErrors[$0] == nil }
        guard !failed.isEmpty else { return false }
        failed.forEach(recordRenderFailure)
        return true
    }

    /// Takes a slot out of the chain after its plugin reported a render error.
    func recordRenderFailure(_ id: UUID) {
        renderErrors[id] = "Stopped: the plugin reported a render error"
        publish()
    }

    /// Clears the "disabled" error on slots of a component the user re-enabled, so
    /// the next `sync` loads them. (`isDisabled` must already say false for it.)
    func forgetDisabled(_ component: ComponentID) {
        loadErrors = loadErrors.filter { id, message in
            !(message == Self.disabledMessage && chain.slot(id: id)?.component == component)
        }
        componentFailures[component] = nil
    }

    /// Forgets load and render errors (Retry), so the next `sync` tries those plugins
    /// again. Disabled components stay disabled.
    func clearErrors() {
        renderErrors.removeAll()
        loadErrors = loadErrors.filter { $0.value == Self.disabledMessage }
        componentFailures.removeAll()
        publish()
    }

    // MARK: Private

    private func startNextLoad() {
        guard activeLoad == nil else { return }
        while let id = loadQueue.first {
            loadQueue.removeFirst()
            if let slot = chain.slot(id: id) {
                load(slot)
                return
            }
            loading.remove(id)                                   // removed while queued
        }
        if publishPending { publish() }                          // the queue has drained
    }

    private var isBusyLoading: Bool { activeLoad != nil || !loadQueue.isEmpty }

    private func load(_ slot: ChainSlot) {
        activeLoad = slot.id
        let component = slot.component
        willStep(component, .load)
        LoadedPlugin.load(component) { [weak self] result in
            guard let self else { return }
            self.didStep(component, .load)
            defer {
                self.activeLoad = nil
                self.startNextLoad()
            }
            self.loading.remove(slot.id)
            guard let latest = self.chain.slot(id: slot.id) else { return }   // removed while loading
            guard !self.isSuspended(latest) else { return }                    // its hardware went away
            switch result {
            case .success(let plugin):
                if let state = latest.state {
                    self.willStep(component, .restore)
                    do {
                        try plugin.restoreState(state)
                    } catch {
                        NSLog("SoundChain: %@ kept its default settings: %@", latest.name, error.localizedDescription)
                    }
                    self.didStep(component, .restore)
                }
                if let format = self.format {
                    self.willStep(component, .load)
                    defer { self.didStep(component, .load) }
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

    /// Builds and swaps in a new snapshot. While plugins are loading, only removals
    /// go out: no newly loaded plugin goes live while another is still loading, so a
    /// crash in one plugin's render is never blamed on the one loading. The full swap
    /// waits until the queue drains.
    ///
    /// A stage new to the snapshot ramps in; one that was on and no longer is stays
    /// for this snapshot to ramp out (RenderChain.Ramp), so switching never clicks.
    private func publish() {
        guard let format else { onChange?(); return }
        let busy = isBusyLoading
        publishPending = busy
        let live = Set(current?.slotIDs ?? [])
        let stages: [RenderChain.Stage] = chain.slots.compactMap { slot in
            guard renderErrors[slot.id] == nil, let plugin = plugins[slot.id] else { return nil }
            let wasOn = live.contains(slot.id)
            let on = !chain.masterBypass && !slot.bypassed && (!busy || wasOn)
            if on { return (slotID: slot.id, unit: plugin.unit, ramp: wasOn ? .none : .in) }
            return wasOn ? (slotID: slot.id, unit: plugin.unit, ramp: .out) : nil
        }
        if busy, stages.filter({ $0.ramp != .out }).map(\.slotID) == current?.slotIDs ?? [] {
            onChange?()
            return
        }
        let next = RenderChain(stages: stages, maxFrames: format.maxFrames,
                               rampFrames: Crossfade(sampleRate: format.sampleRate).length)
        retire(source.swap(next))
        current = next
        onChange?()
    }

    private func retire(_ old: RenderChain?) {
        guard let old else { return }
        retired.append((old, Date(), source.cyclesBegun))
    }
}
