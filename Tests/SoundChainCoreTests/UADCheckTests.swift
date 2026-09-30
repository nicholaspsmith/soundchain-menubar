// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import XCTest
@testable import SoundChainCore

final class UADCheckTests: XCTestCase {
    private func slot(_ name: String, manufacturer: String = "!UAD", bypassed: Bool = false) -> ChainSlot {
        ChainSlot(component: ComponentID("aufx", "53AU", manufacturer)!, name: name,
                  manufacturer: "Universal Audio", bypassed: bypassed)
    }

    func testDSPPluginNeedsHardware() {
        XCTAssertTrue(UADCheck.needsHardware(slot("UAD UA 1176SE Legacy")))
    }

    func testNativeUADxPluginDoesNot() {
        XCTAssertFalse(UADCheck.needsHardware(slot("UADx 1176 Rev E Compressor")))
    }

    func testOtherManufacturersDoNot() {
        XCTAssertFalse(UADCheck.needsHardware(slot("UAD Lookalike", manufacturer: "FabF")))
    }

    func testIdleDSPPluginsAreCountedWithoutHardware() {
        let chain = Chain(slots: [slot("UAD UA 1176SE Legacy"), slot("UAD Pultec EQP-1A"), slot("UADx LA-2A")])
        XCTAssertEqual(UADCheck.idleSlots(in: chain, hardwarePresent: false).count, 2)
        XCTAssertEqual(UADCheck.warning(chain: chain, hardwarePresent: false), "⚠ No UAD hardware: 2 paused")
    }

    func testNoWarningWithHardware() {
        let chain = Chain(slots: [slot("UAD UA 1176SE Legacy")])
        XCTAssertNil(UADCheck.warning(chain: chain, hardwarePresent: true))
        XCTAssertTrue(UADCheck.idleSlots(in: chain, hardwarePresent: true).isEmpty)
    }

    func testBypassedSlotsAndMasterBypassAreNotWarned() {
        XCTAssertNil(UADCheck.warning(chain: Chain(slots: [slot("UAD UA 1176SE Legacy", bypassed: true)]),
                                      hardwarePresent: false))
        XCTAssertNil(UADCheck.warning(chain: Chain(masterBypass: true, slots: [slot("UAD UA 1176SE Legacy")]),
                                      hardwarePresent: false))
    }

    func testWarningFitsOnOneMenuLine() {
        let chain = Chain(slots: [slot("UAD UA 1176SE Legacy")])
        XCTAssertEqual(UADCheck.warning(chain: chain, hardwarePresent: false), "⚠ No UAD hardware: 1 paused")
        let many = Chain(slots: Array(repeating: slot("UAD Pultec EQP-1A"), count: 100))
        XCTAssertLessThanOrEqual(UADCheck.warning(chain: many, hardwarePresent: false)!.count, 34)
    }
}
