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
        XCTAssertEqual(blame.recordLaunch(lastExitUnclean: true).disabled, [])
        XCTAssertTrue(blame.disabled.isEmpty)
    }

    func testAnOperationStillInProgressAtACrashDisablesThatComponent() {
        CrashBlame(directory: dir).begin(a)                         // then the app dies
        let next = CrashBlame(directory: dir)
        XCTAssertEqual(next.recordLaunch(lastExitUnclean: true).disabled, [a])
        XCTAssertTrue(next.isDisabled(a))
        XCTAssertFalse(next.isDisabled(b))
    }

    func testFinishedOperationsAreNotBlamed() {
        let blame = CrashBlame(directory: dir)
        blame.begin(a); blame.begin(b); blame.end(a)
        XCTAssertEqual(CrashBlame(directory: dir).recordLaunch(lastExitUnclean: true).disabled, [b])
    }

    func testACleanExitBlamesNothingAndClearsTheMarker() {
        CrashBlame(directory: dir).begin(a)
        XCTAssertEqual(CrashBlame(directory: dir).recordLaunch(lastExitUnclean: false).disabled, [])
        XCTAssertEqual(CrashBlame(directory: dir).recordLaunch(lastExitUnclean: true).disabled, [])
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
        XCTAssertEqual(blame.recordLaunch(lastExitUnclean: true).disabled, [])
    }

    func testUnreadableFilesCountAsEmpty() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("junk".utf8).write(to: dir.appendingPathComponent(CrashBlame.inProgressFile))
        try Data("junk".utf8).write(to: dir.appendingPathComponent(CrashBlame.disabledFile))
        let blame = CrashBlame(directory: dir)
        XCTAssertEqual(blame.recordLaunch(lastExitUnclean: true).disabled, [])
        XCTAssertTrue(blame.disabled.isEmpty)
    }
}

final class CrashBlameStepTests: XCTestCase {
    private var dir: URL!
    private let a = ComponentID("aufx", "aaaa", "test")!
    private let b = ComponentID("aufx", "bbbb", "test")!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("CrashBlameStepTests-\(UUID().uuidString)")
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testACrashWhileRestoringSettingsIsReportedAsARestoreNotADisable() {
        CrashBlame(directory: dir).begin(a, step: .restore)
        let next = CrashBlame(directory: dir)
        let result = next.recordLaunch(lastExitUnclean: true)
        XCTAssertEqual(result.disabled, [])
        XCTAssertEqual(result.badState, [a])
        XCTAssertFalse(next.isDisabled(a))
    }

    func testMarkersThatOutliveTheirStepAreExpired() {
        let start = Date(timeIntervalSince1970: 1000)
        let blame = CrashBlame(directory: dir)
        blame.begin(a, step: .editor, at: start)
        blame.begin(b, step: .load, at: start.addingTimeInterval(25))
        blame.expire(olderThan: CrashBlame.markerLifetime, now: start.addingTimeInterval(30))
        XCTAssertEqual(CrashBlame(directory: dir).recordLaunch(lastExitUnclean: true).disabled, [b])
    }

    func testEnableTakesAComponentOffTheDisabledList() {
        CrashBlame(directory: dir).begin(a)
        let blame = CrashBlame(directory: dir)
        _ = blame.recordLaunch(lastExitUnclean: true)
        blame.enable(a)
        XCTAssertFalse(blame.isDisabled(a))
        XCTAssertFalse(CrashBlame(directory: dir).isDisabled(a))
    }

    func testEndOnlyClearsTheMatchingStep() {
        let blame = CrashBlame(directory: dir)
        blame.begin(a, step: .load)
        blame.begin(a, step: .editor)
        blame.end(a, step: .editor)
        XCTAssertEqual(CrashBlame(directory: dir).recordLaunch(lastExitUnclean: true).disabled, [a])
    }
}
