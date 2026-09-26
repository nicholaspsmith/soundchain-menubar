// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

/// Protects speakers and ears from a misbehaving plugin. Audio-thread safe.
public enum SampleGuard {
    /// If any of the first `frames` samples in either channel is NaN or infinite,
    /// zeroes both channels and returns true.
    @discardableResult
    public static func sanitize(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>,
                                frames: Int) -> Bool {
        for frame in 0..<frames where !left[frame].isFinite || !right[frame].isFinite {
            left.update(repeating: 0, count: frames)
            right.update(repeating: 0, count: frames)
            return true
        }
        return false
    }
}
