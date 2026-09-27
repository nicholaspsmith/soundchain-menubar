// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import AVFoundation
import AudioToolbox
import SoundChainCore

enum ComponentScanner {
    /// Every installed effect Audio Unit (plain and MIDI-controlled effects), flagged
    /// with any load error seen this session.
    static func effects(failures: [ComponentID: String], disabled: Set<ComponentID> = []) -> [CatalogEntry] {
        [kAudioUnitType_Effect, kAudioUnitType_MusicEffect].flatMap { type -> [CatalogEntry] in
            let query = AudioComponentDescription(componentType: type, componentSubType: 0,
                                                  componentManufacturer: 0, componentFlags: 0, componentFlagsMask: 0)
            return AVAudioUnitComponentManager.shared().components(matching: query).map { component in
                let id = ComponentID(component.audioComponentDescription)
                return CatalogEntry(component: id, name: component.name,
                                    manufacturer: component.manufacturerName, loadError: failures[id],
                                    disabled: disabled.contains(id))
            }
        }
    }
}
