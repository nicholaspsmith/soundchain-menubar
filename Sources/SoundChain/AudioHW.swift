// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import CoreAudio
import Foundation

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
}
