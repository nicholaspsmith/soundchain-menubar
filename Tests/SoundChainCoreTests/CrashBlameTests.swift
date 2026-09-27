// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import XCTest
@testable import SoundChainCore

final class CrashBlameTests: XCTestCase {
    private var dir: URL!
    private let a = ComponentID("aufx", "aaaa", "test")!
    private let b = ComponentID("aufx", "bbbb", "test")!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("CrashBlameTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testNothingDisabledAtFirst() {
        let blame = CrashBlame(directory: dir)
        XCTAssertEqual(blame.recordLaunch(lastExitUnclean: true), [])
        XCTAssertTrue(blame.disabled.isEmpty)
    }

    func testAnOperationStillInProgressAtACrashDisablesThatComponent() {
        CrashBlame(directory: dir).begin(a)                         // then the app dies
        let next = CrashBlame(directory: dir)
        XCTAssertEqual(next.recordLaunch(lastExitUnclean: true), [a])
        XCTAssertTrue(next.isDisabled(a))
        XCTAssertFalse(next.isDisabled(b))
    }

    func testFinishedOperationsAreNotBlamed() {
        let blame = CrashBlame(directory: dir)
        blame.begin(a); blame.begin(b); blame.end(a)
        XCTAssertEqual(CrashBlame(directory: dir).recordLaunch(lastExitUnclean: true), [b])
    }

    func testACleanExitBlamesNothingAndClearsTheMarker() {
        CrashBlame(directory: dir).begin(a)
        XCTAssertEqual(CrashBlame(directory: dir).recordLaunch(lastExitUnclean: false), [])
        XCTAssertEqual(CrashBlame(directory: dir).recordLaunch(lastExitUnclean: true), [])
    }

    func testDisabledComponentsStayDisabledAcrossLaunches() {
        CrashBlame(directory: dir).begin(a)
        _ = CrashBlame(directory: dir).recordLaunch(lastExitUnclean: true)
        let later = CrashBlame(directory: dir)
        _ = later.recordLaunch(lastExitUnclean: false)
        XCTAssertTrue(later.isDisabled(a))
    }

    func testEndWithoutBeginIsHarmless() {
        let blame = CrashBlame(directory: dir)
        blame.end(a)
        XCTAssertEqual(blame.recordLaunch(lastExitUnclean: true), [])
    }

    func testUnreadableFilesCountAsEmpty() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("junk".utf8).write(to: dir.appendingPathComponent(CrashBlame.inProgressFile))
        try Data("junk".utf8).write(to: dir.appendingPathComponent(CrashBlame.disabledFile))
        let blame = CrashBlame(directory: dir)
        XCTAssertEqual(blame.recordLaunch(lastExitUnclean: true), [])
        XCTAssertTrue(blame.disabled.isEmpty)
    }
}
