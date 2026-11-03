// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import StatusItemKit
import SwiftUI

/// SoundChain's Preferences window (menu ▸ Preferences…, ⌘,), StatusItemKit's
/// shared one: Start at Login and the version. It replaced the Settings
/// submenu, which held only those two; the effects, Bypass and Keep Headphones
/// to This Mac stay in the menu, as controls used day to day.
enum SoundChainPreferences {
    static let appName = "SoundChain"

    static func makePane() -> PreferencesPane {
        PreferencesPane(appName: appName) {
            PreferencesForm {
                Section {
                    StartAtLoginToggle()
                } header: {
                    Text("General")
                } footer: {
                    PreferencesNote("The effects, Bypass and Keep Headphones to This Mac are in the menu.")
                }
            }
        }
    }
}
