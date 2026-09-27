// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import AudioToolbox
import Foundation
import SoundChainCore

/// `SoundChain --selftest`: renders a sine through real Apple AUs offline and checks
/// the chain behaves. No tap and no permission needed. Exits non-zero on failure.
enum SelfTest {
    static let sampleRate = 48_000.0
    static let blockFrames = 512
    static let delay = ComponentID("aufx", "dely", "appl")!   // AUDelay
    static let eq = ComponentID("aufx", "nbeq", "appl")!      // AUNBandEQ

    static func run() -> Bool {
        var failures: [String] = []
        func check(_ ok: Bool, _ what: String) {
            print(ok ? "PASS  \(what)" : "FAIL  \(what)")
            if !ok { failures.append(what) }
        }

        do {
            try renderChecks(check)
            try runnerChecks(check)
        } catch {
            check(false, "unexpected error: \(error.localizedDescription)")
        }

        print(failures.isEmpty ? "\nAll self-tests passed." : "\n\(failures.count) self-test(s) failed.")
        return failures.isEmpty
    }

    static func renderChecks(_ check: (Bool, String) -> Void) throws {
        let format = RenderFormat(sampleRate: sampleRate, maxFrames: 4096)
        let delayPlugin = try loadSync(delay)
        try delayPlugin.prepare(format)
        let eqPlugin = try loadSync(eq)
        try eqPlugin.prepare(format)

        let empty = RenderChain(stages: [], maxFrames: format.maxFrames)
        let (el, er) = render(empty, blocks: 4)
        check(el == sine(block: 3) && er == sine(block: 3), "empty chain passes input through bit-exactly")

        func exercise(_ label: String, _ units: [AUAudioUnit]) {
            let chain = RenderChain(stages: units.map { (slotID: UUID(), unit: $0) }, maxFrames: format.maxFrames)
            let (l, r) = render(chain, blocks: 4)
            check(l != sine(block: 3), "\(label): output differs from input")
            check((l + r).allSatisfy(\.isFinite), "\(label): output is finite")
            check(chain.failedSlotIDs().isEmpty, "\(label): no render errors")
        }
        exercise("one stage", [delayPlugin.unit])
        exercise("two stages", [delayPlugin.unit, eqPlugin.unit])

        let full = RenderChain(stages: [(slotID: UUID(), unit: delayPlugin.unit)], maxFrames: format.maxFrames)
        let (fl, _) = render(full, blocks: 1, frames: format.maxFrames)
        check(fl.count == format.maxFrames && fl.allSatisfy(\.isFinite), "renders a full maxFrames block")

        // State capture and restore, through AUDelay's wet/dry mix (parameter address 0).
        guard let mix = delayPlugin.unit.parameterTree?.parameter(withAddress: 0) else {
            check(false, "AUDelay exposes wet/dry mix at address 0")
            return
        }
        let before = mix.value
        let original = delayPlugin.captureState()
        check(original != nil, "state can be captured")
        mix.value = before == 100 ? 0 : 100
        check(delayPlugin.captureState() != original, "captured state reflects a parameter change")
        if let original { try delayPlugin.restoreState(original) }
        check(abs(mix.value - before) < 0.001, "restoring state brings the parameter back")
        check((try? delayPlugin.restoreState(Data("not a plist".utf8))) == nil, "unreadable state is rejected")
    }

    static var eqPluginState: Data?

    static func runnerChecks(_ check: (Bool, String) -> Void) throws {
        let runner = ChainRunner()
        runner.setFormat(RenderFormat(sampleRate: sampleRate, maxFrames: 4096))

        var chain = Chain()
        let delaySlot = chain.add(component: delay, name: "AUDelay", manufacturer: "Apple")
        chain.add(component: eq, name: "AUNBandEQ", manufacturer: "Apple")
        let missing = chain.add(component: ComponentID("aufx", "zzzz", "zzzz")!, name: "Missing", manufacturer: "Nobody")
        let garbled = chain.add(component: delay, name: "AUDelay (bad state)", manufacturer: "Apple")
        chain.setState(Data("not a plist".utf8), id: garbled.id)

        runner.sync(to: chain)
        check(spin { !runner.isLoading }, "runner finishes loading")
        check(runner.error(for: missing.id) != nil, "a missing plugin is flagged, not fatal")
        check(runner.componentFailures[missing.component] != nil, "a failed component is remembered for the picker")
        check(runner.plugin(for: garbled.id) != nil && runner.error(for: garbled.id) == nil,
              "unreadable saved state falls back to the plugin's defaults")
        check(runner.activeCount == 3, "the three loadable effects run")

        chain.setBypassed(true, id: delaySlot.id)
        runner.sync(to: chain)
        check(runner.activeCount == 2, "a bypassed slot is left out")

        chain.masterBypass = true
        runner.sync(to: chain)
        check(runner.activeCount == 0, "master bypass runs no effects")
        if let raw = runner.source.load() {
            let live = Unmanaged<RenderChain>.fromOpaque(raw).takeUnretainedValue()
            check(render(live, blocks: 2).0 == sine(block: 1), "master bypass passes audio through")
        } else {
            check(false, "a snapshot is published")
        }

        chain.masterBypass = false
        chain.remove(id: delaySlot.id)
        runner.sync(to: chain)
        check(runner.plugin(for: delaySlot.id) == nil, "a removed slot's plugin is released")
        check(runner.retiredCount > 0, "replaced snapshots are retired, not freed at once")
        runner.tick(now: Date().addingTimeInterval(ChainRunner.retireDelay + 1))
        check(runner.retiredCount == 0, "retired snapshots are freed after the delay")

        eqPluginState = runner.plugin(for: garbled.id).flatMap { _ in try? loadSync(eq).captureState() }
        runner.setFormat(RenderFormat(sampleRate: 44_100, maxFrames: 4096))
        check(runner.plugin(for: garbled.id)?.preparedFormat?.sampleRate == 44_100,
              "a format change re-prepares loaded plugins")

        let guarded = ChainRunner()
        guarded.setFormat(RenderFormat(sampleRate: sampleRate, maxFrames: 4096))
        var loads: [ComponentID] = []
        guarded.isDisabled = { $0 == eq }
        guarded.willStep = { id, step in if step == .load { loads.append(id) } }
        var blocked = Chain()
        let eqSlot = blocked.add(component: eq, name: "AUNBandEQ", manufacturer: "Apple")
        blocked.add(component: delay, name: "AUDelay", manufacturer: "Apple")
        guarded.sync(to: blocked)
        check(spin { !guarded.isLoading }, "a chain with a disabled plugin finishes loading")
        check(!loads.contains(eq) && Set(loads) == [delay], "a disabled plugin is never loaded")
        check(guarded.error(for: eqSlot.id) == ChainRunner.disabledMessage, "a disabled plugin's slot says why")
        check(guarded.activeCount == 1, "the rest of the chain still runs")
        guarded.isDisabled = { _ in false }
        guarded.forgetDisabled(eq)
        guarded.sync(to: blocked)
        check(spin { !guarded.isLoading }, "a re-enabled plugin loads")
        check(guarded.error(for: eqSlot.id) == nil && guarded.activeCount == 2, "a re-enabled plugin rejoins the chain")

        // No plugin renders while another is mid-load at launch, so a render crash can
        // never be blamed on the plugin that happened to be loading.
        let serial = ChainRunner()
        serial.setFormat(RenderFormat(sampleRate: sampleRate, maxFrames: 4096))
        var liveDuringLoad: [Int] = []
        var steps: [CrashBlame.Step] = []
        serial.willStep = { _, step in
            steps.append(step)
            if step == .load { liveDuringLoad.append(serial.activeCount) }
        }
        var three = Chain()
        three.add(component: delay, name: "AUDelay", manufacturer: "Apple")
        let eqWithState = three.add(component: eq, name: "AUNBandEQ", manufacturer: "Apple")
        three.add(component: delay, name: "AUDelay 2", manufacturer: "Apple")
        if let state = eqPluginState { three.setState(state, id: eqWithState.id) }
        serial.sync(to: three)
        check(serial.activeCount == 0, "nothing renders while the chain is still loading")
        check(spin { !serial.isLoading }, "a three-plugin chain finishes loading")
        check(liveDuringLoad.allSatisfy { $0 == 0 }, "no effect is live while a later plugin loads")
        check(serial.activeCount == 3, "the whole chain goes live once loading finishes")
        check(steps.contains(.restore), "restoring saved settings is marked as its own step")

        // A retired snapshot outlives any audio cycle that began before the swap.
        let cycles = ChainRunner()
        cycles.setFormat(RenderFormat(sampleRate: sampleRate, maxFrames: 4096))
        cycles.sync(to: Chain())
        cycles.tick(now: Date().addingTimeInterval(ChainRunner.retireDelay + 1))
        cycles.source.beginCycle()                      // the audio thread is mid-cycle…
        var one = Chain()
        one.masterBypass = true
        cycles.sync(to: one)                            // …when a new snapshot is swapped in
        cycles.tick(now: Date().addingTimeInterval(ChainRunner.retireDelay + 1))
        check(cycles.retiredCount > 0, "a snapshot in use by an unfinished cycle is not freed")
        cycles.source.endCycle()
        cycles.tick(now: Date().addingTimeInterval(ChainRunner.retireDelay + 1))
        check(cycles.retiredCount == 0, "it is freed once that cycle finishes")

        // Render errors are recoverable.
        let recover = ChainRunner()
        recover.setFormat(RenderFormat(sampleRate: sampleRate, maxFrames: 4096))
        var solo = Chain()
        let soloSlot = solo.add(component: delay, name: "AUDelay", manufacturer: "Apple")
        recover.sync(to: solo)
        _ = spin { !recover.isLoading }
        recover.recordRenderFailure(soloSlot.id)
        check(recover.error(for: soloSlot.id) != nil && recover.activeCount == 0, "a render error takes the slot out")
        solo.setBypassed(true, id: soloSlot.id); recover.sync(to: solo)
        solo.setBypassed(false, id: soloSlot.id); recover.sync(to: solo)
        check(recover.error(for: soloSlot.id) == nil && recover.activeCount == 1, "bypassing and re-enabling the slot retries it")
        recover.recordRenderFailure(soloSlot.id)
        recover.clearErrors()
        recover.sync(to: solo)
        _ = spin { !recover.isLoading }
        check(recover.error(for: soloSlot.id) == nil && recover.activeCount == 1, "Retry clears render errors")
    }

    // MARK: Helpers (also used by later self-tests)

    /// Loads a plugin, spinning the main run loop until `LoadedPlugin.load` completes.
    static func loadSync(_ id: ComponentID, timeout: TimeInterval = 10) throws -> LoadedPlugin {
        var result: Result<LoadedPlugin, Error>?
        LoadedPlugin.load(id) { result = $0 }
        _ = spin(timeout: timeout) { result != nil }
        guard let result else { throw PluginError.instantiate("timed out loading \(id.fourCC)") }
        return try result.get()
    }

    /// Runs the main run loop until `condition` holds or `timeout` passes. Returns whether it held.
    @discardableResult
    static func spin(timeout: TimeInterval = 10, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    /// Feeds `blocks` consecutive sine blocks through `chain`; returns the last block's output.
    static func render(_ chain: RenderChain, blocks: Int, frames: Int = blockFrames) -> ([Float], [Float]) {
        var timestamp = AudioTimeStamp()
        timestamp.mFlags = .sampleTimeValid
        var result: ([Float], [Float]) = ([], [])
        for block in 0..<blocks {
            let input = sine(block: block, frames: frames)
            chain.inputLeft.update(from: input, count: frames)
            chain.inputRight.update(from: input, count: frames)
            timestamp.mSampleTime = Double(block * frames)
            let out = withUnsafePointer(to: timestamp) { chain.process(frames: frames, timestamp: $0) }
            result = (Array(UnsafeBufferPointer(start: out.left, count: frames)),
                      Array(UnsafeBufferPointer(start: out.right, count: frames)))
        }
        return result
    }

    /// Block `block` of a continuous 1 kHz sine at half scale.
    static func sine(block: Int, frames: Int = blockFrames) -> [Float] {
        (0..<frames).map { i in
            Float(0.5 * sin(2 * Double.pi * 1000 * Double(block * frames + i) / sampleRate))
        }
    }
}
