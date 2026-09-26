// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import XCTest
@testable import SoundChainCore

private final class MemoryStore: FlagStore {
    var values: [String: Any] = [:]
    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    func integer(forKey key: String) -> Int { values[key] as? Int ?? 0 }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}

final class CrashGuardTests: XCTestCase {
    private var store: MemoryStore!
    private var guardian: CrashGuard { CrashGuard(store: store) }   // a fresh instance per "launch"

    override func setUp() { store = MemoryStore() }

    func testFirstLaunchDoesNotBypass() {
        XCTAssertFalse(guardian.recordLaunch())
    }

    func testOneCrashDoesNotBypass() {
        _ = guardian.recordLaunch()          // then crash: no clean exit
        XCTAssertFalse(guardian.recordLaunch())
        XCTAssertEqual(guardian.uncleanExits, 1)
    }

    func testTwoCrashesInARowBypass() {
        _ = guardian.recordLaunch()
        _ = guardian.recordLaunch()
        XCTAssertTrue(guardian.recordLaunch())
    }

    func testCleanExitResetsTheCount() {
        _ = guardian.recordLaunch()
        _ = guardian.recordLaunch()
        guardian.recordCleanExit()
        XCTAssertFalse(guardian.recordLaunch())
        XCTAssertEqual(guardian.uncleanExits, 0)
    }

    func testStableRunResetsTheCountSoALaterCrashStartsFresh() {
        _ = guardian.recordLaunch()
        _ = guardian.recordLaunch()          // 1 unclean
        guardian.markStable()                // ran 60 s fine, then crashed
        XCTAssertFalse(guardian.recordLaunch())
        XCTAssertEqual(guardian.uncleanExits, 1)
    }

    func testUserDefaultsConforms() {
        let suite = "CrashGuardTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        _ = CrashGuard(store: defaults).recordLaunch()
        _ = CrashGuard(store: defaults).recordLaunch()
        XCTAssertTrue(CrashGuard(store: defaults).recordLaunch())
    }
}
