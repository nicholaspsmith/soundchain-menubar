// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import Foundation
import XCTest
@testable import SoundChainCore

final class InstanceElectionTests: XCTestCase {
    private let early = Date(timeIntervalSince1970: 1000), late = Date(timeIntervalSince1970: 2000)

    func testAloneIsActive() {
        let me = AppInstance(pid: 10, launched: late)
        XCTAssertTrue(InstanceElection.isActive(me, among: [me]))
        XCTAssertTrue(InstanceElection.isActive(me, among: []))
    }

    // The copy already running keeps the audio; a later one (parity's launch
    // check, a second double-click) stands by.
    func testTheEarliestLaunchedIsActive() {
        let installed = AppInstance(pid: 50, launched: early), check = AppInstance(pid: 40, launched: late)
        XCTAssertTrue(InstanceElection.isActive(installed, among: [installed, check]))
        XCTAssertFalse(InstanceElection.isActive(check, among: [installed, check]))
    }

    // Exactly one wins whatever the dates, so two copies never both stand by.
    func testTiesAndMissingDatesStillPickOne() {
        let a = AppInstance(pid: 7, launched: early), b = AppInstance(pid: 9, launched: early)
        XCTAssertTrue(InstanceElection.isActive(a, among: [a, b]))
        XCTAssertFalse(InstanceElection.isActive(b, among: [a, b]))
        let dated = AppInstance(pid: 30, launched: late), undated = AppInstance(pid: 20, launched: nil)
        XCTAssertTrue(InstanceElection.isActive(dated, among: [dated, undated]))
        XCTAssertFalse(InstanceElection.isActive(undated, among: [dated, undated]))
    }
}

final class CoreAudioHealthTests: XCTestCase {
    // What a call into a hung coreaudiod returns after its 30 s wait.
    func testMachTimeoutsMeanCoreAudioIsNotResponding() {
        XCTAssertTrue(CoreAudioHealth.isUnresponsive(268_435_460))   // MACH_SEND_TIMED_OUT, seen 2026-10-15
        XCTAssertTrue(CoreAudioHealth.isUnresponsive(268_451_843))   // MACH_RCV_TIMED_OUT
        XCTAssertFalse(CoreAudioHealth.isUnresponsive(0))
        XCTAssertFalse(CoreAudioHealth.isUnresponsive(560_947_818))  // kAudioHardwareBadObjectError ('!obj')
    }

    func testTheAdviceNamesTheFix() {
        XCTAssertEqual(CoreAudioHealth.restartCommand, "sudo killall coreaudiod")
        XCTAssertFalse(CoreAudioHealth.message.isEmpty)
    }
}

final class TimedProbeTests: XCTestCase {
    func testAnAnswerInTimeIsReported() {
        let probe = TimedProbe(timeout: 1) {}
        let done = expectation(description: "answered")
        XCTAssertTrue(probe.run { answered in XCTAssertTrue(answered); done.fulfill() })
        wait(for: [done], timeout: 2)
    }

    // A call that never comes back is reported as no answer after the timeout,
    // without waiting for it, and only once.
    func testNoAnswerIsReportedAtTheTimeout() {
        let release = DispatchSemaphore(value: 0)
        let probe = TimedProbe(timeout: 0.1) { release.wait() }
        let done = expectation(description: "timed out")
        let started = Date()
        XCTAssertTrue(probe.run { answered in
            XCTAssertFalse(answered)
            XCTAssertLessThan(Date().timeIntervalSince(started), 1)
            done.fulfill()
        })
        wait(for: [done], timeout: 2)
        release.signal()
    }

    // While the last call is still stuck, no second one is started: a hung
    // coreaudiod must not collect a thread per tick.
    func testOneProbeAtATime() {
        let release = DispatchSemaphore(value: 0)
        let probe = TimedProbe(timeout: 0.05) { release.wait() }
        let first = expectation(description: "first reported")
        XCTAssertTrue(probe.run { _ in first.fulfill() })
        wait(for: [first], timeout: 2)
        XCTAssertTrue(probe.isRunning)
        XCTAssertFalse(probe.run { _ in XCTFail("a second probe ran") })
        release.signal()
        let finished = expectation(description: "stuck call returned")
        DispatchQueue.global().async {
            while probe.isRunning { usleep(5_000) }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 2)
        let again = expectation(description: "runs again")
        XCTAssertTrue(probe.run { _ in again.fulfill() })
        wait(for: [again], timeout: 2)
    }
}
