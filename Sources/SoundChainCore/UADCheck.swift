// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import Foundation

/// Spots UAD-2 plugins that cannot run. They need the DSP inside an Apollo or UAD-2
/// card; with none attached (or once it is unplugged) SoundChain pauses them, taking
/// them out of the chain until it returns. Native UADx plugins (same manufacturer
/// code) run on the Mac.
public enum UADCheck {
    static let manufacturer = ComponentID.code("!UAD")!

    public static func needsHardware(_ slot: ChainSlot) -> Bool {
        slot.component.manufacturer == manufacturer && !slot.name.hasPrefix("UADx")
    }

    /// The enabled slots paused for want of UAD hardware.
    public static func idleSlots(in chain: Chain, hardwarePresent: Bool) -> [ChainSlot] {
        guard !hardwarePresent, !chain.masterBypass else { return [] }
        return chain.slots.filter { !$0.bypassed && needsHardware($0) }
    }

    /// The menu line for those slots, or nil if there are none.
    public static func warning(chain: Chain, hardwarePresent: Bool) -> String? {
        let count = idleSlots(in: chain, hardwarePresent: hardwarePresent).count
        guard count > 0 else { return nil }
        return "⚠ No UAD hardware: \(count) paused"
    }

    /// The row detail for one of those slots in the chain window.
    public static let rowNote = "Paused: needs UAD hardware (Apollo or UAD-2)"
}
