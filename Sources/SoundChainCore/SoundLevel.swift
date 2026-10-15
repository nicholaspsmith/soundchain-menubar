// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import Foundation

/// How loud SoundChain's output is, as the drive Carol walks to: the audio
/// thread measures each cycle's `rms`, the main thread turns the loudest of
/// them into a `drive`.
public enum SoundLevel {
    /// RMS in dBFS at or below which she stands: very quiet, well above silence and dither.
    public static let floor: Float = -42
    /// RMS in dBFS at or above which she walks at full stride. Tuned on music through a
    /// limited chain, whose output ran -30 to -21 dBFS (10th to 90th percentile, 42 ms
    /// windows), so that it spans most of her range; louder masters reach full stride.
    public static let ceiling: Float = -18

    /// The RMS of both channels over the first `frames` samples. Audio-thread safe.
    public static func rms(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int) -> Float {
        guard frames > 0 else { return 0 }
        var sum: Float = 0
        for frame in 0..<frames { sum += left[frame] * left[frame] + right[frame] * right[frame] }
        return (sum / Float(2 * frames)).squareRoot()
    }

    /// 0 at `floor` dBFS or below, 1 at `ceiling` or above, even in decibels between.
    public static func drive(rms: Float) -> Double {
        guard rms > 0 else { return 0 }
        let dB = 20 * log10(rms)
        return Double(max(0, min(1, (dB - floor) / (ceiling - floor))))
    }
}

/// The drive as it was a moment ago: the output is heard its latency after
/// SoundChain writes it (a few ms wired, a few hundred over Bluetooth), so
/// Carol moves to what was measured that long before.
public struct LevelDelay {
    /// Samples kept: over a second at 24 a second.
    public static let capacity = 32
    private(set) var samples: [(time: Double, value: Double)] = []

    public init() {}

    /// Records `value`, measured at `time` (which only goes forward).
    public mutating func push(_ value: Double, at time: Double) {
        samples.append((time, value))
        if samples.count > Self.capacity { samples.removeFirst(samples.count - Self.capacity) }
    }

    /// The newest value measured at or before `time`; 0 when there is none.
    public func value(at time: Double) -> Double {
        samples.last { $0.time <= time }?.value ?? 0
    }
}
