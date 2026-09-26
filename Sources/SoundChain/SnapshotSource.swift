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

    static func make() -> SnapshotSource { SnapshotSource(cell: sc_atomic_ptr_create()) }

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
