// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import XCTest
@testable import SoundChainCore

final class SlotCopyTests: XCTestCase {
    private let delay = ComponentID("aufx", "dely", "appl")!
    private let eq = ComponentID("aufx", "nbeq", "appl")!

    private func chain(_ names: String...) -> Chain {
        var chain = Chain()
        for name in names { chain.add(component: delay, name: name, manufacturer: "Apple") }
        return chain
    }
    private func names(_ chain: Chain) -> [String] { chain.slots.map(\.name) }

    // MARK: Duplicate

    func testDuplicateAppendsACopyWithANewIDAndTheLiveState() throws {
        var c = chain("A", "B", "C")
        let a = c.slots[0]
        c.setState(Data([1]), id: a.id)
        let copy = try XCTUnwrap(c.duplicate(id: a.id, liveState: Data([9, 9])))
        XCTAssertEqual(names(c), ["A", "B", "C", "A"])
        XCTAssertEqual(c.slots.last, copy)
        XCTAssertNotEqual(copy.id, a.id)
        XCTAssertEqual(copy.component, a.component)
        XCTAssertEqual(copy.manufacturer, a.manufacturer)
        XCTAssertEqual(copy.state, Data([9, 9]))
        XCTAssertEqual(c.slot(id: a.id)?.state, Data([1]), "the original is left alone")
    }

    func testDuplicateFallsBackToTheSavedStateWithoutALiveOne() throws {
        var c = chain("A")
        c.setState(Data([7]), id: c.slots[0].id)
        let copy = try XCTUnwrap(c.duplicate(id: c.slots[0].id))
        XCTAssertEqual(copy.state, Data([7]))
    }

    func testDuplicateKeepsTheBypassedFlag() throws {
        var c = chain("A")
        c.setBypassed(true, id: c.slots[0].id)
        XCTAssertTrue(try XCTUnwrap(c.duplicate(id: c.slots[0].id)).bypassed)
    }

    func testDuplicatingAnUnknownSlotDoesNothing() {
        var c = chain("A")
        XCTAssertNil(c.duplicate(id: UUID()))
        XCTAssertEqual(names(c), ["A"])
    }

    // MARK: Paste

    func testPasteGoesDirectlyBelowTheSelectedSlot() {
        var c = chain("A", "B", "C")
        let copy = SlotCopy(ChainSlot(component: eq, name: "EQ", manufacturer: "Apple"))
        let pasted = c.insert(copy, below: c.slots[0].id)
        XCTAssertEqual(names(c), ["A", "EQ", "B", "C"])
        XCTAssertEqual(c.slots[1], pasted)
    }

    func testPasteBelowTheLastSlotOrNothingAppends() {
        var c = chain("A", "B")
        let copy = SlotCopy(ChainSlot(component: eq, name: "EQ", manufacturer: "Apple"))
        c.insert(copy, below: c.slots[1].id)
        c.insert(copy, below: nil)
        c.insert(copy, below: UUID())
        XCTAssertEqual(names(c), ["A", "B", "EQ", "EQ", "EQ"])
    }

    func testPastingTheSameCopyTwiceGivesTwoIndependentSlots() {
        var c = chain("A")
        let copy = SlotCopy(c.slots[0], liveState: Data([5]))
        let first = c.insert(copy, below: c.slots[0].id)
        let second = c.insert(copy, below: c.slots[0].id)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(Set(c.slots.map(\.id)).count, 3)
        c.setState(Data([6]), id: first.id)
        XCTAssertEqual(c.slot(id: second.id)?.state, Data([5]), "changing one copy leaves the other alone")
    }

    // MARK: Payload

    func testCopyCarriesEverythingButTheID() {
        let slot = ChainSlot(component: eq, name: "EQ", manufacturer: "Apple", bypassed: true, state: Data([1, 2]))
        let copy = SlotCopy(slot)
        XCTAssertEqual(copy.component, eq)
        XCTAssertEqual(copy.name, "EQ")
        XCTAssertEqual(copy.manufacturer, "Apple")
        XCTAssertTrue(copy.bypassed)
        XCTAssertEqual(copy.state, Data([1, 2]))
        XCTAssertEqual(SlotCopy(slot, liveState: Data([3])).state, Data([3]), "live state wins over saved")
        XCTAssertNotEqual(copy.makeSlot().id, slot.id)
    }

    func testPayloadRoundTrips() throws {
        let slot = ChainSlot(component: eq, name: "EQ", manufacturer: "Apple", state: Data((0...255).map(UInt8.init)))
        let copy = SlotCopy(slot)
        XCTAssertEqual(try XCTUnwrap(SlotCopy(encoded: copy.encoded())), copy)
        let stateless = SlotCopy(ChainSlot(component: eq, name: "EQ", manufacturer: "Apple"))
        XCTAssertEqual(SlotCopy(encoded: stateless.encoded()), stateless)
    }

    func testPayloadRejectsGarbageAndNewerVersions() throws {
        XCTAssertNil(SlotCopy(encoded: Data("hello".utf8)))
        XCTAssertNil(SlotCopy(encoded: Data()))
        var future = SlotCopy(ChainSlot(component: eq, name: "EQ", manufacturer: "Apple"))
        future.version = SlotCopy.currentVersion + 1
        XCTAssertNil(SlotCopy(encoded: future.encoded()))
    }
}
