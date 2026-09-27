// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import CoreAudio

/// Spots an output SoundChain is following that you probably cannot hear. A virtual
/// device (BlackHole, Zoom's, a driver an uninstalled app left behind) has no
/// speakers of its own, and macOS can fall back to one when headphones disconnect.
public enum OutputCheck {
    /// The menu line for an output with this transport type, or nil if it is a real one.
    public static func warning(transportType: UInt32) -> String? {
        transportType == kAudioDeviceTransportTypeVirtual ? "⚠ Virtual output: may be silent" : nil
    }
}
