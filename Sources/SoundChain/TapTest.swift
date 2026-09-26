// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import Foundation
import SoundChainCore

/// `SoundChain --taptest [seconds]`: runs the real tap with an empty (pass-through)
/// chain. Play audio while it runs: it must sound unchanged, with no echo, doubling
/// or feedback. Switch the output device mid-run to exercise the restart path.
@available(macOS 14.2, *)
enum TapTest {
    static func run(seconds: Double) -> Bool {
        let me = try? AudioHW.ownProcessObject()
        print("Own audio process object: \(me.map(String.init) ?? "NOT FOUND")")
        print("Capture permission: \(AudioPermission.status())")
        print("Note: IO starts only once some app plays audio (tap auto-start), so play something.")

        let runner = ChainRunner()
        runner.sync(to: Chain())
        let engine = TapEngine(source: runner.source)
        engine.onFormat = { runner.setFormat($0) }
        engine.onStateChange = { print("State: \($0)") }
        engine.start()

        var sawRunning = false
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            runner.tick()
            if case .running = engine.state { sawRunning = true }
        }
        let callbacks = engine.callbackCount
        engine.stop()
        print("IO callbacks: \(callbacks)")

        let ok = me != nil && sawRunning && callbacks > 0
        print(ok ? "Tap test passed." : "Tap test FAILED.")
        return ok
    }
}
