// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import XCTest
@testable import SoundChainCore

final class CustomNameTests: XCTestCase {
    private let pitch = ComponentID("aufc", "tmpt", "appl")!

    private func chain() -> (Chain, UUID) {
        var chain = Chain()
        let slot = chain.add(component: pitch, name: "AUPitch", manufacturer: "Apple")
        return (chain, slot.id)
    }

    // MARK: displayName and setCustomName

    func testDisplayNameIsThePluginNameUntilOneIsSet() {
        var (c, id) = chain()
        XCTAssertNil(c.slot(id: id)?.customName)
        XCTAssertEqual(c.slot(id: id)?.displayName, "AUPitch")
        XCTAssertTrue(c.setCustomName("Pitch Down", id: id))
        XCTAssertEqual(c.slot(id: id)?.customName, "Pitch Down")
        XCTAssertEqual(c.slot(id: id)?.displayName, "Pitch Down")
        XCTAssertEqual(c.slot(id: id)?.name, "AUPitch", "the plugin's own name is kept")
    }

    func testNamesAreTrimmed() {
        var (c, id) = chain()
        c.setCustomName("  Pitch Up \n", id: id)
        XCTAssertEqual(c.slot(id: id)?.customName, "Pitch Up")
    }

    func testAnEmptyOrBlankNameClearsIt() {
        var (c, id) = chain()
        c.setCustomName("Pitch Up", id: id)
        XCTAssertTrue(c.setCustomName("   ", id: id))
        XCTAssertNil(c.slot(id: id)?.customName)
        c.setCustomName("Pitch Up", id: id)
        c.setCustomName("", id: id)
        XCTAssertNil(c.slot(id: id)?.customName)
        c.setCustomName("Pitch Up", id: id)
        c.setCustomName(nil, id: id)
        XCTAssertEqual(c.slot(id: id)?.displayName, "AUPitch")
    }

    func testSetCustomNameReportsWhetherAnythingChanged() {
        var (c, id) = chain()
        XCTAssertFalse(c.setCustomName("", id: id), "no name to no name")
        XCTAssertTrue(c.setCustomName("A", id: id))
        XCTAssertFalse(c.setCustomName(" A ", id: id), "same name after trimming")
        XCTAssertFalse(c.setCustomName("B", id: UUID()), "unknown slot")
    }

    func testTheInitializerNormalizesToo() {
        XCTAssertNil(ChainSlot(component: pitch, name: "AUPitch", manufacturer: "Apple", customName: " ").customName)
        XCTAssertEqual(ChainSlot(component: pitch, name: "AUPitch", manufacturer: "Apple",
                                 customName: " X ").customName, "X")
    }

    // MARK: Saved chains

    func testAChainSavedBeforeCustomNamesStillLoads() throws {
        let id = UUID()
        let json = """
        {"version":1,"masterBypass":false,"slots":[{"id":"\(id.uuidString)",
         "component":{"type":\(pitch.type),"subtype":\(pitch.subtype),"manufacturer":\(pitch.manufacturer)},
         "name":"AUPitch","manufacturer":"Apple","bypassed":true}]}
        """
        let chain = try JSONDecoder().decode(Chain.self, from: Data(json.utf8))
        let slot = try XCTUnwrap(chain.slot(id: id))
        XCTAssertNil(slot.customName)
        XCTAssertEqual(slot.displayName, "AUPitch")
        XCTAssertTrue(slot.bypassed)
    }

    func testCustomNamesRoundTrip() throws {
        var (c, id) = chain()
        c.setCustomName("Pitch Up", id: id)
        let decoded = try JSONDecoder().decode(Chain.self, from: JSONEncoder().encode(c))
        XCTAssertEqual(decoded, c)
        XCTAssertEqual(decoded.slot(id: id)?.customName, "Pitch Up")
    }

    // MARK: Duplicate, copy and paste

    func testDuplicateKeepsTheCustomName() throws {
        var (c, id) = chain()
        c.setCustomName("Pitch Up", id: id)
        let copy = try XCTUnwrap(c.duplicate(id: id))
        XCTAssertEqual(copy.customName, "Pitch Up")
    }

    func testCopyAndPasteKeepTheCustomName() throws {
        var (c, id) = chain()
        c.setCustomName("Pitch Down", id: id)
        let data = SlotCopy(try XCTUnwrap(c.slot(id: id))).encoded()
        let copy = try XCTUnwrap(SlotCopy(encoded: data))
        let pasted = c.insert(copy, below: id)
        XCTAssertEqual(pasted.customName, "Pitch Down")
        XCTAssertNotEqual(pasted.id, id)
    }

    func testACopyMadeBeforeCustomNamesStillPastes() throws {
        let json = """
        {"version":1,"component":{"type":\(pitch.type),"subtype":\(pitch.subtype),"manufacturer":\(pitch.manufacturer)},
         "name":"AUPitch","manufacturer":"Apple","bypassed":false}
        """
        let copy = try XCTUnwrap(SlotCopy(encoded: Data(json.utf8)))
        XCTAssertNil(copy.makeSlot().customName)
    }
}
