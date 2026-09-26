// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import CoreAudio
import XCTest
@testable import SoundChainCore

final class TapInputTests: XCTestCase {
    func testInterleavedTapIsTheLastBufferAfterDeviceInputs() {
        let abl = TestABL(frames: 4, layout: [1, 2])      // device mic, then tap
        abl.fill(0, [9, 9, 9, 9])
        abl.fill(1, [1, -1, 2, -2, 3, -3, 4, -4])
        let l = Floats(zeros: 8), r = Floats(zeros: 8)
        XCTAssertEqual(TapInput.read(abl.list, interleaved: true, left: l.pointer, right: r.pointer, capacity: 8), 4)
        XCTAssertEqual(Array(l.array.prefix(4)), [1, 2, 3, 4])
        XCTAssertEqual(Array(r.array.prefix(4)), [-1, -2, -3, -4])
    }

    func testNonInterleavedTapIsTheLastTwoBuffers() {
        let abl = TestABL(frames: 3, layout: [2, 1, 1])   // device stereo input, then tap L, tap R
        abl.fill(1, [1, 2, 3])
        abl.fill(2, [4, 5, 6])
        let l = Floats(zeros: 3), r = Floats(zeros: 3)
        XCTAssertEqual(TapInput.read(abl.list, interleaved: false, left: l.pointer, right: r.pointer, capacity: 3), 3)
        XCTAssertEqual(l.array, [1, 2, 3])
        XCTAssertEqual(r.array, [4, 5, 6])
    }

    func testMonoInterleavedTapIsDuplicated() {
        let abl = TestABL(frames: 2, layout: [1])
        abl.fill(0, [0.5, 0.25])
        let l = Floats(zeros: 2), r = Floats(zeros: 2)
        XCTAssertEqual(TapInput.read(abl.list, interleaved: true, left: l.pointer, right: r.pointer, capacity: 2), 2)
        XCTAssertEqual(l.array, [0.5, 0.25])
        XCTAssertEqual(r.array, [0.5, 0.25])
    }

    func testMoreFramesThanCapacityReadsNothing() {
        let abl = TestABL(frames: 8, layout: [2])
        let l = Floats(zeros: 4), r = Floats(zeros: 4)
        XCTAssertEqual(TapInput.read(abl.list, interleaved: true, left: l.pointer, right: r.pointer, capacity: 4), 0)
        let split = TestABL(frames: 8, layout: [1, 1])   // keep it alive across the call
        XCTAssertEqual(TapInput.read(split.list, interleaved: false, left: l.pointer, right: r.pointer, capacity: 4), 0)
    }

    func testEmptyListReadsNothing() {
        let abl = TestABL(frames: 4, layout: [])
        let l = Floats(zeros: 4), r = Floats(zeros: 4)
        XCTAssertEqual(TapInput.read(abl.list, interleaved: true, left: l.pointer, right: r.pointer, capacity: 4), 0)
        XCTAssertEqual(TapInput.read(abl.list, interleaved: false, left: l.pointer, right: r.pointer, capacity: 4), 0)
    }

    func testNilDataReadsNothing() {
        let abl = TestABL(frames: 4, layout: [2])
        let saved = abl.list[0].mData
        abl.list[0].mData = nil
        defer { abl.list[0].mData = saved }
        let l = Floats(zeros: 4), r = Floats(zeros: 4)
        XCTAssertEqual(TapInput.read(abl.list, interleaved: true, left: l.pointer, right: r.pointer, capacity: 4), 0)
    }

    func testNonInterleavedWithMismatchedChannelCountsReadsNothing() {
        let abl = TestABL(frames: 4, layout: [2, 2])
        let l = Floats(zeros: 4), r = Floats(zeros: 4)
        XCTAssertEqual(TapInput.read(abl.list, interleaved: false, left: l.pointer, right: r.pointer, capacity: 4), 0)
    }
}
