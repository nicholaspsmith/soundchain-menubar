// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import XCTest
@testable import SoundChainCore

final class CrossfadeTests: XCTestCase {
    func testIdleUntilStarted() {
        var fade = Crossfade(length: 8)
        XCTAssertFalse(fade.isActive)
        fade.start()
        XCTAssertTrue(fade.isActive)
        fade.cancel()
        XCTAssertFalse(fade.isActive)
    }

    func testRampsFromOldToNewAcrossBlocks() {
        var fade = Crossfade(length: 4)
        fade.start()
        let old = Floats([1, 1, 1, 1, 1, 1]), new = Floats([0, 0, 0, 0, 0, 0])
        let oldR = Floats([1, 1, 1, 1, 1, 1]), newR = Floats([0, 0, 0, 0, 0, 0])
        // Two frames per block: the ramp carries on where it left off.
        fade.mix(fromLeft: old.pointer, fromRight: oldR.pointer, intoLeft: new.pointer, intoRight: newR.pointer, frames: 2)
        XCTAssertEqual(new.array.prefix(2).map { $0 }, [0.75, 0.5])
        XCTAssertTrue(fade.isActive)
        fade.mix(fromLeft: old.pointer + 2, fromRight: oldR.pointer + 2,
                 intoLeft: new.pointer + 2, intoRight: newR.pointer + 2, frames: 4)
        XCTAssertEqual(new.array, [0.75, 0.5, 0.25, 0, 0, 0])
        XCTAssertEqual(newR.array, [0.75, 0.5, 0.25, 0, 0, 0])
        XCTAssertFalse(fade.isActive)
    }

    func testIdenticalSignalsPassUnchanged() {
        var fade = Crossfade(length: 3)
        fade.start()
        let old = Floats([0.5, -0.25, 0.125]), new = Floats([0.5, -0.25, 0.125])
        let r = Floats(zeros: 3), r2 = Floats(zeros: 3)
        fade.mix(fromLeft: old.pointer, fromRight: r.pointer, intoLeft: new.pointer, intoRight: r2.pointer, frames: 3)
        XCTAssertEqual(new.array, [0.5, -0.25, 0.125])
    }

    func testNothingHappensWhenIdle() {
        var fade = Crossfade(length: 3)
        let old = Floats([1, 1, 1]), new = Floats([0, 0, 0]), r = Floats(zeros: 3), r2 = Floats(zeros: 3)
        fade.mix(fromLeft: old.pointer, fromRight: r.pointer, intoLeft: new.pointer, intoRight: r2.pointer, frames: 3)
        XCTAssertEqual(new.array, [0, 0, 0])
    }

    func testLengthFromSampleRate() {
        XCTAssertEqual(Crossfade(sampleRate: 48_000).length, 1920)
        XCTAssertEqual(Crossfade(sampleRate: 44_100, duration: 0.01).length, 441)
        XCTAssertEqual(Crossfade(length: 0).length, 1)
    }
}
