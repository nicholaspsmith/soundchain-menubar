// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import CoreAudio
import Foundation
import SoundChainCore

struct CoreAudioError: LocalizedError {
    let what: String
    let status: OSStatus
    var errorDescription: String? { "\(what) failed (OSStatus \(status))" }
}

/// Thin wrappers over AudioObjectGet/SetPropertyData. Main thread.
enum AudioHW {
    static func addr(_ selector: AudioObjectPropertySelector,
                     _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func check(_ status: OSStatus, _ what: String) throws {
        guard status == noErr else { throw CoreAudioError(what: what, status: status) }
    }

    static func get<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, initial: T,
                       qualifier: UnsafeRawPointer? = nil, qualifierSize: UInt32 = 0, what: String) throws -> T {
        var address = addr(selector)
        var result = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &result) {
            AudioObjectGetPropertyData(object, &address, qualifierSize, qualifier, &size, $0)
        }
        try check(status, what)
        return result
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, what: String) throws -> String {
        var address = addr(selector)
        var result: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, &result), what)
        guard let result else { throw CoreAudioError(what: what, status: kAudioHardwareUnspecifiedError) }
        return result.takeRetainedValue() as String
    }

    static var system: AudioObjectID { AudioObjectID(kAudioObjectSystemObject) }

    static func defaultOutputDevice() throws -> AudioObjectID {
        let id: AudioObjectID = try get(system, kAudioHardwarePropertyDefaultOutputDevice,
                                        initial: AudioObjectID(kAudioObjectUnknown), what: "Reading the default output")
        guard id != kAudioObjectUnknown else {
            throw CoreAudioError(what: "Finding an output device", status: kAudioHardwareBadDeviceError)
        }
        return id
    }

    static func uid(_ device: AudioObjectID) throws -> String {
        try string(device, kAudioDevicePropertyDeviceUID, what: "Reading the output's UID")
    }

    static func name(_ device: AudioObjectID) -> String {
        (try? string(device, kAudioObjectPropertyName, what: "Reading the output's name")) ?? "Unknown output"
    }

    /// kAudioDeviceTransportType*; unknown (0) if it cannot be read.
    static func transportType(_ device: AudioObjectID) -> UInt32 {
        (try? get(device, kAudioDevicePropertyTransportType, initial: UInt32(0), what: "Reading the transport type")) ?? 0
    }

    /// Each output stream's channel count, in order.
    static func outputStreamChannels(_ device: AudioObjectID) -> [Int] {
        var address = addr(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else { return [] }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.map { Int($0.mNumberChannels) }
    }

    /// The output channels apps play stereo into (1-based); [] if unreadable.
    static func preferredStereoChannels(_ device: AudioObjectID) -> [UInt32] {
        var address = addr(kAudioDevicePropertyPreferredChannelsForStereo, kAudioObjectPropertyScopeOutput)
        var pair: (UInt32, UInt32) = (0, 0)
        var size = UInt32(MemoryLayout<(UInt32, UInt32)>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &pair) == noErr else { return [] }
        return [pair.0, pair.1]
    }

    /// Where stereo goes on this output device, or nil if it has no output channels.
    static func stereoRoute(_ device: AudioObjectID) -> StereoRoute? {
        StereoRoute.resolve(preferred: preferredStereoChannels(device), streamChannels: outputStreamChannels(device))
    }

    static func nominalSampleRate(_ device: AudioObjectID) throws -> Double {
        try get(device, kAudioDevicePropertyNominalSampleRate, initial: Float64(0), what: "Reading the sample rate")
    }

    static func bufferFrameSize(_ device: AudioObjectID) throws -> UInt32 {
        try get(device, kAudioDevicePropertyBufferFrameSize, initial: UInt32(0), what: "Reading the buffer size")
    }

    static func setBufferFrameSize(_ device: AudioObjectID, _ frames: UInt32) throws {
        var address = addr(kAudioDevicePropertyBufferFrameSize)
        var value = frames
        try check(AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value),
                  "Setting the buffer size")
    }

    /// SoundChain's own Core Audio process object, which the tap must exclude.
    /// Throws rather than return "unknown": tapping ourselves would feed back.
    static func ownProcessObject() throws -> AudioObjectID {
        var pid = getpid()
        let what = "Finding SoundChain's own audio process"
        let id: AudioObjectID = try withUnsafePointer(to: &pid) { pointer in
            try get(system, kAudioHardwarePropertyTranslatePIDToProcessObject,
                    initial: AudioObjectID(kAudioObjectUnknown),
                    qualifier: UnsafeRawPointer(pointer), qualifierSize: UInt32(MemoryLayout<pid_t>.size), what: what)
        }
        guard id != kAudioObjectUnknown else {
            throw CoreAudioError(what: what, status: kAudioHardwareIllegalOperationError)
        }
        return id
    }

    static func tapFormat(_ tap: AudioObjectID) throws -> AudioStreamBasicDescription {
        try get(tap, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription(), what: "Reading the tap format")
    }

    // MARK: Diagnostics (logging only)

    /// A UInt32 property as a string, or "?" if it cannot be read.
    static func flag(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String {
        (try? get(object, selector, initial: UInt32(0), what: "")).map(String.init) ?? "?"
    }

    /// One line describing a device: id, name, UID, transport, alive, running somewhere, rate.
    static func describe(_ device: AudioObjectID) -> String {
        let uid = (try? uid(device)) ?? "?"
        let transport = String(format: "%08x", transportType(device))
        let rate = (try? nominalSampleRate(device)).map { String($0) } ?? "?"
        return "#\(device) '\(name(device))' uid=\(uid) transport=\(transport) alive=\(flag(device, kAudioDevicePropertyDeviceIsAlive)) "
            + "runningSomewhere=\(flag(device, kAudioDevicePropertyDeviceIsRunningSomewhere)) rate=\(rate) "
            + "streams=\(outputStreamChannels(device)) stereo=\(preferredStereoChannels(device))"
    }

    /// The processes currently playing audio, with their PID, bundle ID and output devices.
    static func playingProcesses() -> [String] {
        var address = addr(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { process in
            guard (try? get(process, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0), what: "")) == 1 else { return nil }
            let pid = (try? get(process, kAudioProcessPropertyPID, initial: pid_t(0), what: "")) ?? 0
            let bundle = (try? string(process, kAudioProcessPropertyBundleID, what: "")) ?? "?"
            var devicesAddress = addr(kAudioProcessPropertyDevices, kAudioObjectPropertyScopeOutput)
            var devicesSize: UInt32 = 0
            var devices: [AudioObjectID] = []
            if AudioObjectGetPropertyDataSize(process, &devicesAddress, 0, nil, &devicesSize) == noErr, devicesSize > 0 {
                devices = [AudioObjectID](repeating: 0, count: Int(devicesSize) / MemoryLayout<AudioObjectID>.size)
                if AudioObjectGetPropertyData(process, &devicesAddress, 0, nil, &devicesSize, &devices) != noErr { devices = [] }
            }
            return "#\(process) pid=\(pid) \(bundle) devices=\(devices)"
        }
    }

    /// A four-char selector code as text, for logs.
    static func fourCC(_ code: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: code >> $0) }
        return bytes.allSatisfy { $0 >= 32 && $0 < 127 } ? String(decoding: bytes, as: UTF8.self) : String(code)
    }
}
