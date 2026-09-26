// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import XCTest
@testable import SoundChainCore

final class SampleGuardTests: XCTestCase {
    func testFiniteSamplesAreLeftAlone() {
        let l = Floats([0.1, -0.2]), r = Floats([0.3, 1.5])
        XCTAssertFalse(SampleGuard.sanitize(left: l.pointer, right: r.pointer, frames: 2))
        XCTAssertEqual(l.array, [0.1, -0.2])
        XCTAssertEqual(r.array, [0.3, 1.5])
    }

    func testNaNZeroesBothChannels() {
        let l = Floats([0.1, 0.2]), r = Floats([.nan, 0.3])
        XCTAssertTrue(SampleGuard.sanitize(left: l.pointer, right: r.pointer, frames: 2))
        XCTAssertEqual(l.array, [0, 0])
        XCTAssertEqual(r.array, [0, 0])
    }

    func testInfinityZeroesBothChannels() {
        let l = Floats([0.1, -.infinity]), r = Floats([0.2, 0.3])
        XCTAssertTrue(SampleGuard.sanitize(left: l.pointer, right: r.pointer, frames: 2))
        XCTAssertEqual(l.array + r.array, [0, 0, 0, 0])
    }

    func testOnlyTheRenderedFramesAreChecked() {
        let l = Floats([0.1, .nan]), r = Floats([0.2, 0.3])
        XCTAssertFalse(SampleGuard.sanitize(left: l.pointer, right: r.pointer, frames: 1))
    }
}
