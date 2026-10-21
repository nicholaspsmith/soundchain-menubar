// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import Foundation

/// Every change to the chain (an effect switched on or off, added, moved) swaps in a
/// new snapshot, and the new one's output does not line up with the old one's: a
/// plugin that was off resumes with stale history, and its latency moves the signal.
/// Cut straight across and that is a click. So for a short while after a swap both
/// snapshots run on the same input and the output ramps from the old to the new.
///
/// Plain arithmetic over raw pointers: audio-thread safe, no allocation.
public struct Crossfade {
    /// How long the ramp lasts.
    public static let duration: TimeInterval = 0.04

    /// Frames in the whole ramp.
    public let length: Int
    /// Frames of the ramp already output; `length` when no fade is running.
    public private(set) var position: Int

    public init(length: Int) {
        self.length = max(length, 1)
        position = self.length
    }

    public init(sampleRate: Double, duration: TimeInterval = Crossfade.duration) {
        self.init(length: Int(duration * sampleRate))
    }

    public var isActive: Bool { position < length }

    public mutating func start() { position = 0 }
    public mutating func cancel() { position = length }

    /// Blends `from` (the old snapshot's output) into `into` (the new one's), in
    /// place, for `frames` frames, and advances. Linear: the two are the same audio,
    /// give or take, so a linear ramp keeps the level steady.
    public mutating func mix(fromLeft: UnsafePointer<Float>, fromRight: UnsafePointer<Float>,
                             intoLeft: UnsafeMutablePointer<Float>, intoRight: UnsafeMutablePointer<Float>,
                             frames: Int) {
        guard isActive, frames > 0 else { return }
        let step = 1 / Float(length)
        var gain = Float(position + 1) * step
        let ramp = min(frames, length - position)
        for i in 0..<ramp {
            let old = 1 - gain
            intoLeft[i] = intoLeft[i] * gain + fromLeft[i] * old
            intoRight[i] = intoRight[i] * gain + fromRight[i] * old
            gain += step
        }
        position += ramp
    }
}
