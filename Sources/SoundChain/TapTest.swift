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
        var loudest: Float = 0, drives: [Double] = []
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            runner.tick()
            if case .running = engine.state { sawRunning = true }
            let level = engine.takeLevel()
            loudest = max(loudest, level)
            if sawRunning { drives.append(SoundLevel.drive(rms: level)) }
        }
        let callbacks = engine.callbackCount, latency = engine.outputLatency
        engine.stop()
        print("IO callbacks: \(callbacks)")
        // How Carol would walk to what played: her drive (0 stands, 1 full stride) every 0.1 s.
        let sorted = drives.sorted()
        func percentile(_ p: Double) -> Double { sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] }
        print(String(format: "Loudest output: %.0f dBFS RMS · output latency %.0f ms",
                     20 * log10(max(loudest, 1e-9)), latency * 1000))
        print(String(format: "Carol's drive: 10%% %.2f · median %.2f · 90%% %.2f",
                     percentile(0.1), percentile(0.5), percentile(0.9)))

        let ok = me != nil && sawRunning && callbacks > 0
        print(ok ? "Tap test passed." : "Tap test FAILED.")
        return ok
    }
}
