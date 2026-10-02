// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import XCTest
@testable import SoundChainCore

final class BluetoothOutputTests: XCTestCase {
    func testAddressFromOutputUID() {
        XCTAssertEqual(BluetoothOutput.address(fromUID: "2C-41-A1-03-A0-DC:output"), "2c-41-a1-03-a0-dc")
    }

    func testAddressFromBareUID() {
        XCTAssertEqual(BluetoothOutput.address(fromUID: "2C-41-A1-03-A0-DC"), "2c-41-a1-03-a0-dc")
    }

    func testAddressWithColonSeparators() {
        XCTAssertEqual(BluetoothOutput.address(fromUID: "2c:41:a1:03:a0:dc:output"), "2c-41-a1-03-a0-dc")
    }

    func testNoAddressInOtherUIDs() {
        XCTAssertNil(BluetoothOutput.address(fromUID: "BuiltInSpeakerDevice"))
        XCTAssertNil(BluetoothOutput.address(fromUID: "AppleUSBAudioEngine:Generic:USB Audio:20134200:1"))
        XCTAssertNil(BluetoothOutput.address(fromUID: "506C5396-0000-0000-1423-010380794478"))
        XCTAssertNil(BluetoothOutput.address(fromUID: "2C-41-A1-03-A0"))
        XCTAssertNil(BluetoothOutput.address(fromUID: "ZZ-41-A1-03-A0-DC:output"))
    }

    func testBluetoothTransports() {
        XCTAssertTrue(BluetoothOutput.isBluetooth(transport: 0x626C7565))  // 'blue'
        XCTAssertTrue(BluetoothOutput.isBluetooth(transport: 0x626C6561))  // 'blea'
        XCTAssertFalse(BluetoothOutput.isBluetooth(transport: 0x626C746E)) // 'bltn' built-in
        XCTAssertFalse(BluetoothOutput.isBluetooth(transport: 0))
    }

    func testLogArgumentsCoverWindowBeforeReconnect() {
        let end = Date(timeIntervalSince1970: 1_790_000_000)
        let utc = TimeZone(identifier: "UTC")!
        let args = BluetoothOutput.logArguments(end: end, timeZone: utc)
        XCTAssertEqual(args.first, "show")
        XCTAssertEqual(value(after: "--start", in: args),
                       BluetoothOutput.logTimestamp(end.addingTimeInterval(-BluetoothOutput.logWindow), timeZone: utc))
        XCTAssertEqual(value(after: "--end", in: args), BluetoothOutput.logTimestamp(end, timeZone: utc))
        XCTAssertTrue(args.contains("--info"))
        XCTAssertTrue(args.contains("--debug"))
        let predicate = value(after: "--predicate", in: args) ?? ""
        for process in ["bluetoothd", "coreaudiod", "audioaccessoryd"] {
            XCTAssertTrue(predicate.contains("\"\(process)\""), process)
        }
    }

    func testLogTimestampFormat() {
        let date = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(BluetoothOutput.logTimestamp(date, timeZone: TimeZone(identifier: "UTC")!),
                       "1970-01-01 00:00:00+0000")
    }

    func testLogFileName() {
        let date = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(BluetoothOutput.logFileName(device: "Osiris", at: date, timeZone: TimeZone(identifier: "UTC")!),
                       "bluetooth-Osiris-19700101-000000.log")
        XCTAssertEqual(BluetoothOutput.logFileName(device: "Nick's AirPods/Pro", at: date,
                                                   timeZone: TimeZone(identifier: "UTC")!),
                       "bluetooth-Nick-s-AirPods-Pro-19700101-000000.log")
    }

    private func value(after flag: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
}
