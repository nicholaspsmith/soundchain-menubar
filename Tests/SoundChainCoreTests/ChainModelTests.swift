// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import XCTest
@testable import SoundChainCore

final class ChainModelTests: XCTestCase {
    private let delay = ComponentID("aufx", "dely", "appl")!

    private func chain(_ names: String...) -> Chain {
        var chain = Chain()
        for name in names { chain.add(component: delay, name: name, manufacturer: "Apple") }
        return chain
    }
    private func names(_ chain: Chain) -> [String] { chain.slots.map(\.name) }

    func testFourCCRoundTrip() {
        XCTAssertEqual(delay.fourCC, "aufx dely appl")
        XCTAssertEqual(delay.type, 0x6175_6678)
    }

    func testFourCCRejectsWrongLengthOrNonASCII() {
        XCTAssertNil(ComponentID("auf", "dely", "appl"))
        XCTAssertNil(ComponentID("aufx", "délé", "appl"))
    }

    func testNonPrintableBytesShowAsQuestionMarks() {
        let id = ComponentID(type: 0x0061_6263, subtype: delay.subtype, manufacturer: delay.manufacturer)
        XCTAssertEqual(id.fourCC, "?abc dely appl")
    }

    func testAddAppendsAnUnbypassedSlotWithoutState() {
        var c = chain("A")
        let slot = c.add(component: delay, name: "B", manufacturer: "Apple")
        XCTAssertEqual(names(c), ["A", "B"])
        XCTAssertFalse(slot.bypassed)
        XCTAssertNil(slot.state)
        XCTAssertEqual(c.slot(id: slot.id), slot)
    }

    func testRemove() {
        var c = chain("A", "B", "C")
        c.remove(id: c.slots[1].id)
        XCTAssertEqual(names(c), ["A", "C"])
    }

    func testMoveDown() {
        var c = chain("A", "B", "C")
        c.move(from: 0, insertionIndex: 2)
        XCTAssertEqual(names(c), ["B", "A", "C"])
    }

    func testMoveToEnd() {
        var c = chain("A", "B", "C")
        c.move(from: 0, insertionIndex: 3)
        XCTAssertEqual(names(c), ["B", "C", "A"])
    }

    func testMoveUp() {
        var c = chain("A", "B", "C")
        c.move(from: 2, insertionIndex: 0)
        XCTAssertEqual(names(c), ["C", "A", "B"])
    }

    func testMoveOntoItselfIsANoOp() {
        var c = chain("A", "B", "C")
        c.move(from: 1, insertionIndex: 1)
        c.move(from: 1, insertionIndex: 2)
        XCTAssertEqual(names(c), ["A", "B", "C"])
    }

    func testMoveOutOfRangeIsIgnored() {
        var c = chain("A", "B")
        c.move(from: 5, insertionIndex: 0)
        c.move(from: 0, insertionIndex: 9)
        c.move(from: -1, insertionIndex: 0)
        XCTAssertEqual(names(c), ["A", "B"])
    }

    func testSetBypassed() {
        var c = chain("A", "B")
        c.setBypassed(true, id: c.slots[1].id)
        XCTAssertEqual(c.slots.map(\.bypassed), [false, true])
    }

    func testSetStateReportsWhetherItChanged() {
        var c = chain("A")
        let id = c.slots[0].id
        XCTAssertTrue(c.setState(Data([1, 2]), id: id))
        XCTAssertFalse(c.setState(Data([1, 2]), id: id))
        XCTAssertTrue(c.setState(nil, id: id))
        XCTAssertFalse(c.setState(Data([1]), id: UUID()))
    }

    func testCodableRoundTrip() throws {
        var c = chain("A", "B")
        c.masterBypass = true
        c.setBypassed(true, id: c.slots[0].id)
        c.setState(Data([9, 8, 7]), id: c.slots[1].id)
        let decoded = try JSONDecoder().decode(Chain.self, from: JSONEncoder().encode(c))
        XCTAssertEqual(decoded, c)
        XCTAssertEqual(decoded.version, Chain.currentVersion)
    }
}
