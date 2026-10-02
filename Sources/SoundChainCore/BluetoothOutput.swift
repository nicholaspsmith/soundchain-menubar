// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import Foundation

/// Bluetooth headphones can go silent while macOS still shows them as the current,
/// running output; disconnecting and reconnecting brings the sound back. SoundChain
/// offers that reconnect, and first saves the recent Bluetooth and audio logs so the
/// cause can be found later.
public enum BluetoothOutput {
    /// kAudioDeviceTransportTypeBluetooth ('blue') and ...BluetoothLE ('blea').
    static let transports: Set<UInt32> = [0x626C_7565, 0x626C_6561]

    public static func isBluetooth(transport: UInt32) -> Bool { transports.contains(transport) }

    /// The device address in a Bluetooth output's Core Audio UID
    /// ("2C-41-A1-03-A0-DC:output"), lowercased and dash-separated as IOBluetooth
    /// takes it; nil if the UID does not start with one.
    public static func address(fromUID uid: String) -> String? {
        let octets = uid.split(omittingEmptySubsequences: false) { $0 == "-" || $0 == ":" }.prefix(6)
        guard octets.count == 6,
              octets.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isHexDigit) }) else { return nil }
        return octets.joined(separator: "-").lowercased()
    }

    /// How far back the saved log reaches before the reconnect.
    public static let logWindow: TimeInterval = 5 * 60

    /// Arguments for `/usr/bin/log` covering the `logWindow` before `end`.
    public static func logArguments(end: Date, timeZone: TimeZone = .current) -> [String] {
        ["show", "--style", "compact", "--info", "--debug",
         "--start", logTimestamp(end.addingTimeInterval(-logWindow), timeZone: timeZone),
         "--end", logTimestamp(end, timeZone: timeZone),
         "--predicate", #"process IN {"bluetoothd", "coreaudiod", "audioaccessoryd"}"#]
    }

    /// The `log show` date format, with its zone so it is read unambiguously.
    public static func logTimestamp(_ date: Date, timeZone: TimeZone = .current) -> String {
        formatter("yyyy-MM-dd HH:mm:ssZ", timeZone).string(from: date)
    }

    public static func logFileName(device: String, at date: Date, timeZone: TimeZone = .current) -> String {
        let safe = String(device.map { $0.isLetter || $0.isNumber ? $0 : "-" })
        return "bluetooth-\(safe)-\(formatter("yyyyMMdd-HHmmss", timeZone).string(from: date)).log"
    }

    private static func formatter(_ format: String, _ timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter
    }
}
