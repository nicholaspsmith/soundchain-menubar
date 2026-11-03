// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import XCTest
@testable import SoundChainCore

final class MenuLinesTests: XCTestCase {
    func testShortLinesAreLeftAlone() {
        let fit = MenuLines.fit("2 effects running")
        XCTAssertEqual(fit.title, "2 effects running")
        XCTAssertNil(fit.toolTip)
        XCTAssertNil(MenuLines.fit(String(repeating: "a", count: MenuLines.limit)).toolTip, "exactly the limit fits")
    }

    func testLongLinesAreCutWithTheFullTextAsTooltip() {
        let long = "External Headphones on a Very Long Device Name"
        let fit = MenuLines.fit(long)
        XCTAssertEqual(fit.title.count, MenuLines.limit)
        XCTAssertTrue(fit.title.hasSuffix("…"))
        XCTAssertTrue(long.hasPrefix(String(fit.title.dropLast())))
        XCTAssertEqual(fit.toolTip, long)
    }

    func testInfoBlockOrder() {
        XCTAssertEqual(MenuLines.info(status: ["AirPods", "1 effect running"], notice: "Reconnected AirPods",
                                      headphones: "Dropped iPhone", errors: ["Pro-Q: failed"], uadWarning: "UAD"),
                       ["AirPods", "1 effect running", "Reconnected AirPods", "Dropped iPhone", "Pro-Q: failed", "UAD"])
        XCTAssertEqual(MenuLines.info(status: ["Bypassed"], notice: nil, headphones: nil, errors: [], uadWarning: nil),
                       ["Bypassed"])
    }

    func testReconnectTitle() {
        XCTAssertEqual(MenuLines.reconnect("AirPods", inProgress: false), "Reconnect AirPods")
        XCTAssertEqual(MenuLines.reconnect("AirPods", inProgress: true), "Reconnecting AirPods…")
    }
}
