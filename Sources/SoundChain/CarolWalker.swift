// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import AppKit
import SoundChainCore
import StatusItemKit

/// Walks Carol to the sound SoundChain is playing: the louder the output, the
/// higher and faster she steps, and in silence she settles and stands. What
/// she moves to is delayed by the output's latency, so she keeps time with what
/// you hear rather than with what was just written. She looks at the level
/// `idleInterval` apart while standing and every `CaterpillarWalk.frameInterval`
/// while walking. Main thread.
@available(macOS 14.2, *)
final class CarolWalker {
    static let idleInterval: TimeInterval = 0.1

    /// Her walk; nil while she stands.
    private(set) var walk: CaterpillarWalk?
    /// Called each frame while she walks, and once more as she comes to rest.
    var onFrame: (() -> Void)?
    /// False while she must keep still (Reduce Motion, her run): she settles and stands.
    var mayWalk: () -> Bool = { true }

    private let takeLevel: () -> Float
    private let latency: () -> Double
    private var delay = LevelDelay()
    private var timer: Timer?
    private var timerIsFast = false
    private var lastStep: TimeInterval?

    /// `takeLevel` returns the loudest output RMS since it was last called;
    /// `latency` is the output's latency in seconds.
    init(takeLevel: @escaping () -> Float, latency: @escaping () -> Double) {
        self.takeLevel = takeLevel
        self.latency = latency
    }

    func start() { schedule(fast: false) }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func schedule(fast: Bool) {
        timer?.invalidate()
        let interval = fast ? CaterpillarWalk.frameInterval : Self.idleInterval
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.step() }
        timer.tolerance = interval / 10
        // Common modes: she keeps walking while a menu is open.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        timerIsFast = fast
    }

    private func step() {
        let now = ProcessInfo.processInfo.systemUptime
        let measured = SoundLevel.drive(rms: takeLevel())
        delay.push(measured, at: now)
        let allowed = mayWalk()
        let drive = allowed ? delay.value(at: now - latency()) : 0
        // Sound just written counts too, so she is up to speed by the time it is heard.
        let wanted = allowed && (measured > 0 || drive > 0)
        let elapsed = lastStep.map { now - $0 } ?? 0
        lastStep = now
        if var current = walk {
            current.advance(by: elapsed, drive: CGFloat(drive))
            walk = current.isResting && !wanted ? nil : current
            onFrame?()
        } else if wanted {
            walk = CaterpillarWalk()
        }
        if (walk != nil) != timerIsFast { schedule(fast: walk != nil) }
    }
}
