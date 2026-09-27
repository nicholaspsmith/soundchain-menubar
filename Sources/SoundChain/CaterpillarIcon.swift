// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import AppKit

/// SoundChain's menu-bar character: a caterpillar wearing headphones. It grows one
/// body segment per running effect (up to five) and its colour is the app's state:
/// green processing, grey bypassed, red on an error. Every variant shares one 28x22
/// canvas so the menu bar never shifts.
enum CaterpillarIcon {
    static let processing = NSColor(red: 0.30, green: 0.72, blue: 0.36, alpha: 1)
    static let bypassed = NSColor(white: 0.62, alpha: 1)
    static let error = NSColor(red: 0.90, green: 0.26, blue: 0.22, alpha: 1)
    static let maxSegments = 5

    static func image(effects: Int, color: NSColor) -> NSImage {
        let segments = max(1, min(effects, maxSegments))
        let image = NSImage(size: NSSize(width: 28, height: 22), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current else { return false }
            draw(ctx, segments: segments, color: color)
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func draw(_ ctx: NSGraphicsContext, segments: Int, color: NSColor) {
        let shade = color.blended(withFraction: 0.35, of: .black) ?? color
        let groundY: CGFloat = 3.2

        // Body: segments from just behind the head back towards the tail.
        let firstX: CGFloat = 15.2, lastX: CGFloat = 3.6
        let spacing = segments > 1 ? min(4.6, (firstX - lastX) / CGFloat(segments - 1)) : 0
        for i in (0..<segments).reversed() {
            let cx = firstX - CGFloat(i) * spacing
            let r: CGFloat = i == segments - 1 && segments > 1 ? 2.7 : 3.2
            // a tiny foot under each segment
            shade.set()
            let foot = NSBezierPath()
            foot.move(to: NSPoint(x: cx, y: groundY + 1.2))
            foot.line(to: NSPoint(x: cx, y: groundY - 0.6))
            foot.lineWidth = 1.1; foot.lineCapStyle = .round; foot.stroke()
            color.set()
            NSBezierPath(ovalIn: NSRect(x: cx - r, y: groundY + 0.6, width: r * 2, height: r * 2)).fill()
            // segment seam, so neighbours read as separate links
            shade.withAlphaComponent(0.8).set()
            let seam = NSBezierPath(ovalIn: NSRect(x: cx - r, y: groundY + 0.6, width: r * 2, height: r * 2))
            seam.lineWidth = 0.5; seam.stroke()
        }

        // Head.
        let head = NSRect(x: 16.6, y: 4.4, width: 10.2, height: 10.2)
        color.set()
        NSBezierPath(ovalIn: head).fill()
        // Eye and smile.
        ctx.compositingOperation = .destinationOut
        NSBezierPath(ovalIn: NSRect(x: 22.6, y: 9.6, width: 2.1, height: 2.3)).fill()
        ctx.compositingOperation = .sourceOver
        shade.set()
        let smile = NSBezierPath()
        smile.move(to: NSPoint(x: 22.3, y: 7.0))
        smile.curve(to: NSPoint(x: 25.4, y: 7.6), controlPoint1: NSPoint(x: 23.3, y: 5.9), controlPoint2: NSPoint(x: 24.8, y: 6.2))
        smile.lineWidth = 0.7; smile.lineCapStyle = .round; smile.stroke()

        // Headphones: a band over the crown and a cup over the ear.
        shade.set()
        let band = NSBezierPath()
        band.move(to: NSPoint(x: 17.4, y: 10.4))
        band.curve(to: NSPoint(x: 25.9, y: 12.4), controlPoint1: NSPoint(x: 17.6, y: 17.6), controlPoint2: NSPoint(x: 25.2, y: 18.2))
        band.lineWidth = 1.3; band.lineCapStyle = .round; band.stroke()
        NSBezierPath(roundedRect: NSRect(x: 16.3, y: 7.0, width: 3.0, height: 4.6), xRadius: 1.3, yRadius: 1.3).fill()
    }
}
