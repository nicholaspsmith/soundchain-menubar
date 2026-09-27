// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import AppKit

/// SoundChain's menu-bar character: a caterpillar wearing black headphones. Its body
/// is always five segments long; the segments nearest the head light up, one per
/// running effect, and the rest stay a paler shade. Its colour is the app's state:
/// green processing, grey bypassed, red on an error. Every variant shares one 36x22
/// canvas so the menu bar never shifts. The drawing is laid out on a 28x22 grid and
/// scaled up so it fills nearly the whole bar height.
enum CaterpillarIcon {
    static let processing = NSColor(red: 0.30, green: 0.72, blue: 0.36, alpha: 1)
    static let bypassed = NSColor(white: 0.62, alpha: 1)
    static let error = NSColor(red: 0.90, green: 0.26, blue: 0.22, alpha: 1)
    static let headphones = NSColor(white: 0.07, alpha: 1)
    static let bodySegments = 5
    /// The artwork spans y 2.05…17.0 on its grid; this scale and offset stretch it to y 1…21.
    static let scale: CGFloat = 1.34
    static let offset = NSPoint(x: -0.3, y: 1 - 2.05 * 1.34)

    static func image(effects: Int, color: NSColor) -> NSImage {
        let lit = max(0, min(effects, bodySegments))
        let image = NSImage(size: NSSize(width: 36, height: 22), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current else { return false }
            let t = NSAffineTransform()
            t.translateX(by: offset.x, yBy: offset.y)
            t.scale(by: scale)
            t.concat()
            draw(ctx, lit: lit, color: color)
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func draw(_ ctx: NSGraphicsContext, lit: Int, color: NSColor) {
        let shade = color.blended(withFraction: 0.35, of: .black) ?? color
        let pale = color.blended(withFraction: 0.45, of: NSColor(white: 0.85, alpha: 1)) ?? color
        let groundY: CGFloat = 3.2

        // Body: five segments from just behind the head back to a tapered tail, with a
        // gentle wave. Drawn tail first so each segment overlaps the one behind it.
        let firstX: CGFloat = 15.4, spacing: CGFloat = 2.95
        for i in (0..<bodySegments).reversed() {
            let cx = firstX - CGFloat(i) * spacing
            let r: CGFloat = 3.25 - CGFloat(max(0, i - 2)) * 0.35          // taper the last two
            let lift: CGFloat = i % 2 == 0 ? 0.5 : 0                          // the wave
            let bottom = groundY + 0.6 + lift
            shade.set()
            let foot = NSBezierPath()
            foot.move(to: NSPoint(x: cx, y: bottom + 0.6))
            foot.line(to: NSPoint(x: cx, y: groundY - 0.6))
            foot.lineWidth = 1.1; foot.lineCapStyle = .round; foot.stroke()
            let fill = i < lit ? color : pale
            fill.set()
            let segment = NSBezierPath(ovalIn: NSRect(x: cx - r, y: bottom, width: r * 2, height: r * 2))
            segment.fill()
            shade.withAlphaComponent(0.8).set()
            segment.lineWidth = 0.5; segment.stroke()
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

        // Black headphones, with a faint light rim so they still read on a dark bar.
        let band = NSBezierPath()
        band.move(to: NSPoint(x: 17.4, y: 10.4))
        band.curve(to: NSPoint(x: 25.9, y: 12.4), controlPoint1: NSPoint(x: 17.6, y: 17.6), controlPoint2: NSPoint(x: 25.2, y: 18.2))
        band.lineCapStyle = .round
        let cup = NSBezierPath(roundedRect: NSRect(x: 16.1, y: 6.8, width: 3.4, height: 5.0), xRadius: 1.4, yRadius: 1.4)
        NSColor(white: 1, alpha: 0.35).set()
        band.lineWidth = 1.9; band.stroke()
        cup.lineWidth = 0.6; cup.stroke()
        headphones.set()
        band.lineWidth = 1.3; band.stroke()
        cup.fill()
    }
}
