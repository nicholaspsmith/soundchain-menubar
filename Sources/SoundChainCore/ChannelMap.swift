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
    /// Writes left and right to `route`'s channels (by default channels 1 and 2, or
    /// (L+R)/2 on a single-channel device), counting channels across buffers in order.
    /// Other channels of the tapped stream get `passthrough`'s samples, so audio apps
    /// sent to them is not lost to the tap's muting; every other channel, and frames
    /// beyond `frames`, are zeroed.
    public static func write(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int,
                             to output: UnsafeMutableAudioBufferListPointer,
                             route: StereoRoute? = nil, passthrough: TapStream? = nil) {
        var totalChannels = 0
        for b in 0..<output.count { totalChannels += Int(output[b].mNumberChannels) }
        let leftChannel = route?.left ?? 0
        let rightChannel = route?.right ?? min(1, totalChannels - 1)
        let tapStart = route?.tapStart ?? 0
        let tapChannels = passthrough == nil ? 0 : min(route?.tapChannels ?? 0, passthrough!.channels)
        let tapFrames = passthrough?.frames ?? 0

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
                    let inTap = channel - tapStart
                    for frame in 0..<capacity {
                        let value: Float
                        if frame >= rendered {
                            value = 0
                        } else if channel == leftChannel && channel == rightChannel {
                            value = (left[frame] + right[frame]) * 0.5
                        } else if channel == leftChannel {
                            value = left[frame]
                        } else if channel == rightChannel {
                            value = right[frame]
                        } else if let passthrough, inTap >= 0, inTap < tapChannels, frame < tapFrames {
                            value = passthrough.sample(inTap, frame)
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
