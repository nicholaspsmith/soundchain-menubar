// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import CoreAudio
import Foundation

/// Writes the processed stereo signal into whatever stream layout the output device has.
/// Audio-thread safe: no allocation, no locks.
public enum ChannelMap {
    /// Channel 1 gets left and channel 2 gets right, counting channels across buffers
    /// in order; every other channel is zeroed. A device with a single channel gets
    /// (L+R)/2. Frames beyond `frames` in each buffer are zeroed.
    public static func write(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int,
                             to output: UnsafeMutableAudioBufferListPointer) {
        var totalChannels = 0
        for b in 0..<output.count { totalChannels += Int(output[b].mNumberChannels) }

        var firstChannel = 0
        for b in 0..<output.count {
            let buffer = output[b]
            let channels = Int(buffer.mNumberChannels)
            if channels > 0, let data = buffer.mData {
                let destination = data.assumingMemoryBound(to: Float.self)
                let capacity = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
                let rendered = min(frames, capacity)
                for c in 0..<channels {
                    let channel = firstChannel + c
                    for frame in 0..<capacity {
                        let value: Float
                        if frame >= rendered {
                            value = 0
                        } else if totalChannels == 1 {
                            value = (left[frame] + right[frame]) * 0.5
                        } else if channel == 0 {
                            value = left[frame]
                        } else if channel == 1 {
                            value = right[frame]
                        } else {
                            value = 0
                        }
                        destination[frame * channels + c] = value
                    }
                }
            }
            firstChannel += channels
        }
    }

    public static func zero(_ output: UnsafeMutableAudioBufferListPointer) {
        for b in 0..<output.count {
            if let data = output[b].mData { memset(data, 0, Int(output[b].mDataByteSize)) }
        }
    }
}
