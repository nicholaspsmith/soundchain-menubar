// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import AudioToolbox
import CAtomics
import Foundation

/// An immutable snapshot of the chain as the audio thread runs it: the enabled
/// plugins in order, with every buffer allocated up front. The main thread builds a
/// new one for every change and swaps it in (SnapshotSource); nothing here is ever
/// mutated from the main thread after init.
///
/// Buffers: two stereo pairs, A (index 0) and B (index 1). The tap's audio is copied
/// into A; each stage reads the current pair through the pull block and writes the
/// other, so the chain ping-pongs without copying.
final class RenderChain {
    let maxFrames: Int
    let slotIDs: [UUID]
    let inputLeft: UnsafeMutablePointer<Float>
    let inputRight: UnsafeMutablePointer<Float>

    private let units: [AUAudioUnit]                                   // keeps plugins alive
    private let renderBlocks: ContiguousArray<AURenderBlock>
    private let buffers: UnsafeMutablePointer<UnsafeMutablePointer<Float>>  // A.L, A.R, B.L, B.R
    private let source: UnsafeMutablePointer<Int>                      // pair the pull block reads
    private let outList: UnsafeMutableAudioBufferListPointer
    private let failed: OpaquePointer                                  // sc_flags, one per stage
    /// What each plugin calls for its input. Internal for --selftest.
    let pull: AURenderPullInputBlock

    init(stages: [(slotID: UUID, unit: AUAudioUnit)], maxFrames: Int) {
        let buffers = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 4)
        for i in 0..<4 {
            buffers[i] = .allocate(capacity: maxFrames)
            buffers[i].initialize(repeating: 0, count: maxFrames)
        }
        let source = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        source.initialize(to: 0)

        self.maxFrames = maxFrames
        slotIDs = stages.map(\.slotID)
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
        source.deallocate()
        free(outList.unsafeMutablePointer)
        sc_flags_destroy(failed)
    }

    var stageCount: Int { renderBlocks.count }

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
            current = target
        }
        return (buffers[current * 2], buffers[current * 2 + 1])
    }

    /// Slots whose plugin returned a render error in this snapshot. Main thread.
    func failedSlotIDs() -> [UUID] {
        slotIDs.indices.filter { sc_flags_get(failed, Int32($0)) != 0 }.map { slotIDs[$0] }
    }
}
