// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import XCTest
@testable import SoundChainCore

final class BoseConversationTests: XCTestCase {
    private final class Fake: BoseConversation {
        var onStart: () -> Void = {}
        var cancels = 0
        func start() { onStart() }
        func cancel() { cancels += 1 }
    }

    func testAConversationThatFailsWhileStartingLeavesTheSlotFree() {
        let slot = BoseConversationSlot()
        let failing = Fake()
        failing.onStart = { slot.finished(failing) }
        slot.begin(failing)
        XCTAssertNil(slot.current)
    }

    func testAConversationIsHeldWhileItRuns() {
        let slot = BoseConversationSlot()
        let running = Fake()
        slot.begin(running)
        XCTAssertTrue(slot.current === running)
    }

    func testCancelStopsTheConversationAndFreesTheSlot() {
        let slot = BoseConversationSlot()
        let running = Fake()
        slot.begin(running)
        slot.cancel()
        XCTAssertEqual(running.cancels, 1)
        XCTAssertNil(slot.current)
    }

    func testAnEarlierConversationFinishingLeavesTheCurrentOneHeld() {
        let slot = BoseConversationSlot()
        let earlier = Fake()
        slot.begin(earlier)
        slot.cancel()
        let later = Fake()
        slot.begin(later)
        slot.finished(earlier)
        XCTAssertTrue(slot.current === later)
    }

    func testHeadphonesThatAreOffAreNotChecked() {
        XCTAssertFalse(BoseLink.shouldCheck(stopped: false, busy: false, inConversation: false, connected: false))
    }

    func testConnectedHeadphonesAreChecked() {
        XCTAssertTrue(BoseLink.shouldCheck(stopped: false, busy: false, inConversation: false, connected: true))
    }

    func testNothingStartsWhileAnythingElseHoldsTheDevice() {
        XCTAssertFalse(BoseLink.shouldCheck(stopped: true, busy: false, inConversation: false, connected: true))
        XCTAssertFalse(BoseLink.shouldCheck(stopped: false, busy: true, inConversation: false, connected: true))
        XCTAssertFalse(BoseLink.shouldCheck(stopped: false, busy: false, inConversation: true, connected: true))
    }
}
