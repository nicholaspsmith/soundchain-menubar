// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import Foundation
import XCTest
@testable import SoundChainCore

final class SoundLevelTests: XCTestCase {
    private func rms(_ left: [Float], _ right: [Float], frames: Int? = nil) -> Float {
        let l = Floats(left), r = Floats(right)
        return SoundLevel.rms(left: l.pointer, right: r.pointer, frames: frames ?? left.count)
    }

    private func level(dB: Float) -> Float { pow(10, dB / 20) }

    func testRMSOfSilenceIsZero() {
        XCTAssertEqual(rms([0, 0, 0], [0, 0, 0]), 0)
        XCTAssertEqual(rms([], [], frames: 0), 0)
    }

    func testRMSOfAFullScaleSquareIsOne() {
        XCTAssertEqual(rms([1, -1, 1, -1], [-1, 1, -1, 1]), 1, accuracy: 1e-6)
    }

    // Both channels count: one silent side halves the power.
    func testRMSCoversBothChannels() {
        XCTAssertEqual(rms([1, -1], [0, 0]), Float(0.5).squareRoot(), accuracy: 1e-6)
    }

    func testRMSCountsOnlyFrames() {
        XCTAssertEqual(rms([0, 1], [0, 1], frames: 1), 0)
    }

    // Silent below the floor, full stride at the ceiling, even in decibels between.
    func testDriveFollowsDecibelsFromFloorToCeiling() {
        XCTAssertEqual(SoundLevel.drive(rms: 0), 0)
        XCTAssertEqual(SoundLevel.drive(rms: level(dB: SoundLevel.floor - 10)), 0)
        XCTAssertEqual(SoundLevel.drive(rms: level(dB: SoundLevel.floor)), 0, accuracy: 1e-5)
        XCTAssertEqual(SoundLevel.drive(rms: level(dB: (SoundLevel.floor + SoundLevel.ceiling) / 2)), 0.5, accuracy: 1e-5)
        XCTAssertEqual(SoundLevel.drive(rms: level(dB: SoundLevel.ceiling)), 1, accuracy: 1e-5)
        XCTAssertEqual(SoundLevel.drive(rms: 1), 1)
        XCTAssertEqual(SoundLevel.drive(rms: .infinity), 1)
    }

    // She moves to the sound as it is heard: what was measured `latency` ago.
    func testDelayGivesWhatWasMeasuredThatLongAgo() {
        var delay = LevelDelay()
        delay.push(0.2, at: 1.0)
        delay.push(0.8, at: 1.1)
        delay.push(0.5, at: 1.2)
        XCTAssertEqual(delay.value(at: 1.15), 0.8)
        XCTAssertEqual(delay.value(at: 1.1), 0.8)
        XCTAssertEqual(delay.value(at: 1.2), 0.5)
        XCTAssertEqual(delay.value(at: 9), 0.5)
        XCTAssertEqual(delay.value(at: 0.5), 0)
    }

    func testDelayKeepsOnlyRecentSamples() {
        var delay = LevelDelay()
        for i in 0..<1000 { delay.push(Double(i), at: Double(i)) }
        XCTAssertEqual(delay.samples.count, LevelDelay.capacity)
        XCTAssertEqual(delay.value(at: 999), 999)
        XCTAssertEqual(delay.value(at: 990.5), 990)
    }
}
