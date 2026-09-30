// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import CoreAudio

/// The tap's stream inside the aggregate device's input list: always last, after the
/// output device's own input streams. Either one interleaved buffer of `channels`, or
/// `channels` single-channel buffers. Audio-thread safe: no allocation, no locks.
public struct TapStream {
    public let frames: Int
    public let channels: Int
    private let interleaved: UnsafeMutablePointer<Float>?
    private let firstBuffer: Int
    private let list: UnsafeMutableAudioBufferListPointer

    /// Nil when the list's tail does not have that shape or a buffer has no data.
    public init?(_ list: UnsafeMutableAudioBufferListPointer, interleaved: Bool, channels: Int) {
        let count = list.count
        guard channels >= 1, count > 0 else { return nil }
        let floatSize = MemoryLayout<Float>.size
        self.list = list
        self.channels = channels
        if interleaved {
            let buffer = list[count - 1]
            guard Int(buffer.mNumberChannels) == channels, let data = buffer.mData else { return nil }
            self.interleaved = data.assumingMemoryBound(to: Float.self)
            firstBuffer = count - 1
            frames = Int(buffer.mDataByteSize) / (floatSize * channels)
        } else {
            guard count >= channels else { return nil }
            firstBuffer = count - channels
            let bytes = list[firstBuffer].mDataByteSize
            for b in firstBuffer..<count {
                guard list[b].mNumberChannels == 1, list[b].mData != nil, list[b].mDataByteSize == bytes else { return nil }
            }
            self.interleaved = nil
            frames = Int(bytes) / floatSize
        }
    }

    /// Channel `channel` (0-based, within the tap) of frame `frame`.
    @inline(__always)
    public func sample(_ channel: Int, _ frame: Int) -> Float {
        if let interleaved { return interleaved[frame * channels + channel] }
        return list[firstBuffer + channel].mData!.assumingMemoryBound(to: Float.self)[frame]
    }
}

/// Pulls the stereo pair the chain processes out of the tap.
public enum TapInput {
    /// Copies tap channels `leftChannel` and `rightChannel`. Returns the frames copied,
    /// or 0 when the block is larger than `capacity` or a channel is out of range.
    public static func read(_ stream: TapStream, leftChannel: Int, rightChannel: Int,
                            left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>,
                            capacity: Int) -> Int {
        let range = 0..<stream.channels
        guard stream.frames <= capacity, range.contains(leftChannel), range.contains(rightChannel) else { return 0 }
        for frame in 0..<stream.frames {
            left[frame] = stream.sample(leftChannel, frame)
            right[frame] = stream.sample(rightChannel, frame)
        }
        return stream.frames
    }

    /// A stereo (or mono, duplicated) tap: its first two channels.
    public static func read(_ input: UnsafeMutableAudioBufferListPointer, interleaved: Bool,
                            left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>,
                            capacity: Int) -> Int {
        guard let last = input.last else { return 0 }
        let channels = interleaved ? Int(last.mNumberChannels) : 2
        guard let stream = TapStream(input, interleaved: interleaved, channels: channels) else { return 0 }
        return read(stream, leftChannel: 0, rightChannel: min(1, channels - 1),
                    left: left, right: right, capacity: capacity)
    }
}
