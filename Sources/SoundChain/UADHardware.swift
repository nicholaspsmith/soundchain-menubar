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

    private(set) var isPresent = false
    var onChange: (() -> Void)?
    private var port: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []

    func start() {
        guard port == nil, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        self.port = port
        IONotificationPortSetDispatchQueue(port, .main)
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOServiceMatchingCallback = { context, iterator in
            guard let context else { return }
            Unmanaged<UADHardware>.fromOpaque(context).takeUnretainedValue().drain(iterator)
        }
        for type in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            var iterator: io_iterator_t = 0
            guard IOServiceAddMatchingNotification(port, type, IOServiceMatching(Self.serviceClass),
                                                   callback, context, &iterator) == KERN_SUCCESS else { continue }
            iterators.append(iterator)
            // Arms the notification and consumes what is already there.
            while case let service = IOIteratorNext(iterator), service != 0 { IOObjectRelease(service) }
        }
        recount()
    }

    private func drain(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 { IOObjectRelease(service) }
        recount()
    }

    /// Recounts rather than tracking arrivals and departures, which can come in either order.
    private func recount() {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(Self.serviceClass),
                                           &iterator) == KERN_SUCCESS else { return }
        var count = 0
        while case let service = IOIteratorNext(iterator), service != 0 {
            count += 1
            IOObjectRelease(service)
        }
        IOObjectRelease(iterator)
        let present = count > 0
        guard present != isPresent else { return }
        isPresent = present
        onChange?()
    }

    deinit {
        iterators.forEach { IOObjectRelease($0) }
        if let port { IONotificationPortDestroy(port) }
    }
}
