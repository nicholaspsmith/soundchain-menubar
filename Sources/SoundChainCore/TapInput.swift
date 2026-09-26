// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import CoreAudio

/// Pulls the tap's stereo stream out of the aggregate device's input list.
/// Audio-thread safe: no allocation, no locks.
public enum TapInput {
    /// The tap's stream is always last: one interleaved buffer (2 channels, or 1 for a
    /// mono tap, which is duplicated), or two 1-channel buffers when non-interleaved.
    /// Returns the frames copied, or 0 when the list has no tap stream of that shape,
    /// a buffer has no data, or the block is larger than `capacity`.
    public static func read(_ input: UnsafeMutableAudioBufferListPointer, interleaved: Bool,
                            left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>,
                            capacity: Int) -> Int {
        let count = input.count
        guard count > 0 else { return 0 }
        let floatSize = MemoryLayout<Float>.size

        if interleaved {
            let buffer = input[count - 1]
            let channels = Int(buffer.mNumberChannels)
            guard channels >= 1, let data = buffer.mData else { return 0 }
            let frames = Int(buffer.mDataByteSize) / (floatSize * channels)
            guard frames <= capacity else { return 0 }
            let source = data.assumingMemoryBound(to: Float.self)
            for frame in 0..<frames {
                let base = frame * channels
                left[frame] = source[base]
                right[frame] = channels > 1 ? source[base + 1] : source[base]
            }
            return frames
        }

        let leftBuffer = count >= 2 ? input[count - 2] : input[count - 1]
        let rightBuffer = input[count - 1]
        guard leftBuffer.mNumberChannels == 1, rightBuffer.mNumberChannels == 1,
              let leftData = leftBuffer.mData, let rightData = rightBuffer.mData else { return 0 }
        let frames = Int(rightBuffer.mDataByteSize) / floatSize
        guard frames <= capacity, Int(leftBuffer.mDataByteSize) / floatSize == frames else { return 0 }
        left.update(from: leftData.assumingMemoryBound(to: Float.self), count: frames)
        right.update(from: rightData.assumingMemoryBound(to: Float.self), count: frames)
        return frames
    }
}
