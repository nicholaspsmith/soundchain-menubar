// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

/// Whether sound is passing through SoundChain, for Carol to walk while it is.
/// The audio thread counts the cycles that carry sound (`isAudible`); the main
/// thread asks whether that count has moved lately (`update`).
public struct SoundActivity {
    /// A cycle is sound if any sample reaches this: -60 dBFS, above dither and
    /// a quiet device's noise floor.
    public static let threshold: Float = 0.001
    /// How long she keeps walking after the last sound, so a gap between
    /// tracks does not stop her.
    public static let hold: Double = 1.5

    private var lastCount: Int64?
    private var lastSound: Double?

    public init() {}

    /// `count` is the audible cycles so far, `now` a monotonic clock in seconds.
    /// The first call only learns the count, since it cannot tell when those
    /// cycles were.
    public mutating func update(count: Int64, now: Double) -> Bool {
        if let lastCount, count != lastCount { lastSound = now }
        lastCount = count
        guard let lastSound else { return false }
        return now - lastSound < Self.hold
    }

    /// Whether any of the first `frames` samples in either channel reaches
    /// `threshold`. Audio-thread safe; stops at the first one.
    public static func isAudible(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int) -> Bool {
        for frame in 0..<frames where abs(left[frame]) >= threshold || abs(right[frame]) >= threshold {
            return true
        }
        return false
    }
}
