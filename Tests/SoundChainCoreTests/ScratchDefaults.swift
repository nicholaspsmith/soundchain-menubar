// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import XCTest

extension XCTestCase {
    /// A defaults suite of the test's own, kept in the temporary directory.
    /// A named suite lives in ~/Library/Preferences, and cfprefsd writes its
    /// plist there after the test ends even once the domain is removed, so
    /// every run used to leave `<prefix>-<UUID>.plist` behind. A suite named
    /// by an absolute path is stored at that path instead.
    func scratchDefaults(_ prefix: String) -> UserDefaults {
        let plist = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString).plist")
        let defaults = UserDefaults(suiteName: plist.path)!
        addTeardownBlock {
            defaults.removePersistentDomain(forName: plist.path)
            try? FileManager.default.removeItem(at: plist)
        }
        return defaults
    }
}
