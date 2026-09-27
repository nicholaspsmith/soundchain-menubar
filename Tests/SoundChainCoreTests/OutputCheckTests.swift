// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import CoreAudio
import XCTest
@testable import SoundChainCore

final class OutputCheckTests: XCTestCase {
    func testVirtualOutputIsWarned() {
        XCTAssertNotNil(OutputCheck.warning(transportType: kAudioDeviceTransportTypeVirtual))
    }

    func testRealOutputsAreNotWarned() {
        for transport in [kAudioDeviceTransportTypeBuiltIn, kAudioDeviceTransportTypeUSB,
                          kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeHDMI,
                          kAudioDeviceTransportTypeAirPlay, kAudioDeviceTransportTypeAggregate] {
            XCTAssertNil(OutputCheck.warning(transportType: transport), "transport \(transport)")
        }
    }

    func testUnreadableTransportIsNotWarned() {
        XCTAssertNil(OutputCheck.warning(transportType: kAudioDeviceTransportTypeUnknown))
    }

    func testWarningFitsOnOneMenuLine() {
        XCTAssertLessThanOrEqual(OutputCheck.warning(transportType: kAudioDeviceTransportTypeVirtual)!.count, 34)
    }
}
