// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import AudioToolbox
import CAtomics
import Foundation
import SoundChainCore

/// An immutable snapshot of the chain as the audio thread runs it: the enabled
/// plugins in order, with every buffer allocated up front. The main thread builds a
/// new one for every change and swaps it in (SnapshotSource); nothing here is ever
/// mutated from the main thread after init.
///
/// Buffers: two stereo pairs, A (index 0) and B (index 1). The tap's audio is copied
/// into A; each stage reads the current pair through the pull block and writes the
/// other, so the chain ping-pongs without copying.
///
/// A stage that has just been switched on ramps in: its output is crossfaded over
/// its input for the first `rampFrames`, since a plugin resuming with stale history
/// and its own latency would otherwise click. A stage just switched off stays in
/// this one snapshot to ramp out the same way, and is skipped once it has.
final class RenderChain {
    enum Ramp {
        case none, `in`, out
    }

    typealias Stage = (slotID: UUID, unit: AUAudioUnit, ramp: Ramp)

    let maxFrames: Int
    /// The stages that are on (not ramping out), in order.
    let slotIDs: [UUID]
    let inputLeft: UnsafeMutablePointer<Float>
    let inputRight: UnsafeMutablePointer<Float>

    private let allSlotIDs: [UUID]
    private let ramps: [Ramp]
    private let fades: UnsafeMutablePointer<Crossfade>                 // one per stage, audio thread's
    private let units: [AUAudioUnit]                                   // keeps plugins alive
    private let renderBlocks: ContiguousArray<AURenderBlock>
    private let buffers: UnsafeMutablePointer<UnsafeMutablePointer<Float>>  // A.L, A.R, B.L, B.R
    private let source: UnsafeMutablePointer<Int>                      // pair the pull block reads
    private let outList: UnsafeMutableAudioBufferListPointer
    private let failed: OpaquePointer                                  // sc_flags, one per stage
    /// What each plugin calls for its input. Internal for --selftest.
    let pull: AURenderPullInputBlock

    convenience init(stages: [(slotID: UUID, unit: AUAudioUnit)], maxFrames: Int) {
        self.init(stages: stages.map { (slotID: $0.slotID, unit: $0.unit, ramp: .none) }, maxFrames: maxFrames,
                  rampFrames: 0)
    }

    init(stages: [Stage], maxFrames: Int, rampFrames: Int) {
        let buffers = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 4)
        for i in 0..<4 {
            buffers[i] = .allocate(capacity: maxFrames)
            buffers[i].initialize(repeating: 0, count: maxFrames)
        }
        let source = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        source.initialize(to: 0)

        self.maxFrames = maxFrames
        allSlotIDs = stages.map(\.slotID)
        slotIDs = stages.filter { $0.ramp != .out }.map(\.slotID)
        ramps = stages.map(\.ramp)
        fades = .allocate(capacity: max(stages.count, 1))
        for (i, stage) in stages.enumerated() {
            var fade = Crossfade(length: rampFrames)
            if stage.ramp != .none { fade.start() }
            (fades + i).initialize(to: fade)
        }
        units = stages.map(\.unit)
        renderBlocks = ContiguousArray(stages.map { $0.unit.renderBlock })
        self.buffers = buffers
        self.source = source
        inputLeft = buffers[0]
        inputRight = buffers[1]
        outList = AudioBufferList.allocate(maximumBuffers: 2)
        failed = sc_flags_create(Int32(stages.count))

        // Captures only raw pointers and an Int, so calling it on the audio thread
        // touches no refcounts. A plugin asking for more than `maxFrames` would read
        // past the buffers; it gets an error instead.
        pull = { _, _, frameCount, _, ioData in
            guard Int(frameCount) <= maxFrames else { return kAudioUnitErr_TooManyFramesToProcess }
            let list = UnsafeMutableAudioBufferListPointer(ioData)
            let byteCount = Int(frameCount) * MemoryLayout<Float>.size
            let base = source.pointee * 2
            for i in 0..<min(list.count, 2) {
                let from = UnsafeMutableRawPointer(buffers[base + i])
                if let to = list[i].mData {
                    if to != from { to.copyMemory(from: from, byteCount: byteCount) }
                } else {
                    list[i].mData = from
                }
                list[i].mDataByteSize = UInt32(byteCount)
            }
            return noErr
        }
    }

    deinit {
        for i in 0..<4 { buffers[i].deallocate() }
        buffers.deallocate()
        fades.deallocate()
        source.deallocate()
        free(outList.unsafeMutablePointer)
        sc_flags_destroy(failed)
    }

    /// Stages that are on (not ramping out).
    var stageCount: Int { slotIDs.count }

    /// Runs the chain over `frames` frames already in `inputLeft`/`inputRight` and
    /// returns the pair holding the result. A stage that returns an error is flagged
    /// and skipped from then on; its output is discarded. Audio-thread safe.
    func process(frames: Int, timestamp: UnsafePointer<AudioTimeStamp>)
        -> (left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        guard frames > 0, frames <= maxFrames else { return (buffers[0], buffers[1]) }
        let byteCount = UInt32(frames * MemoryLayout<Float>.size)
        var current = 0
        for stage in 0..<renderBlocks.count {
            if sc_flags_get(failed, Int32(stage)) != 0 { continue }
            let ramp = ramps[stage]
            if ramp == .out, !fades[stage].isActive { continue }        // faded out: bypassed now
            let target = 1 - current
            let dstL = buffers[target * 2], dstR = buffers[target * 2 + 1]
            outList[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: byteCount, mData: UnsafeMutableRawPointer(dstL))
            outList[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: byteCount, mData: UnsafeMutableRawPointer(dstR))
            source.pointee = current
            var flags = AudioUnitRenderActionFlags()
            let status = renderBlocks[stage](&flags, timestamp, AUAudioFrameCount(frames), 0,
                                             outList.unsafeMutablePointer, pull)
            if status == kAudioUnitErr_CannotDoInCurrentContext { continue }   // "try again later": skip this cycle
            if status != noErr {
                sc_flags_set(failed, Int32(stage))
                continue
            }
            // A plugin may point the list at its own buffers instead of filling ours.
            if let l = outList[0].mData, l != UnsafeMutableRawPointer(dstL) {
                dstL.update(from: l.assumingMemoryBound(to: Float.self), count: frames)
            }
            if let r = outList[1].mData, r != UnsafeMutableRawPointer(dstR) {
                dstR.update(from: r.assumingMemoryBound(to: Float.self), count: frames)
            }
            let srcL = buffers[current * 2], srcR = buffers[current * 2 + 1]
            switch ramp {
            case .none:
                current = target
            case .in:
                // Wet ramps in over dry; the wet pair carries on.
                fades[stage].mix(fromLeft: srcL, fromRight: srcR, intoLeft: dstL, intoRight: dstR, frames: frames)
                current = target
            case .out:
                // Dry ramps in over wet, written back to the dry pair, which carries on.
                fades[stage].mix(fromLeft: dstL, fromRight: dstR, intoLeft: srcL, intoRight: srcR, frames: frames)
            }
        }
        return (buffers[current * 2], buffers[current * 2 + 1])
    }

    /// Slots whose plugin returned a render error in this snapshot, among the stages
    /// that are on. Main thread.
    func failedSlotIDs() -> [UUID] {
        allSlotIDs.indices.filter { ramps[$0] != .out && sc_flags_get(failed, Int32($0)) != 0 }.map { allSlotIDs[$0] }
    }
}
