// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import XCTest
@testable import SoundChainCore

/// Bytes captured from a QuietComfort 35 II on 2026-10-08.
final class BoseLinkTests: XCTestCase {
    let phone: [UInt8] = [0xEC, 0x81, 0x50, 0x47, 0xE1, 0xA7]
    let thisMac: [UInt8] = [0xC0, 0xC7, 0xDB, 0x02, 0x8C, 0xDE]
    let otherMac: [UInt8] = [0xA0, 0x78, 0x17, 0x8A, 0x97, 0xF2]

    func testInitReply() {
        XCTAssertTrue(BoseLink.isInitReply([0x00, 0x01, 0x03, 0x05, 0x31, 0x2E, 0x30, 0x2E, 0x34]))
        XCTAssertFalse(BoseLink.isInitReply([0x00, 0x01, 0x04, 0x00]))  // error
        XCTAssertFalse(BoseLink.isInitReply([0x41, 0x54, 0x0D]))        // "AT\r": some other serial device
        XCTAssertFalse(BoseLink.isInitReply([]))
    }

    func testDeviceListSkipsCountByte() {
        let reply: [UInt8] = [0x04, 0x04, 0x03, 0x13, 0x03] + phone + thisMac + otherMac
        XCTAssertEqual(BoseLink.parseDeviceList(reply), [phone, thisMac, otherMac])
    }

    func testDeviceListIgnoresTrailingPartialAddress() {
        let reply: [UInt8] = [0x04, 0x04, 0x03, 0x09, 0x02] + phone + [0xC0, 0xC7]
        XCTAssertEqual(BoseLink.parseDeviceList(reply), [phone])
    }

    func testDeviceListRejectsOtherPackets() {
        XCTAssertEqual(BoseLink.parseDeviceList([0x04, 0x05, 0x03, 0x01, 0x00]), [])
        XCTAssertEqual(BoseLink.parseDeviceList([0x04, 0x04, 0x04, 0x00]), [])
    }

    func testInfoConnectedPhone() {
        let reply: [UInt8] = [0x04, 0x05, 0x03, 0x16] + phone + [0x01, 0x02, 0x03] + Array("Magooberstein".utf8)
        XCTAssertEqual(BoseLink.parseInfo(reply),
                       BoseLink.Device(address: phone, status: .connected, name: "Magooberstein"))
    }

    func testInfoThisMacAndNotConnected() {
        let mine: [UInt8] = [0x04, 0x05, 0x03, 0x17] + thisMac + [0x03, 0x01, 0x03] + Array("MacBook Pro M5".utf8)
        XCTAssertEqual(BoseLink.parseInfo(mine)?.status, .thisDevice)
        let away: [UInt8] = [0x04, 0x05, 0x03, 0x17] + otherMac + [0x00, 0x01, 0x03] + Array("MacBook Pro M1".utf8)
        XCTAssertEqual(BoseLink.parseInfo(away)?.status, .notConnected)
        XCTAssertEqual(BoseLink.parseInfo(away)?.name, "MacBook Pro M1")
    }

    func testInfoRejectsShortReply() {
        XCTAssertNil(BoseLink.parseInfo([0x04, 0x05, 0x03, 0x06] + phone))
        XCTAssertNil(BoseLink.parseInfo([0x04, 0x05, 0x04, 0x00]))
    }

    func testReplyFoundAfterAnEventPacket() {
        // An 11-byte event from the headphones, then the Info reply.
        let event: [UInt8] = [0x04, 0x09, 0x03, 0x07, 0x01] + phone
        let info: [UInt8] = [0x04, 0x05, 0x03, 0x16] + phone + [0x01, 0x02, 0x03] + Array("Magooberstein".utf8)
        XCTAssertEqual(BoseLink.parseInfo(event + info)?.name, "Magooberstein")
        XCTAssertEqual(BoseLink.parseDeviceList(event + [0x04, 0x04, 0x03, 0x07, 0x01] + phone), [phone])
        XCTAssertTrue(BoseLink.isInitReply(event + [0x00, 0x01, 0x03, 0x05, 0x31, 0x2E, 0x30, 0x2E, 0x34]))
        XCTAssertEqual(BoseLink.packets(in: event + info).count, 2)
        XCTAssertEqual(BoseLink.packets(in: [0x04, 0x05]), [])  // too short to be a packet
    }

    func testPackets() {
        XCTAssertEqual(BoseLink.infoPacket(address: phone), [0x04, 0x05, 0x01, 0x06] + phone)
        XCTAssertEqual(BoseLink.disconnectPacket(address: phone), [0x04, 0x02, 0x05, 0x06] + phone)
    }

    func testDisconnectOutcomeFromProcessingThenResult() {
        let reply: [UInt8] = [0x04, 0x02, 0x07, 0x07, 0x21] + phone + [0x04, 0x02, 0x06, 0x06] + phone
        XCTAssertEqual(BoseLink.disconnectOutcome(reply, address: phone), true)
    }

    func testDisconnectOutcomeError() {
        XCTAssertEqual(BoseLink.disconnectOutcome([0x04, 0x02, 0x04, 0x01, 0x05], address: phone), false)
        XCTAssertNil(BoseLink.disconnectOutcome([0x04, 0x02, 0x07, 0x07, 0x21] + phone, address: phone))
        XCTAssertNil(BoseLink.disconnectOutcome([], address: phone))
    }

    func testOthersAreTheConnectedDevicesThatAreNotThisMac() {
        let devices = [
            BoseLink.Device(address: phone, status: .connected, name: "Magooberstein"),
            BoseLink.Device(address: thisMac, status: .thisDevice, name: "MacBook Pro M5"),
            BoseLink.Device(address: otherMac, status: .notConnected, name: "MacBook Pro M1"),
        ]
        XCTAssertEqual(BoseLink.others(in: devices).map(\.name), ["Magooberstein"])
    }

    func testAddressString() {
        XCTAssertEqual(BoseLink.Device(address: phone, status: .connected, name: "").addressString, "EC:81:50:47:E1:A7")
    }
}
