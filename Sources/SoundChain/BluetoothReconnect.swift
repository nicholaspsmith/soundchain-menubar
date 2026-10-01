// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import CoreAudio
import Foundation
import IOBluetooth
import SoundChainCore

/// Disconnects and reconnects the current Bluetooth output, after saving the recent
/// Bluetooth and audio logs to ~/Library/Logs/SoundChain. Main thread.
final class BluetoothReconnect {
    struct Target {
        let name: String
        let address: String
    }

    static let logDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/SoundChain", isDirectory: true)
    /// How long to wait for the link to drop before reconnecting anyway.
    static let disconnectTimeout: TimeInterval = 5

    private(set) var inProgress = false
    /// Called on the main thread with a one-line result for the menu.
    var onFinish: ((String) -> Void)?

    /// The current output, if it is a Bluetooth device we can address.
    static func currentTarget() -> Target? {
        guard let device = try? AudioHW.defaultOutputDevice(),
              BluetoothOutput.isBluetooth(transport: AudioHW.transportType(device)),
              let uid = try? AudioHW.uid(device),
              let address = BluetoothOutput.address(fromUID: uid) else { return nil }
        return Target(name: AudioHW.name(device), address: address)
    }

    func reconnect(_ target: Target) {
        guard !inProgress else { return }
        guard let device = IOBluetoothDevice(addressString: target.address) else {
            onFinish?("Couldn't find \(target.name) in Bluetooth")
            return
        }
        inProgress = true
        let now = Date()
        // The log is read on its own; the reconnect does not wait for it.
        let logURL = Self.logDirectory.appendingPathComponent(BluetoothOutput.logFileName(device: target.name, at: now))
        Self.saveLog(end: now, to: logURL)

        device.closeConnection()
        waitForDisconnect(device, deadline: now.addingTimeInterval(Self.disconnectTimeout)) { [weak self] in
            let status = device.openConnection()
            self?.inProgress = false
            self?.onFinish?(status == kIOReturnSuccess
                            ? "Reconnected \(target.name)"
                            : "Couldn't reconnect \(target.name) (\(String(format: "0x%08x", status)))")
        }
    }

    private func waitForDisconnect(_ device: IOBluetoothDevice, deadline: Date, then: @escaping () -> Void) {
        if !device.isConnected() || Date() >= deadline {
            // A moment for the headphones to settle before they are asked back.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: then)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.waitForDisconnect(device, deadline: deadline, then: then)
        }
    }

    /// Runs `log show` for the window before `end` and writes it to `url`. Failures
    /// are logged, never shown: the reconnect is what the user asked for.
    private static func saveLog(end: Date, to url: URL) {
        DispatchQueue.global(qos: .utility).async {
            do {
                try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: url.path, contents: nil)
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
                process.arguments = BluetoothOutput.logArguments(end: end)
                process.standardOutput = handle
                process.standardError = handle
                try process.run()
                process.waitUntilExit()
            } catch {
                NSLog("SoundChain: couldn't save the Bluetooth log: %@", error.localizedDescription)
            }
        }
    }
}
