// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import AppKit
import Foundation
import StatusItemKit

LoginCLI.runIfRequested()

// A top-level `guard #available` does not refine availability for the rest of
// main.swift, so everything that needs macOS 14.2 lives in `Entry.run()`.
if #available(macOS 14.2, *) {
    Entry.run()
} else {
    FileHandle.standardError.write(Data("SoundChain needs macOS 14.2 or later.\n".utf8))
    exit(1)
}

@available(macOS 14.2, *)
enum Entry {
    static func run() {
        let arguments = CommandLine.arguments
        if arguments.contains("--selftest") {
            exit(SelfTest.run() ? 0 : 1)
        }
        if let flag = arguments.firstIndex(of: "--taptest") {
            let seconds = arguments.dropFirst(flag + 1).first.flatMap(Double.init) ?? 5
            exit(TapTest.run(seconds: seconds) ? 0 : 1)
        }
        let app = NSApplication.shared
        let delegate = AppController()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
