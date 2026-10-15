// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import Foundation

/// One running copy of SoundChain.
public struct AppInstance: Equatable {
    public let pid: Int32
    public let launched: Date?
    public init(pid: Int32, launched: Date?) {
        self.pid = pid
        self.launched = launched
    }
}

/// Only one SoundChain may tap the system's audio. Two taps on one output, each
/// muting what the other plays, created and torn down within seconds of each
/// other, is what preceded coreaudiod hanging on 2026-10-15 (parity's launch
/// check runs a second copy beside the installed one). So every copy but one
/// stands by, out of the audio path.
public enum InstanceElection {
    /// Whether `me` runs the audio: the earliest launched of all copies. A copy
    /// with no launch date counts as launched last; ties go to the lower pid, so
    /// exactly one copy is ever active.
    public static func isActive(_ me: AppInstance, among all: [AppInstance]) -> Bool {
        let everyone = all.filter { $0.pid != me.pid } + [me]
        let first = everyone.min { a, b in
            switch (a.launched, b.launched) {
            case let (x?, y?) where x != y: return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.pid < b.pid
            }
        }
        return first?.pid == me.pid
    }
}

/// Telling the user when macOS's audio service has stopped answering, which no
/// app can fix and only restarting coreaudiod does.
public enum CoreAudioHealth {
    public static let message = "macOS audio isn't responding"
    public static let restartCommand = "sudo killall coreaudiod"

    /// Whether a Core Audio call failed because coreaudiod never answered:
    /// MACH_SEND_TIMED_OUT or MACH_RCV_TIMED_OUT, after the HAL's 30 s wait.
    public static func isUnresponsive(_ status: Int32) -> Bool {
        status == 0x1000_0004 || status == 0x1000_4003
    }
}

/// Runs a call that may never return (one into a hung coreaudiod) off the main
/// thread, and reports on main whether it came back within `timeout`. While one
/// call is still out, `run` starts no other, so a hung service cannot collect a
/// thread per attempt.
public final class TimedProbe: @unchecked Sendable {
    private let timeout: TimeInterval
    private let queue: DispatchQueue
    private let work: () -> Void
    private let lock = NSLock()
    private var running = false

    public init(timeout: TimeInterval, queue: DispatchQueue = .global(qos: .utility), work: @escaping () -> Void) {
        self.timeout = timeout
        self.queue = queue
        self.work = work
    }

    /// Whether a call is still out (it may have been reported as no answer already).
    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    /// Starts the call and returns true, or returns false if one is still out.
    /// `done` runs once on main: true if the call came back in time, else false.
    @discardableResult
    public func run(_ done: @escaping (Bool) -> Void) -> Bool {
        lock.lock()
        let busy = running
        running = true
        lock.unlock()
        guard !busy else { return false }
        var reported = false   // main thread only
        let report = { (answered: Bool) in
            guard !reported else { return }
            reported = true
            done(answered)
        }
        queue.async {
            self.work()
            self.lock.lock()
            self.running = false
            self.lock.unlock()
            DispatchQueue.main.async { report(true) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { report(false) }
        return true
    }
}
