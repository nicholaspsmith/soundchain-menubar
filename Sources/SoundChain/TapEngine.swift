// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import AppKit
import CAtomics
import CoreAudio
import Foundation
import SoundChainCore

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
        teardown()
        removeListeners()
        do {
            try build()
        } catch {
            teardown()
            state = .failed(error.localizedDescription)
        }
        listen()
    }

    func stop() {
        teardown()
        removeListeners()
        state = .stopped
    }

    // MARK: Build and teardown

    private func build() throws {
        outputDevice = try AudioHW.defaultOutputDevice()
        let outputUID = try AudioHW.uid(outputDevice)
        let deviceName = AudioHW.name(outputDevice)
        let warning = OutputCheck.warning(transportType: AudioHW.transportType(outputDevice))
        let me = try AudioHW.ownProcessObject()
        guard let route = AudioHW.stereoRoute(outputDevice) else {
            throw CoreAudioError(what: "Finding the output's channels", status: kAudioHardwareBadStreamError)
        }
        self.route = route

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
        NSLog("SoundChain: input streams %d, tap-only usage set: %d", count, status)
    }

    private func teardown() {
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
        ) { [weak self] _ in self?.scheduleRestart(force: true) }
    }

    private func addListener(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                             _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) {
        var address = AudioHW.addr(selector, scope)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.scheduleRestart(force: false) }
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
            if forced || self.needsRestart() { self.start() }
        }
    }

    private func needsRestart() -> Bool {
        guard case .running(_, _, let rate, _) = state else { return true }
        guard let current = try? AudioHW.defaultOutputDevice(), current == outputDevice else { return true }
        if AudioHW.stereoRoute(outputDevice) != route { return true }
        return (try? AudioHW.nominalSampleRate(outputDevice)) != rate
    }
}
