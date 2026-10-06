// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import AppKit
import Foundation
import SoundChainCore

/// System-audio capture permission ("System Audio Recording Only", under Privacy &
/// Security ▸ Screen & System Audio Recording). There is no public preflight API, so
/// this calls TCC's private functions through dlopen, as AudioCap does. If they
/// cannot be found the status is `.unknown` and the app simply tries the tap.
enum AudioPermission {
    typealias Status = CapturePermission

    private static let service = "kTCCServiceAudioCapture" as CFString
    private typealias PreflightFn = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias RequestFn = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void
    private static let tcc = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    static func status() -> Status {
        guard let handle = tcc, let symbol = dlsym(handle, "TCCAccessPreflight") else { return .unknown }
        switch unsafeBitCast(symbol, to: PreflightFn.self)(service, nil) {
        case 0: return .authorized
        case 1: return .denied
        default: return .unknown
        }
    }

    /// Shows the system prompt if the user has not decided yet. `completion` runs on main.
    static func request(_ completion: @escaping (Bool) -> Void) {
        guard let handle = tcc, let symbol = dlsym(handle, "TCCAccessRequest") else {
            DispatchQueue.main.async { completion(true) }
            return
        }
        unsafeBitCast(symbol, to: RequestFn.self)(service, nil) { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    static func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }
}
