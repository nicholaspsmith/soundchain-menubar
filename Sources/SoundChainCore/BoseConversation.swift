// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

/// One back-and-forth with a pair of headphones.
public protocol BoseConversation: AnyObject {
    func start()
    /// Stops it without reporting a result.
    func cancel()
}

/// Holds the one conversation allowed at a time.
public final class BoseConversationSlot {
    public private(set) var current: BoseConversation?

    public init() {}

    /// Held before it starts: one that fails at once reports `finished` from
    /// inside `start()`, and held afterwards it would block every later check.
    public func begin(_ conversation: BoseConversation) {
        current = conversation
        conversation.start()
    }

    public func finished(_ conversation: BoseConversation) {
        if current === conversation { current = nil }
    }

    public func cancel() {
        let conversation = current
        current = nil
        conversation?.cancel()
    }
}

extension BoseLink {
    /// Whether to talk to the headphones now. Opening a channel to headphones that
    /// are off makes the Mac search for them, so a check waits until they are back.
    public static func shouldCheck(stopped: Bool, busy: Bool, inConversation: Bool, connected: Bool) -> Bool {
        !stopped && !busy && !inConversation && connected
    }
}
