// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import AppKit
import CAtomics
import CoreAudio
import Foundation
import os
import SoundChainCore

/// Engine lifecycle: why it rebuilt, what the device looked like, how long each step took.
/// Read with `log show --predicate 'subsystem == "com.nicholaspsmith.SoundChain"' --info`.
let engineLog = Logger(subsystem: "com.nicholaspsmith.SoundChain", category: "engine")

/// Owns the process tap on the current default output, the private aggregate device
/// that pairs it with that output, and the IO proc that runs the chain. Main thread, except
/// `render`, which runs on the audio thread.
@available(macOS 14.2, *)
final class TapEngine {
    enum State: Equatable {
        case stopped
        /// `warning` is set when the output is one you probably cannot hear.
        case running(device: String, warning: String?, sampleRate: Double, bufferFrames: Int)
        case failed(String)
    }

    static let requestedBufferFrames: UInt32 = 512
    static let minimumMaxFrames = 4096

    private(set) var state: State = .stopped {
        didSet { if state != oldValue { onStateChange?(state) } }
    }
    var onStateChange: ((State) -> Void)?
    /// Called with the format the chain must run at, while no IO is running.
    var onFormat: ((RenderFormat) -> Void)?

    private let source: SnapshotSource
    private let callbacks = sc_counter_create()
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var outputDevice = AudioObjectID(kAudioObjectUnknown)
    private var route: StereoRoute?
    private var listeners: [(object: AudioObjectID, address: AudioObjectPropertyAddress,
                             block: AudioObjectPropertyListenerBlock)] = []
    private var wakeObserver: NSObjectProtocol?
    private var restartPending = false
    private var restartForced = false

    init(source: SnapshotSource) { self.source = source }

    deinit {
        teardown()
        removeListeners()
        sc_counter_destroy(callbacks)
    }

    /// IO cycles run so far; for --taptest and diagnostics.
    var callbackCount: Int64 { sc_counter_get(callbacks) }

    /// Builds everything for the current default output and starts audio. On failure
    /// the state is `.failed` and listeners stay installed, so the next device change retries.
    func start() {
        engineLog.notice("start: tearing down tap #\(self.tapID) aggregate #\(self.aggregateID)")
        teardown()
        removeListeners()
        let began = Date()
        do {
            try build()
            engineLog.notice("start: running after \(Self.ms(since: began), privacy: .public)")
            logPlayingProcesses("after build")
            let built = aggregateID
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, self.aggregateID == built else { return }
                engineLog.notice("start +3s: \(self.callbackCount) IO callbacks so far")
                self.logPlayingProcesses("3s after build")
            }
        } catch {
            engineLog.error("start: failed after \(Self.ms(since: began), privacy: .public): \(error.localizedDescription, privacy: .public)")
            teardown()
            state = .failed(error.localizedDescription)
        }
        listen()
    }

    func stop() {
        engineLog.notice("stop")
        teardown()
        removeListeners()
        state = .stopped
    }

    // MARK: Build and teardown

    private func build() throws {
        var step = Date()
        func stepDone(_ what: String) {
            engineLog.notice("build: \(what, privacy: .public) (\(Self.ms(since: step), privacy: .public))")
            step = Date()
        }
        outputDevice = try AudioHW.defaultOutputDevice()
        engineLog.notice("build: output \(AudioHW.describe(self.outputDevice), privacy: .public)")
        let outputUID = try AudioHW.uid(outputDevice)
        let deviceName = AudioHW.name(outputDevice)
        let warning = OutputCheck.warning(transportType: AudioHW.transportType(outputDevice))
        let me = try AudioHW.ownProcessObject()
        guard let route = AudioHW.stereoRoute(outputDevice) else {
            throw CoreAudioError(what: "Finding the output's channels", status: kAudioHardwareBadStreamError)
        }
        self.route = route
        engineLog.notice("build: own process #\(me), route \(String(describing: route), privacy: .public)")

        // Tap the output stream itself, channel for channel, rather than a stereo
        // mixdown: a mixdown takes channels 1 and 2 as front left and right and scales
        // any other pair down, and apps play into the device's preferred pair (5 and 6
        // on an Apollo). What comes in is exactly what apps sent that stream.
        let description = CATapDescription(excludingProcesses: [me], deviceUID: outputUID, stream: UInt(route.tapStream))
        description.uuid = UUID()
        description.name = "SoundChain"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        try AudioHW.check(AudioHardwareCreateProcessTap(description, &tapID), "Creating the system audio tap")
        stepDone("created tap #\(tapID) \(description.uuid.uuidString) on stream \(route.tapStream)")

        let tapFormat = try AudioHW.tapFormat(tapID)
        guard tapFormat.mFormatID == kAudioFormatLinearPCM,
              tapFormat.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              tapFormat.mBitsPerChannel == 32 else {
            throw CoreAudioError(what: "Using the tap (it is not 32-bit float)", status: kAudioHardwareUnsupportedOperationError)
        }
        let interleaved = tapFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        let tapChannels = Int(tapFormat.mChannelsPerFrame)

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "SoundChain",
            kAudioAggregateDeviceUIDKey: "com.nicholaspsmith.SoundChain.aggregate.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        try AudioHW.check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID),
                          "Creating the aggregate device")
        stepDone("created aggregate #\(aggregateID)")

        try? AudioHW.setBufferFrameSize(aggregateID, Self.requestedBufferFrames)
        let frames = Int(try AudioHW.bufferFrameSize(aggregateID))
        let rate = try AudioHW.nominalSampleRate(aggregateID)
        onFormat?(RenderFormat(sampleRate: rate, maxFrames: max(Self.minimumMaxFrames, frames)))

        let source = self.source, callbacks = self.callbacks
        try AudioHW.check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { _, input, inputTime, output, _ in
            sc_counter_increment(callbacks)
            TapEngine.render(source: source, interleaved: interleaved, tapChannels: tapChannels, route: route,
                             input: input, inputTime: inputTime, output: output)
        }, "Installing the audio callback")
        if let procID { Self.useOnlyTapInput(aggregateID, procID) }
        try AudioHW.check(AudioDeviceStart(aggregateID, procID), "Starting audio")
        stepDone("started IO: \(rate) Hz, \(frames) frames, tap \(tapChannels) ch \(interleaved ? "interleaved" : "planar")")
        state = .running(device: deviceName, warning: warning, sampleRate: rate, bufferFrames: frames)
    }

    /// The aggregate's input side holds the output device's own input streams (a
    /// Scarlett's mic inputs, say) followed by the tap's stream. Leaving the device's
    /// streams on makes coreaudiod demand Microphone permission, so turn off every
    /// input stream except the last one, which is the tap.
    private static func useOnlyTapInput(_ device: AudioObjectID, _ procID: AudioDeviceIOProcID) {
        var address = AudioHW.addr(kAudioDevicePropertyIOProcStreamUsage, kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 8)
        defer { raw.deallocate() }
        let usage = raw.bindMemory(to: AudioHardwareIOProcStreamUsage.self, capacity: 1)
        usage.pointee.mIOProc = unsafeBitCast(procID, to: UnsafeMutableRawPointer.self)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else { return }
        let count = Int(usage.pointee.mNumberStreams)
        guard count > 1 else { return }
        let flags = raw.advanced(by: MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn)!)
            .bindMemory(to: UInt32.self, capacity: count)
        for i in 0..<count { flags[i] = i == count - 1 ? 1 : 0 }
        let status = AudioObjectSetPropertyData(device, &address, 0, nil, size, raw)
        engineLog.notice("build: input streams \(count), tap-only usage set: \(status)")
    }

    private func teardown() {
        if aggregateID != kAudioObjectUnknown || tapID != kAudioObjectUnknown {
            engineLog.notice("teardown: aggregate #\(self.aggregateID) tap #\(self.tapID) after \(self.callbackCount) IO callbacks")
        }
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        route = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    // MARK: Audio thread

    /// The IO proc body. No allocation, no locks: the snapshot is used unretained
    /// (it outlives any cycle; see ChainRunner.retireDelay).
    private static func render(source: SnapshotSource, interleaved: Bool, tapChannels: Int, route: StereoRoute,
                               input: UnsafePointer<AudioBufferList>, inputTime: UnsafePointer<AudioTimeStamp>,
                               output: UnsafeMutablePointer<AudioBufferList>) {
        let out = UnsafeMutableAudioBufferListPointer(output)
        source.beginCycle()
        defer { source.endCycle() }
        guard let raw = source.load() else { ChannelMap.zero(out); return }
        Unmanaged<RenderChain>.fromOpaque(raw)._withUnsafeGuaranteedRef { chain in
            let inputList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard let tap = TapStream(inputList, interleaved: interleaved, channels: tapChannels) else {
                ChannelMap.zero(out); return
            }
            let frames = TapInput.read(tap, leftChannel: route.leftInTap, rightChannel: route.rightInTap,
                                       left: chain.inputLeft, right: chain.inputRight, capacity: chain.maxFrames)
            guard frames > 0 else { ChannelMap.zero(out); return }
            let result = chain.process(frames: frames, timestamp: inputTime)
            SampleGuard.sanitize(left: result.left, right: result.right, frames: frames)
            ChannelMap.write(left: result.left, right: result.right, frames: frames, to: out,
                             route: route, passthrough: tap)
        }
    }

    // MARK: Device changes

    private func listen() {
        addListener(AudioHW.system, kAudioHardwarePropertyDefaultOutputDevice)
        if outputDevice != kAudioObjectUnknown {
            addListener(outputDevice, kAudioDevicePropertyNominalSampleRate)
            addListener(outputDevice, kAudioDevicePropertyDeviceIsAlive)
            addListener(outputDevice, kAudioDevicePropertyPreferredChannelsForStereo, kAudioObjectPropertyScopeOutput)
            addListener(outputDevice, kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput)
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            engineLog.notice("event: wake")
            self?.scheduleRestart(force: true)
        }
    }

    private func addListener(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                             _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) {
        var address = AudioHW.addr(selector, scope)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            engineLog.notice("event: '\(AudioHW.fourCC(selector), privacy: .public)' on #\(object)")
            self?.scheduleRestart(force: false)
        }
        if AudioObjectAddPropertyListenerBlock(object, &address, DispatchQueue.main, block) == noErr {
            listeners.append((object, address, block))
        }
    }

    private func removeListeners() {
        for listener in listeners {
            var address = listener.address
            AudioObjectRemovePropertyListenerBlock(listener.object, &address, DispatchQueue.main, listener.block)
        }
        listeners.removeAll()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
    }

    /// Debounces bursts of device notifications into one restart, and skips the
    /// restart when nothing that matters changed (building the aggregate itself can
    /// fire notifications; restarting on those would loop).
    private func scheduleRestart(force: Bool) {
        restartForced = restartForced || force
        guard !restartPending else { return }
        restartPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            let forced = self.restartForced
            self.restartPending = false
            self.restartForced = false
            let reason = forced ? "forced" : self.restartReason()
            engineLog.notice("restart check: \(reason ?? "nothing changed, staying put", privacy: .public)")
            if reason != nil { self.start() }
        }
    }

    /// Why the engine must rebuild, or nil when nothing that matters changed.
    private func restartReason() -> String? {
        guard case .running(_, _, let rate, _) = state else { return "not running (\(state))" }
        let current = try? AudioHW.defaultOutputDevice()
        guard let current, current == outputDevice else {
            return "default output #\(outputDevice) -> \(current.map { AudioHW.describe($0) } ?? "none")"
        }
        if AudioHW.stereoRoute(outputDevice) != route { return "stereo route changed" }
        let now = try? AudioHW.nominalSampleRate(outputDevice)
        return now != rate ? "sample rate \(rate) -> \(now.map { String($0) } ?? "?")" : nil
    }

    private func logPlayingProcesses(_ when: String) {
        let processes = AudioHW.playingProcesses()
        engineLog.notice("processes playing \(when, privacy: .public): \(processes.isEmpty ? "none" : processes.joined(separator: "; "), privacy: .public)")
    }

    private static func ms(since date: Date) -> String {
        String(format: "%.0f ms", Date().timeIntervalSince(date) * 1000)
    }
}
