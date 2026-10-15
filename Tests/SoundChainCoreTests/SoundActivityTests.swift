// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import XCTest
@testable import SoundChainCore

final class SoundActivityTests: XCTestCase {
    func testSilenceIsNotAudible() {
        let l = Floats([0, 0, 0]), r = Floats([0, -0, 0])
        XCTAssertFalse(SoundActivity.isAudible(left: l.pointer, right: r.pointer, frames: 3))
    }

    // Dither and noise floor (around -70 dBFS) are not sound.
    func testNoiseFloorIsNotAudible() {
        let l = Floats([0.0003, -0.0003]), r = Floats([-0.0002, 0.0001])
        XCTAssertFalse(SoundActivity.isAudible(left: l.pointer, right: r.pointer, frames: 2))
    }

    func testAnySampleAboveTheThresholdIsAudible() {
        let l = Floats([0, 0, 0]), r = Floats([0, -0.01, 0])
        XCTAssertTrue(SoundActivity.isAudible(left: r.pointer, right: l.pointer, frames: 3))
        XCTAssertTrue(SoundActivity.isAudible(left: l.pointer, right: r.pointer, frames: 3))
    }

    // Only the first `frames` samples count.
    func testSamplesPastFramesAreIgnored() {
        let l = Floats([0, 0.5]), r = Floats([0, 0.5])
        XCTAssertFalse(SoundActivity.isAudible(left: l.pointer, right: r.pointer, frames: 1))
    }

    // The first look only learns where the count stands: it cannot tell when
    // those cycles were.
    func testFirstUpdateIsNotSound() {
        var activity = SoundActivity()
        XCTAssertFalse(activity.update(count: 500, now: 10))
    }

    func testCountMovingIsSound() {
        var activity = SoundActivity()
        _ = activity.update(count: 0, now: 0)
        XCTAssertFalse(activity.update(count: 0, now: 1))
        XCTAssertTrue(activity.update(count: 40, now: 2))
    }

    // A gap shorter than `hold` (between tracks, say) does not stop her.
    func testSoundIsHeldThroughShortGaps() {
        var activity = SoundActivity()
        _ = activity.update(count: 0, now: 0)
        XCTAssertTrue(activity.update(count: 40, now: 1))
        XCTAssertTrue(activity.update(count: 40, now: 1 + SoundActivity.hold * 0.9))
        XCTAssertTrue(activity.update(count: 41, now: 1 + SoundActivity.hold * 1.5))
        XCTAssertTrue(activity.update(count: 41, now: 1 + SoundActivity.hold * 2.4))
        XCTAssertFalse(activity.update(count: 41, now: 1 + SoundActivity.hold * 2.5))
        XCTAssertFalse(activity.update(count: 41, now: 100))
    }
}
