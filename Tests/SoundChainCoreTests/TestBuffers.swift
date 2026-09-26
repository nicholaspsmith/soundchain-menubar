// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import CoreAudio
import Foundation

/// Owns an AudioBufferList whose buffers have the given channel counts, each `frames` long, zero-filled.
final class TestABL {
    let list: UnsafeMutableAudioBufferListPointer

    init(frames: Int, layout: [Int]) {
        // allocate(maximumBuffers:) traps on 0, so allocate one and set the real count.
        list = AudioBufferList.allocate(maximumBuffers: max(layout.count, 1))
        list.count = layout.count
        for (i, channels) in layout.enumerated() {
            let bytes = frames * channels * MemoryLayout<Float>.size
            let data = UnsafeMutableRawPointer.allocate(byteCount: max(bytes, 1), alignment: 16)
            data.initializeMemory(as: UInt8.self, repeating: 0, count: max(bytes, 1))
            list[i] = AudioBuffer(mNumberChannels: UInt32(channels), mDataByteSize: UInt32(bytes), mData: data)
        }
    }

    func samples(_ buffer: Int) -> UnsafeMutablePointer<Float> {
        list[buffer].mData!.assumingMemoryBound(to: Float.self)
    }

    func array(_ buffer: Int) -> [Float] {
        let count = Int(list[buffer].mDataByteSize) / MemoryLayout<Float>.size
        return Array(UnsafeBufferPointer(start: samples(buffer), count: count))
    }

    func fill(_ buffer: Int, _ values: [Float]) {
        for (i, v) in values.enumerated() { samples(buffer)[i] = v }
    }

    deinit {
        for buffer in list { buffer.mData?.deallocate() }
        free(list.unsafeMutablePointer)
    }
}

/// A heap float array for the left/right destinations.
final class Floats {
    let pointer: UnsafeMutablePointer<Float>
    let count: Int
    init(_ values: [Float]) {
        count = values.count
        pointer = .allocate(capacity: max(count, 1))
        pointer.initialize(from: values, count: count)
    }
    convenience init(zeros count: Int) { self.init([Float](repeating: 0, count: count)) }
    var array: [Float] { Array(UnsafeBufferPointer(start: pointer, count: count)) }
    deinit { pointer.deallocate() }
}
