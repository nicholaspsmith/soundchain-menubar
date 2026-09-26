// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import CAtomics
import XCTest

final class AtomicsTests: XCTestCase {
    func testPointerStartsNilAndExchangeReturnsPrevious() {
        let cell = sc_atomic_ptr_create()
        defer { sc_atomic_ptr_destroy(cell) }
        XCTAssertNil(sc_atomic_ptr_load(cell))
        let a = UnsafeMutableRawPointer(bitPattern: 0x1000)!
        let b = UnsafeMutableRawPointer(bitPattern: 0x2000)!
        XCTAssertNil(sc_atomic_ptr_exchange(cell, a))
        XCTAssertEqual(sc_atomic_ptr_load(cell), a)
        XCTAssertEqual(sc_atomic_ptr_exchange(cell, b), a)
        XCTAssertEqual(sc_atomic_ptr_exchange(cell, nil), b)
    }

    func testFlagsSetGetAndIgnoreOutOfRange() {
        let flags = sc_flags_create(3)
        defer { sc_flags_destroy(flags) }
        XCTAssertEqual(sc_flags_get(flags, 1), 0)
        sc_flags_set(flags, 1)
        sc_flags_set(flags, 7)
        sc_flags_set(flags, -1)
        XCTAssertEqual(sc_flags_get(flags, 0), 0)
        XCTAssertEqual(sc_flags_get(flags, 1), 1)
        XCTAssertEqual(sc_flags_get(flags, 7), 0)
    }

    func testZeroFlagsIsSafe() {
        let flags = sc_flags_create(0)
        defer { sc_flags_destroy(flags) }
        sc_flags_set(flags, 0)
        XCTAssertEqual(sc_flags_get(flags, 0), 0)
    }

    func testCounterCounts() {
        let counter = sc_counter_create()
        defer { sc_counter_destroy(counter) }
        for _ in 0..<5 { sc_counter_increment(counter) }
        XCTAssertEqual(sc_counter_get(counter), 5)
    }
}
