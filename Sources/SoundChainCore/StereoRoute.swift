// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

/// Where stereo lives on the output device. Apps play into the device's preferred
/// stereo pair (Audio MIDI Setup ▸ Configure Speakers), which is not always channels
/// 1 and 2: an Apollo's is 5 and 6. SoundChain taps the output stream that holds
/// that pair, processes the pair, and writes it back to the same channels.
public struct StereoRoute: Equatable, Sendable {
    /// Output channels, 0-based and counted across all of the device's output buffers.
    public let left: Int
    public let right: Int
    /// The output stream the tap covers, the output channel it starts at, and its width.
    public let tapStream: Int
    public let tapStart: Int
    public let tapChannels: Int

    public init(left: Int, right: Int, tapStream: Int, tapStart: Int, tapChannels: Int) {
        self.left = left
        self.right = right
        self.tapStream = tapStream
        self.tapStart = tapStart
        self.tapChannels = tapChannels
    }

    public var leftInTap: Int { left - tapStart }
    public var rightInTap: Int { right - tapStart }

    /// `preferred` is kAudioDevicePropertyPreferredChannelsForStereo (1-based; 0 or
    /// out of range means unset, which falls back to the first two channels).
    /// `streamChannels` is each output stream's channel count, in order. Both channels
    /// come from one stream; a right channel elsewhere is replaced by the left one's
    /// neighbour, or by the left one itself on a single-channel stream.
    public static func resolve(preferred: [UInt32], streamChannels: [Int]) -> StereoRoute? {
        let total = streamChannels.reduce(0, +)
        guard total > 0 else { return nil }
        let wanted = preferred.first.map { Int($0) - 1 } ?? -1
        let left = (0..<total).contains(wanted) ? wanted : 0

        var start = 0
        var stream = 0
        while left >= start + streamChannels[stream] {
            start += streamChannels[stream]
            stream += 1
        }
        let channels = start..<(start + streamChannels[stream])
        let wantedRight = preferred.count > 1 ? Int(preferred[1]) - 1 : -1
        let right = channels.contains(wantedRight) && wantedRight != left ? wantedRight
            : channels.contains(left + 1) ? left + 1 : left
        return StereoRoute(left: left, right: right, tapStream: stream, tapStart: start,
                           tapChannels: streamChannels[stream])
    }
}
