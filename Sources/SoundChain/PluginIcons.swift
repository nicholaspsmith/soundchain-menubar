// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import AVFoundation
import AppKit
import SoundChainCore
import UniformTypeIdentifiers

/// Icons for plugins in the chain window and Add picker: the component's own icon,
/// else the generic macOS Audio Unit icon. Main thread.
enum PluginIcons {
    private static var cache: [ComponentID: NSImage] = [:]

    static let generic: NSImage = NSWorkspace.shared.icon(for: UTType(filenameExtension: "component") ?? .bundle)

    static func icon(for id: ComponentID) -> NSImage {
        if let cached = cache[id] { return cached }
        let component = AVAudioUnitComponentManager.shared()
            .components(matching: id.audioComponentDescription).first
        let image = component?.icon ?? generic
        cache[id] = image
        return image
    }

    /// An image view of `size` points showing the plugin's icon.
    static func view(for id: ComponentID, size: CGFloat) -> NSImageView {
        let view = NSImageView(image: icon(for: id))
        view.imageScaling = .scaleProportionallyUpOrDown
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: size).isActive = true
        view.heightAnchor.constraint(equalToConstant: size).isActive = true
        return view
    }
}
