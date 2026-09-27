// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import Foundation

public protocol FlagStore: AnyObject {
    func bool(forKey key: String) -> Bool
    func integer(forKey key: String) -> Int
    func set(_ value: Any?, forKey key: String)
}

extension UserDefaults: FlagStore {}

/// Detects a crash loop. A "running" marker is set at launch and cleared on a clean
/// quit; finding it still set at the next launch means the last run ended uncleanly.
/// After `threshold` unclean exits in a row the app starts with master bypass on, so
/// a plugin that crashes the app cannot keep crashing it.
public final class CrashGuard {
    public static let threshold = 2
    static let runningKey = "CrashGuardRunning"
    static let uncleanKey = "CrashGuardUncleanExits"

    private let store: FlagStore

    public init(store: FlagStore) { self.store = store }

    public var uncleanExits: Int { store.integer(forKey: Self.uncleanKey) }

    /// Set by `recordLaunch`: whether the previous run ended without a clean quit.
    public private(set) var lastExitWasUnclean = false

    /// Call once, first thing at launch. Returns true when the app must start bypassed.
    public func recordLaunch() -> Bool {
        lastExitWasUnclean = store.bool(forKey: Self.runningKey)
        if lastExitWasUnclean {
            store.set(uncleanExits + 1, forKey: Self.uncleanKey)
        }
        store.set(true, forKey: Self.runningKey)
        return uncleanExits >= Self.threshold
    }

    /// Call once the app has run long enough to count as stable (60 s).
    public func markStable() { store.set(0, forKey: Self.uncleanKey) }

    public func recordCleanExit() {
        store.set(false, forKey: Self.runningKey)
        store.set(0, forKey: Self.uncleanKey)
    }
}
