// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import CoreAudio
import XCTest
@testable import SoundChainCore

final class StereoRouteTests: XCTestCase {
    func testApolloStylePreferredPairInsideOneWideStream() {
        let route = StereoRoute.resolve(preferred: [5, 6], streamChannels: [10])
        XCTAssertEqual(route, StereoRoute(left: 4, right: 5, tapStream: 0, tapStart: 0, tapChannels: 10))
        XCTAssertEqual(route?.leftInTap, 4)
        XCTAssertEqual(route?.rightInTap, 5)
    }

    func testPreferredPairInALaterStream() {
        let route = StereoRoute.resolve(preferred: [3, 4], streamChannels: [2, 8])
        XCTAssertEqual(route, StereoRoute(left: 2, right: 3, tapStream: 1, tapStart: 2, tapChannels: 8))
        XCTAssertEqual(route?.leftInTap, 0)
    }

    func testUnsetOrOutOfRangePreferenceFallsBackToTheFirstPair() {
        let expected = StereoRoute(left: 0, right: 1, tapStream: 0, tapStart: 0, tapChannels: 2)
        XCTAssertEqual(StereoRoute.resolve(preferred: [0, 0], streamChannels: [2]), expected)
        XCTAssertEqual(StereoRoute.resolve(preferred: [7, 8], streamChannels: [2]), expected)
        XCTAssertEqual(StereoRoute.resolve(preferred: [], streamChannels: [2]), expected)
    }

    func testRightChannelOutsideTheLeftChannelsStreamUsesItsNeighbour() {
        XCTAssertEqual(StereoRoute.resolve(preferred: [3, 9], streamChannels: [4, 8]),
                       StereoRoute(left: 2, right: 3, tapStream: 0, tapStart: 0, tapChannels: 4))
    }

    func testMonoDeviceUsesOneChannelForBoth() {
        XCTAssertEqual(StereoRoute.resolve(preferred: [1, 2], streamChannels: [1]),
                       StereoRoute(left: 0, right: 0, tapStream: 0, tapStart: 0, tapChannels: 1))
    }

    func testNoOutputChannelsHasNoRoute() {
        XCTAssertNil(StereoRoute.resolve(preferred: [1, 2], streamChannels: []))
        XCTAssertNil(StereoRoute.resolve(preferred: [1, 2], streamChannels: [0]))
    }
}

/// The device-shaped tap (every channel of the output stream) feeding the chain and the output.
final class DeviceTapTests: XCTestCase {
    /// 10 interleaved channels; channel c of frame f holds c * 10 + f.
    private func tenChannelTap(frames: Int, after deviceInputs: [Int] = []) -> TestABL {
        let abl = TestABL(frames: frames, layout: deviceInputs + [10])
        abl.fill(deviceInputs.count, (0..<frames).flatMap { f in (0..<10).map { Float($0 * 10 + f) } })
        return abl
    }

    func testReadsThePreferredPairOutOfAWideInterleavedTap() {
        let abl = tenChannelTap(frames: 3, after: [2])
        let stream = TapStream(abl.list, interleaved: true, channels: 10)
        XCTAssertEqual(stream?.frames, 3)
        let l = Floats(zeros: 3), r = Floats(zeros: 3)
        XCTAssertEqual(TapInput.read(stream!, leftChannel: 4, rightChannel: 5, left: l.pointer, right: r.pointer, capacity: 8), 3)
        XCTAssertEqual(l.array, [40, 41, 42])
        XCTAssertEqual(r.array, [50, 51, 52])
    }

    func testReadsANonInterleavedTapFromTheLastBuffers() {
        let abl = TestABL(frames: 2, layout: [2, 1, 1, 1])          // device input, then 3 tap channels
        abl.fill(1, [1, 2]); abl.fill(2, [3, 4]); abl.fill(3, [5, 6])
        let stream = TapStream(abl.list, interleaved: false, channels: 3)
        let l = Floats(zeros: 2), r = Floats(zeros: 2)
        XCTAssertEqual(TapInput.read(stream!, leftChannel: 1, rightChannel: 2, left: l.pointer, right: r.pointer, capacity: 2), 2)
        XCTAssertEqual(l.array, [3, 4])
        XCTAssertEqual(r.array, [5, 6])
    }

    func testAMisshapenTapIsRejected() {
        let stereo = TestABL(frames: 2, layout: [2]), mixed = TestABL(frames: 2, layout: [2, 1])
        let empty = TestABL(frames: 2, layout: [])
        XCTAssertNil(TapStream(stereo.list, interleaved: true, channels: 10))
        XCTAssertNil(TapStream(mixed.list, interleaved: false, channels: 3))
        XCTAssertNil(TapStream(empty.list, interleaved: true, channels: 2))
    }

    func testProcessedPairGoesBackToThePreferredChannelsAndTheRestPassThrough() {
        let tap = tenChannelTap(frames: 2)
        let stream = TapStream(tap.list, interleaved: true, channels: 10)!
        let route = StereoRoute.resolve(preferred: [5, 6], streamChannels: [10])!
        let out = TestABL(frames: 2, layout: [10])
        let l = Floats([-1, -2]), r = Floats([-3, -4])
        ChannelMap.write(left: l.pointer, right: r.pointer, frames: 2, to: out.list, route: route, passthrough: stream)
        XCTAssertEqual(out.array(0), [0, 10, 20, 30, -1, -3, 60, 70, 80, 90,
                                      1, 11, 21, 31, -2, -4, 61, 71, 81, 91])
    }

    func testChannelsOutsideTheTappedStreamAreSilent() {
        let tap = TestABL(frames: 1, layout: [2])
        tap.fill(0, [7, 8])
        let stream = TapStream(tap.list, interleaved: true, channels: 2)!
        let route = StereoRoute.resolve(preferred: [3, 4], streamChannels: [2, 2])!   // tap covers stream 1
        let out = TestABL(frames: 1, layout: [2, 2])
        out.fill(0, [9, 9])
        let l = Floats([0.5]), r = Floats([0.25])
        ChannelMap.write(left: l.pointer, right: r.pointer, frames: 1, to: out.list, route: route, passthrough: stream)
        XCTAssertEqual(out.array(0), [0, 0])
        XCTAssertEqual(out.array(1), [0.5, 0.25])
    }

    /// Bypass must be unity gain end to end: tap in, same samples out on the same channels.
    func testPassThroughIsBitExact() {
        let tap = tenChannelTap(frames: 4)
        let stream = TapStream(tap.list, interleaved: true, channels: 10)!
        let route = StereoRoute.resolve(preferred: [5, 6], streamChannels: [10])!
        let l = Floats(zeros: 4), r = Floats(zeros: 4)
        let frames = TapInput.read(stream, leftChannel: route.leftInTap, rightChannel: route.rightInTap,
                                   left: l.pointer, right: r.pointer, capacity: 4)
        let out = TestABL(frames: 4, layout: [10])
        ChannelMap.write(left: l.pointer, right: r.pointer, frames: frames, to: out.list, route: route, passthrough: stream)
        XCTAssertEqual(out.array(0), tap.array(0))
    }
}
