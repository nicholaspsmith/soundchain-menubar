// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import CoreAudio
import XCTest
@testable import SoundChainCore

final class ChannelMapTests: XCTestCase {
    private let left = Floats([1, 2, 3, 4])
    private let right = Floats([-1, -2, -3, -4])

    func testInterleavedStereo() {
        let out = TestABL(frames: 4, layout: [2])
        ChannelMap.write(left: left.pointer, right: right.pointer, frames: 4, to: out.list)
        XCTAssertEqual(out.array(0), [1, -1, 2, -2, 3, -3, 4, -4])
    }

    func testSixChannelInterleavedZeroesTheExtraChannels() {
        let out = TestABL(frames: 2, layout: [6])
        out.fill(0, [Float](repeating: 9, count: 12))
        ChannelMap.write(left: left.pointer, right: right.pointer, frames: 2, to: out.list)
        XCTAssertEqual(out.array(0), [1, -1, 0, 0, 0, 0, 2, -2, 0, 0, 0, 0])
    }

    func testNonInterleavedStereo() {
        let out = TestABL(frames: 4, layout: [1, 1])
        ChannelMap.write(left: left.pointer, right: right.pointer, frames: 4, to: out.list)
        XCTAssertEqual(out.array(0), [1, 2, 3, 4])
        XCTAssertEqual(out.array(1), [-1, -2, -3, -4])
    }

    func testChannelsSpanBuffers() {
        let out = TestABL(frames: 2, layout: [1, 3])        // L alone, then R + 2 extras
        out.fill(1, [Float](repeating: 9, count: 6))
        ChannelMap.write(left: left.pointer, right: right.pointer, frames: 2, to: out.list)
        XCTAssertEqual(out.array(0), [1, 2])
        XCTAssertEqual(out.array(1), [-1, 0, 0, -2, 0, 0])
    }

    func testMonoDeviceGetsTheAverage() {
        let l = Floats([1, 0.5]), r = Floats([0, 0.5])
        let out = TestABL(frames: 2, layout: [1])
        ChannelMap.write(left: l.pointer, right: r.pointer, frames: 2, to: out.list)
        XCTAssertEqual(out.array(0), [0.5, 0.5])
    }

    func testShortRenderZeroesTheRestOfTheBuffer() {
        let out = TestABL(frames: 4, layout: [2])
        out.fill(0, [Float](repeating: 9, count: 8))
        ChannelMap.write(left: left.pointer, right: right.pointer, frames: 2, to: out.list)
        XCTAssertEqual(out.array(0), [1, -1, 2, -2, 0, 0, 0, 0])
    }

    func testZero() {
        let out = TestABL(frames: 2, layout: [2, 1])
        out.fill(0, [1, 1, 1, 1]); out.fill(1, [1, 1])
        ChannelMap.zero(out.list)
        XCTAssertEqual(out.array(0), [0, 0, 0, 0])
        XCTAssertEqual(out.array(1), [0, 0])
    }
}
