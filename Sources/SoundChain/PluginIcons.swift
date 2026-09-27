// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import AppKit
import SoundChainCore

/// Icons for plugins in the chain window and Add picker: the icon file a plugin's
/// bundle declares (`CFBundleIconFile`, when that file exists), else a music-note
/// tile. Most plugins ship no icon, and macOS's generic Audio Unit icon is a folder,
/// so the tile is the honest default. Main thread.
enum PluginIcons {
    private static var cache: [ComponentID: NSImage] = [:]

    /// Component → bundle icon file, built once by scanning the Audio Unit folders.
    private static let iconFiles: [ComponentID: URL] = {
        var map: [ComponentID: URL] = [:]
        let dirs = [URL(fileURLWithPath: "/Library/Audio/Plug-Ins/Components"),
                    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Audio/Plug-Ins/Components")]
        for dir in dirs {
            let bundles = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for bundle in bundles where bundle.pathExtension == "component" {
                guard let info = NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")),
                      let icon = iconFile(in: bundle, info: info) else { continue }
                for entry in (info["AudioComponents"] as? [[String: Any]]) ?? [] {
                    if let type = entry["type"] as? String, let subtype = entry["subtype"] as? String,
                       let maker = entry["manufacturer"] as? String,
                       let id = ComponentID(type, subtype, maker) {
                        map[id] = icon
                    }
                }
            }
        }
        return map
    }()

    private static func iconFile(in bundle: URL, info: NSDictionary) -> URL? {
        guard let name = info["CFBundleIconFile"] as? String, !name.isEmpty else { return nil }
        var file = bundle.appendingPathComponent("Contents/Resources").appendingPathComponent(name)
        if file.pathExtension.isEmpty { file.appendPathExtension("icns") }
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    /// A rounded tile with a white music note, drawn at any size.
    static let musicTile: NSImage = {
        let image = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            let tile = NSBezierPath(roundedRect: rect.insetBy(dx: 3, dy: 3), xRadius: 14, yRadius: 14)
            NSGradient(starting: NSColor(red: 0.98, green: 0.36, blue: 0.47, alpha: 1),
                       ending: NSColor(red: 0.82, green: 0.18, blue: 0.40, alpha: 1))?.draw(in: tile, angle: -90)
            let config = NSImage.SymbolConfiguration(pointSize: 34, weight: .semibold)
                .applying(.init(paletteColors: [.white]))
            if let note = NSImage(systemSymbolName: "music.note", accessibilityDescription: "Audio Unit")?
                .withSymbolConfiguration(config) {
                let s = note.size
                note.draw(in: NSRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2, width: s.width, height: s.height))
            }
            return true
        }
        return image
    }()

    static func icon(for id: ComponentID) -> NSImage {
        if let cached = cache[id] { return cached }
        let image = iconFiles[id].flatMap { NSImage(contentsOf: $0) } ?? musicTile
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
