// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import XCTest
@testable import SoundChainCore

final class PermissionAdviceTests: XCTestCase {
    func testStartsOnceAGrantShowsUp() {
        XCTAssertTrue(PermissionAdvice.shouldStart(denied: true, now: .authorized))
        XCTAssertFalse(PermissionAdvice.shouldStart(denied: true, now: .denied))
        XCTAssertFalse(PermissionAdvice.shouldStart(denied: true, now: .unknown))
        XCTAssertFalse(PermissionAdvice.shouldStart(denied: false, now: .authorized), "already running")
    }

    func testOffersGrantWhenDenied() {
        for status in [CapturePermission.authorized, .denied, .unknown] {
            XCTAssertTrue(PermissionAdvice.offersGrant(denied: true, tapFailed: false, status: status))
        }
    }

    func testOffersGrantWhenTheTapFailsAndPermissionIsUnknown() {
        XCTAssertTrue(PermissionAdvice.offersGrant(denied: false, tapFailed: true, status: .unknown))
        XCTAssertTrue(PermissionAdvice.offersGrant(denied: false, tapFailed: true, status: .denied))
        XCTAssertFalse(PermissionAdvice.offersGrant(denied: false, tapFailed: true, status: .authorized),
                       "a granted permission is not the problem")
        XCTAssertFalse(PermissionAdvice.offersGrant(denied: false, tapFailed: false, status: .unknown))
    }
}
