// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import Foundation
import IOBluetooth
import OSLog
import SoundChainCore

/// Keeps Bose headphones to this Mac: while they are the output and the setting is
/// on, every other device connected to them (a phone, usually) is asked to leave,
/// now and every `interval`, since a phone comes back on its own. Main thread.
final class BoseExclusive {
    static let defaultsKey = "KeepHeadphonesExclusive"
    static let interval: TimeInterval = 30
    /// How long one reply, or the headphones' confirmation of a disconnect, may take.
    static let replyTimeout: TimeInterval = 3

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.defaultsKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.defaultsKey)
            lastEvent = nil
            apply()
        }
    }
    /// Skips a check while something else (Reconnect) has the device.
    var isBusy: () -> Bool = { false }
    /// Called on the main thread whenever `statusLine` may have changed.
    var onChange: (() -> Void)?

    private(set) var target: BluetoothReconnect.Target?
    /// The last thing worth telling: "Dropped Magooberstein from Osiris".
    private(set) var lastEvent: String?
    /// Addresses that turned out not to speak Bose's protocol; left alone from then on.
    private var unsupported: Set<String> = []
    private var timer: Timer?
    private var session: Session?
    private let log = Logger(subsystem: "com.nicholaspsmith.SoundChain", category: "bose")
    private var stopped = false
    /// Checks in a row that could not open the channel. bluetoothd can be left
    /// holding the channel for nobody (a process that died mid-open); only the
    /// headphones reconnecting clears it, so after a few the menu says so.
    private var unreachableRuns = 0
    static let unreachableRunsBeforeAdvice = 3
    /// The process's Bluetooth stack powers up on first use; an open sent in that
    /// same instant is dropped without a word. So the first use is a harmless one,
    /// and the first conversation waits.
    private var warmedUp = false
    static let warmUpDelay: TimeInterval = 3

    /// The menu's line about this, if there is one.
    var statusLine: String? {
        guard isEnabled, let target else { return nil }
        if unsupported.contains(target.address) { return "\(target.name) doesn't take Bose commands" }
        return lastEvent
    }

    /// Call when the output device may have changed.
    func outputChanged() {
        guard !stopped else { return }
        let next = BluetoothReconnect.currentTarget()
        let same = next?.address == target?.address
        target = next
        // Engine restarts on the same output change nothing; a new output starts over.
        if same, (timer != nil) == shouldRun { return }
        if !same { lastEvent = nil }
        apply()
    }

    private var shouldRun: Bool {
        guard isEnabled, let target else { return false }
        return !unsupported.contains(target.address)
    }

    /// On quit: no new conversation, and any open channel is closed now, while
    /// bluetoothd can still hear it. A process that dies with an open in flight
    /// leaves bluetoothd holding a link nobody owns, and the channel cannot be
    /// opened again until the headphones reconnect.
    func stop() {
        stopped = true
        timer?.invalidate()
        timer = nil
        session?.cancel()
        session = nil
    }

    private func apply() {
        timer?.invalidate()
        timer = nil
        guard shouldRun else {
            onChange?()
            return
        }
        if warmedUp {
            check()
        } else {
            warmedUp = true
            _ = IOBluetoothDevice.pairedDevices()
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.warmUpDelay) { [weak self] in
                guard let self, self.timer != nil else { return }
                self.check()
            }
        }
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in self?.check() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func check() {
        guard !stopped, session == nil, !isBusy(), let target else { return }
        session = Session(address: target.address) { [weak self] outcome in
            self?.session = nil
            self?.finish(outcome, target: target)
        }
    }

    private func finish(_ outcome: Session.Outcome, target: BluetoothReconnect.Target) {
        switch outcome {
        case .unsupported:
            unsupported.insert(target.address)
            timer?.invalidate()
            timer = nil
        case .unreachable(let why):
            log.error("couldn't reach \(target.name, privacy: .public)'s controls: \(why, privacy: .public)")
            unreachableRuns += 1
            if unreachableRuns >= Self.unreachableRunsBeforeAdvice {
                lastEvent = "Can't reach \(target.name)'s controls: turn them off and on"
            }
        case .dropped(let names):
            unreachableRuns = 0
            if lastEvent?.hasPrefix("Can't reach") == true { lastEvent = nil }
            if !names.isEmpty {
                lastEvent = "Dropped \(names.joined(separator: ", ")) from \(target.name)"
                log.notice("\(self.lastEvent!, privacy: .public)")
            } else {
                log.info("\(target.name, privacy: .public): nothing else connected")
            }
        case .failed(let names):
            unreachableRuns = 0
            lastEvent = "\(target.name) wouldn't drop \(names.joined(separator: ", "))"
            log.error("\(self.lastEvent!, privacy: .public)")
        }
        onChange?()
    }

    // MARK: One conversation with the headphones

    /// Opens the headphones' serial channel, lists what is connected, and sends a
    /// Disconnect for each device that is not this Mac. Event-driven on the main
    /// thread: IOBluetooth delivers its callbacks on the run loop of the thread that
    /// opened the channel, and only the main thread's is always running.
    private final class Session: NSObject, IOBluetoothRFCOMMChannelDelegate {
        enum Outcome {
            /// No Bose service, or the handshake came back wrong.
            case unsupported
            case unreachable(String)
            case dropped([String])
            case failed([String])
        }

        private enum Step {
            case handshake
            case list
            case info(remaining: [[UInt8]])
            case disconnect(remaining: [BoseLink.Device])
        }

        private let device: IOBluetoothDevice?
        private let completion: (Outcome) -> Void
        private var channel: IOBluetoothRFCOMMChannel?
        private var step = Step.handshake
        private var received: [UInt8] = []
        private var devices: [BoseLink.Device] = []
        private var dropped: [String] = []
        private var failed: [String] = []
        /// Fires when a reply has gone quiet, or when none came in time.
        private var settle: DispatchWorkItem?
        private var deadline: DispatchWorkItem?
        private var done = false

        init(address: String, completion: @escaping (Outcome) -> Void) {
            device = IOBluetoothDevice(addressString: address)
            self.completion = completion
            super.init()
            guard let device else { finish(.unreachable("not in Bluetooth")); return }
            if let id = Self.channel(in: device.services) {
                open(id)
            } else {
                device.performSDPQuery(self)
                arm(deadline: BoseExclusive.replyTimeout) { [weak self] in self?.finish(.unsupported) }
            }
        }

        @objc func sdpQueryComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
            guard !done else { return }
            deadline?.cancel()
            guard let id = Self.channel(in: device?.services) else { return finish(.unsupported) }
            open(id)
        }

        /// The first open after launch can be dropped without a word ("can only
        /// accept this command while in the powered on state": the process's
        /// Bluetooth stack is still waking), so an open that hears nothing is tried
        /// again; a real one completes within a tenth of a second.
        private func open(_ id: BluetoothRFCOMMChannelID, attempt: Int = 1) {
            var channel: IOBluetoothRFCOMMChannel?
            let status = device!.openRFCOMMChannelAsync(&channel, withChannelID: id, delegate: self)
            guard status == kIOReturnSuccess, let channel else {
                return finish(.unreachable(String(format: "channel %d open failed 0x%08x", Int(id), status)))
            }
            self.channel = channel
            arm(deadline: 2) { [weak self] in
                guard let self else { return }
                guard attempt < 3 else { return self.finish(.unreachable("channel open timed out")) }
                self.channel?.close()
                self.channel = nil
                self.open(id, attempt: attempt + 1)
            }
        }

        func rfcommChannelOpenComplete(_ channel: IOBluetoothRFCOMMChannel!, status: IOReturn) {
            guard !done else { return }
            deadline?.cancel()
            guard status == kIOReturnSuccess else {
                return finish(.unreachable(String(format: "channel open failed 0x%08x", status)))
            }
            send(BoseLink.initPacket)
        }

        func rfcommChannelClosed(_ channel: IOBluetoothRFCOMMChannel!) {
            guard !done else { return }
            finish(.unreachable("channel closed"))
        }

        func rfcommChannelData(_ channel: IOBluetoothRFCOMMChannel!, data: UnsafeMutableRawPointer!, length: Int) {
            guard !done else { return }
            received.append(contentsOf: UnsafeRawBufferPointer(start: data, count: length))
            if case .disconnect(let remaining) = step, let first = remaining.first,
               BoseLink.disconnectOutcome(received, address: first.address) != nil {
                settled()
                return
            }
            // A reply can arrive in pieces; it is complete once the line goes quiet.
            settle?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.settled() }
            settle = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
        }

        private func send(_ packet: [UInt8]) {
            received = []
            var bytes = packet
            guard let channel, channel.writeSync(&bytes, length: UInt16(bytes.count)) == kIOReturnSuccess else {
                return finish(.unreachable("write failed"))
            }
            arm(deadline: BoseExclusive.replyTimeout) { [weak self] in self?.settled() }
        }

        /// The current step's reply is in `received` (possibly empty): act on it.
        private func settled() {
            settle?.cancel()
            deadline?.cancel()
            let reply = received
            switch step {
            case .handshake:
                guard BoseLink.isInitReply(reply) else { return finish(.unsupported) }
                step = .list
                send(BoseLink.listDevicesPacket)
            case .list:
                next(info: BoseLink.parseDeviceList(reply))
            case .info(let remaining):
                if let info = BoseLink.parseInfo(reply) { devices.append(info) }
                next(info: Array(remaining.dropFirst()))
            case .disconnect(let remaining):
                let other = remaining[0]
                let name = other.name.isEmpty ? other.addressString : other.name
                if BoseLink.disconnectOutcome(reply, address: other.address) == true {
                    dropped.append(name)
                } else {
                    failed.append(name)
                }
                next(disconnect: Array(remaining.dropFirst()))
            }
        }

        private func next(info remaining: [[UInt8]]) {
            guard let address = remaining.first else {
                return next(disconnect: BoseLink.others(in: devices))
            }
            step = .info(remaining: remaining)
            send(BoseLink.infoPacket(address: address))
        }

        private func next(disconnect remaining: [BoseLink.Device]) {
            guard let other = remaining.first else {
                return finish(failed.isEmpty ? .dropped(dropped) : .failed(failed))
            }
            step = .disconnect(remaining: remaining)
            send(BoseLink.disconnectPacket(address: other.address))
        }

        private func arm(deadline seconds: TimeInterval, _ action: @escaping () -> Void) {
            deadline?.cancel()
            let work = DispatchWorkItem(block: action)
            deadline = work
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
        }

        /// Closes the channel without reporting.
        func cancel() {
            guard !done else { return }
            done = true
            settle?.cancel()
            deadline?.cancel()
            channel?.close()
            channel = nil
        }

        private func finish(_ outcome: Outcome) {
            guard !done else { return }
            cancel()
            completion(outcome)
        }

        private static func channel(in services: [Any]?) -> BluetoothRFCOMMChannelID? {
            for case let record as IOBluetoothSDPServiceRecord in services ?? []
            where record.getServiceName() == BoseLink.serviceName {
                var id: BluetoothRFCOMMChannelID = 0
                if record.getRFCOMMChannelID(&id) == kIOReturnSuccess { return id }
            }
            return nil
        }
    }
}
