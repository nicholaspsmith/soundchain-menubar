// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import Foundation

/// Bose headphones share their radio between two sources at once (multipoint), and a
/// phone that is merely connected, playing nothing, can turn the Mac's audio into
/// crackle. The headphones take management commands over a Bluetooth serial channel
/// from any connected device, in Bose's own packet format (BMAP, as the Bose app
/// speaks it); SoundChain uses it to ask them to drop every other device.
///
/// A packet is `[block, function, flags, length, payload…]`; the low nibble of the
/// flags is the operator. This is the bytes only: `BoseExclusive` does the Bluetooth.
public enum BoseLink {
    /// Operators, in the low nibble of a packet's flags byte.
    public enum Operator: UInt8 {
        case set = 0, get = 1, setGet = 2, status = 3, error = 4, start = 5, result = 6, processing = 7
    }

    /// The SDP service the headphones publish for this channel (Bose's own name).
    public static let serviceName = "SPP Dev"

    /// What the headphones say about a device they have paired with.
    public enum DeviceStatus: Equatable {
        case notConnected
        case connected
        /// The device asking: this Mac.
        case thisDevice
        case other(UInt8)

        init(_ raw: UInt8) {
            switch raw {
            case 0: self = .notConnected
            case 1: self = .connected
            case 3: self = .thisDevice
            default: self = .other(raw)
            }
        }
    }

    public struct Device: Equatable {
        public let address: [UInt8]
        public let status: DeviceStatus
        public let name: String

        public init(address: [UInt8], status: DeviceStatus, name: String) {
            self.address = address
            self.status = status
            self.name = name
        }

        public var addressString: String {
            address.map { String(format: "%02X", $0) }.joined(separator: ":")
        }
    }

    // MARK: Packets

    /// The handshake every session starts with; the reply carries the firmware version.
    public static let initPacket: [UInt8] = [0x00, 0x01, 0x01, 0x00]
    /// Asks for the addresses of every paired device.
    public static let listDevicesPacket: [UInt8] = [0x04, 0x04, 0x01, 0x00]

    public static func infoPacket(address: [UInt8]) -> [UInt8] {
        [0x04, 0x05, 0x01, 0x06] + address
    }

    public static func disconnectPacket(address: [UInt8]) -> [UInt8] {
        [0x04, 0x02, 0x05, 0x06] + address
    }

    // MARK: Replies

    /// True when the handshake reply is well formed: anything else on the channel is
    /// not a Bose headset speaking this protocol.
    public static func isInitReply(_ data: [UInt8]) -> Bool {
        data.count >= 4 && data[0] == 0 && data[1] == 1 && data[2] & 0x0F == Operator.status.rawValue
    }

    /// The paired addresses in a ListDevices reply. The payload's first byte is a
    /// count of some kind that does not match the connected devices, so it is skipped
    /// and each device's status is asked for separately.
    public static func parseDeviceList(_ data: [UInt8]) -> [[UInt8]] {
        guard data.count >= 5, data[0] == 4, data[1] == 4, data[2] & 0x0F == Operator.status.rawValue else { return [] }
        let payload = data.dropFirst(4).prefix(Int(data[3])).dropFirst()
        return stride(from: payload.startIndex, to: payload.endIndex, by: 6).compactMap { start in
            let address = payload[start..<min(start + 6, payload.endIndex)]
            return address.count == 6 ? Array(address) : nil
        }
    }

    /// An Info reply: `04 05 03 len <address> <status> <2 bytes> <name>`.
    public static func parseInfo(_ data: [UInt8]) -> Device? {
        guard data.count >= 13, data[0] == 4, data[1] == 5, data[2] & 0x0F == Operator.status.rawValue else { return nil }
        let payload = data.dropFirst(4).prefix(Int(data[3]))
        guard payload.count >= 9 else { return nil }
        let address = Array(payload.prefix(6))
        let status = DeviceStatus(payload[payload.startIndex + 6])
        let name = String(decoding: payload.dropFirst(9), as: UTF8.self)
        return Device(address: address, status: status, name: name)
    }

    /// Whether a Disconnect reply (possibly several packets run together) ends in
    /// a result or an error for `address`.
    public static func disconnectOutcome(_ data: [UInt8], address: [UInt8]) -> Bool? {
        var i = 0
        var outcome: Bool?
        while i + 4 <= data.count {
            let length = Int(data[i + 3])
            let end = min(i + 4 + length, data.count)
            if data[i] == 4, data[i + 1] == 2 {
                switch Operator(rawValue: data[i + 2] & 0x0F) {
                case .result: outcome = true
                case .error: outcome = false
                default: break
                }
            }
            i = end
        }
        return outcome
    }

    /// The devices to drop: connected, and not the one asking.
    public static func others(in devices: [Device]) -> [Device] {
        devices.filter { $0.status == .connected }
    }
}
