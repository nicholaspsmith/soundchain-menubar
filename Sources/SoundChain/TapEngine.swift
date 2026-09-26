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

/// Owns the global process tap, the private aggregate device that pairs it with the
/// current default output, and the IO proc that runs the chain. Main thread, except
/// `render`, which runs on the audio thread.
@available(macOS 14.2, *)
final class TapEngine {
    enum State: Equatable {
        case stopped
        case running(device: String, sampleRate: Double, bufferFrames: Int)
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
        let me = try AudioHW.ownProcessObject()

        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [me])
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
            TapEngine.render(source: source, interleaved: interleaved,
                             input: input, inputTime: inputTime, output: output)
        }, "Installing the audio callback")
        try AudioHW.check(AudioDeviceStart(aggregateID, procID), "Starting audio")
        state = .running(device: deviceName, sampleRate: rate, bufferFrames: frames)
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
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    // MARK: Audio thread

    /// The IO proc body. No allocation, no locks: the snapshot is used unretained
    /// (it outlives any cycle; see ChainRunner.retireDelay).
    private static func render(source: SnapshotSource, interleaved: Bool,
                               input: UnsafePointer<AudioBufferList>, inputTime: UnsafePointer<AudioTimeStamp>,
                               output: UnsafeMutablePointer<AudioBufferList>) {
        let out = UnsafeMutableAudioBufferListPointer(output)
        guard let raw = source.load() else { ChannelMap.zero(out); return }
        Unmanaged<RenderChain>.fromOpaque(raw)._withUnsafeGuaranteedRef { chain in
            let inputList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            let frames = TapInput.read(inputList, interleaved: interleaved,
                                       left: chain.inputLeft, right: chain.inputRight, capacity: chain.maxFrames)
            guard frames > 0 else { ChannelMap.zero(out); return }
            let result = chain.process(frames: frames, timestamp: inputTime)
            SampleGuard.sanitize(left: result.left, right: result.right, frames: frames)
            ChannelMap.write(left: result.left, right: result.right, frames: frames, to: out)
        }
    }

    // MARK: Device changes

    private func listen() {
        addListener(AudioHW.system, kAudioHardwarePropertyDefaultOutputDevice)
        if outputDevice != kAudioObjectUnknown {
            addListener(outputDevice, kAudioDevicePropertyNominalSampleRate)
            addListener(outputDevice, kAudioDevicePropertyDeviceIsAlive)
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.scheduleRestart(force: true) }
    }

    private func addListener(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) {
        var address = AudioHW.addr(selector)
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
        guard case .running(_, let rate, _) = state else { return true }
        guard let current = try? AudioHW.defaultOutputDevice(), current == outputDevice else { return true }
        return (try? AudioHW.nominalSampleRate(outputDevice)) != rate
    }
}
