// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import Foundation
import IOKit

/// Whether a UAD DSP is attached. UA's kext publishes one `UAD2Pcie2` service per
/// DSP device (an Apollo or Satellite over Thunderbolt, or a PCIe card), whatever
/// audio device is current. Watched with IOKit notifications. Main thread.
final class UADHardware {
    static let serviceClass = "com_uaudio_driver_UAD2Pcie2"

    var isPresent: Bool { count > 0 }
    var onChange: (() -> Void)?
    private var count = 0
    private var port: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []

    /// Counts services from the notifications themselves: a terminated service can
    /// still show up in a fresh match while its termination is being delivered.
    func start() {
        guard port == nil, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        self.port = port
        IONotificationPortSetDispatchQueue(port, .main)
        let context = Unmanaged.passUnretained(self).toOpaque()
        let arrived: IOServiceMatchingCallback = { context, iterator in
            guard let context else { return }
            Unmanaged<UADHardware>.fromOpaque(context).takeUnretainedValue().adjust(by: drain(iterator))
        }
        let left: IOServiceMatchingCallback = { context, iterator in
            guard let context else { return }
            Unmanaged<UADHardware>.fromOpaque(context).takeUnretainedValue().adjust(by: -drain(iterator))
        }
        for (type, callback) in [(kIOFirstMatchNotification, arrived), (kIOTerminatedNotification, left)] {
            var iterator: io_iterator_t = 0
            guard IOServiceAddMatchingNotification(port, type, IOServiceMatching(Self.serviceClass),
                                                   callback, context, &iterator) == KERN_SUCCESS else { continue }
            iterators.append(iterator)
            // Draining arms the notification; the first-match iterator starts out
            // holding the services already there.
            let existing = drain(iterator)
            if type == kIOFirstMatchNotification { count += existing }
        }
    }

    private func adjust(by delta: Int) {
        let was = isPresent
        count = max(0, count + delta)
        if isPresent != was { onChange?() }
    }

    deinit {
        iterators.forEach { IOObjectRelease($0) }
        if let port { IONotificationPortDestroy(port) }
    }
}

/// Releases every service an IOKit iterator holds and returns how many there were.
private func drain(_ iterator: io_iterator_t) -> Int {
    var n = 0
    while case let service = IOIteratorNext(iterator), service != 0 {
        n += 1
        IOObjectRelease(service)
    }
    return n
}
