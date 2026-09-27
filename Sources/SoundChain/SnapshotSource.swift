// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import CAtomics
import Foundation

/// The one atomic pointer the IO proc reads the current RenderChain from.
/// The cell holds a +1 retain on the published snapshot.
struct SnapshotSource {
    let cell: OpaquePointer
    /// IO cycles begun and finished, so a retired snapshot is only freed once every
    /// cycle that could have loaded it has returned (see ChainRunner.tick).
    let begun: OpaquePointer
    let finished: OpaquePointer

    static func make() -> SnapshotSource {
        SnapshotSource(cell: sc_atomic_ptr_create(), begun: sc_counter_create(), finished: sc_counter_create())
    }

    /// Audio thread: bracket every IO cycle.
    @inline(__always) func beginCycle() { sc_counter_increment(begun) }
    @inline(__always) func endCycle() { sc_counter_increment(finished) }
    var cyclesBegun: Int64 { sc_counter_get(begun) }
    var cyclesFinished: Int64 { sc_counter_get(finished) }

    /// Audio thread: the published snapshot, unretained, or nil.
    @inline(__always)
    func load() -> UnsafeMutableRawPointer? { sc_atomic_ptr_load(cell) }

    /// Main thread: publishes `chain` and hands back the previous snapshot (with
    /// ownership). The caller must keep the old one alive until the audio thread
    /// can no longer be using it (ChainRunner.retireDelay).
    func swap(_ chain: RenderChain?) -> RenderChain? {
        let new = chain.map { Unmanaged.passRetained($0).toOpaque() }
        guard let old = sc_atomic_ptr_exchange(cell, new) else { return nil }
        return Unmanaged<RenderChain>.fromOpaque(old).takeRetainedValue()
    }
}
