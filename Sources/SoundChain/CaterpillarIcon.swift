// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import AppKit

/// SoundChain's menu-bar character, drawn in a storybook style (ink outlines, soft
/// shading): a caterpillar in black headphones. Its body is always five segments, all
/// the same colour as the head; each running effect puts a bright highlight on top of
/// a segment, counting back from the head. Its colour is the app's state. Every variant shares one 36x22pt canvas so
/// the menu bar never shifts.
///
/// Each variant is drawn once at 8x and downsampled (high-quality interpolation) to
/// 2x and 1x bitmaps, which smooths the small curves far better than drawing straight
/// at menu-bar size. Results are cached.
enum CaterpillarIcon {
    enum State: Hashable { case processing, bypassed, error }

    static let bodySegments = 5
    static let size = NSSize(width: 36, height: 22)
    static let supersample: CGFloat = 8
    /// The artwork is laid out on a 28x22 grid spanning y 2.05…17.0; this scale and
    /// offset stretch it to fill the canvas.
    static let gridScale: CGFloat = 1.34
    static let gridOffset = NSPoint(x: -0.3, y: 1 - 2.05 * 1.34)

    private struct Key: Hashable { let lit: Int; let state: State }
    private static var cache: [Key: NSImage] = [:]

    static func image(effects: Int, state: State) -> NSImage {
        let key = Key(lit: max(0, min(effects, bodySegments)), state: state)
        if let cached = cache[key] { return cached }
        let big = render(lit: key.lit, palette: Palette(state), scale: supersample)
        let image = NSImage(size: size)
        for scale in [2, 1] as [CGFloat] {
            if let rep = downsample(big, scale: scale) { image.addRepresentation(rep) }
        }
        image.isTemplate = false
        cache[key] = image
        return image
    }

    // MARK: Palette

    struct Palette {
        let light, mid, dark: NSColor          // lit segment / head shading
        static let ink = NSColor(red: 0.22, green: 0.14, blue: 0.09, alpha: 1)
        static let cheek = NSColor(red: 0.98, green: 0.66, blue: 0.68, alpha: 0.9)
        static let phones = NSColor(white: 0.07, alpha: 1)
        static let phonesSheen = NSColor(white: 0.42, alpha: 1)
        /// A faint light edge that keeps dark parts visible on a dark menu bar.
        static let rim = NSColor(white: 1, alpha: 0.4)
        /// The legs are thin, so their rim is nearly opaque.
        static let legRim = NSColor(white: 1, alpha: 0.85)

        init(_ state: State) {
            let base: NSColor
            switch state {
            case .processing: base = NSColor(red: 0.44, green: 0.74, blue: 0.33, alpha: 1)
            case .bypassed: base = NSColor(white: 0.64, alpha: 1)
            case .error: base = NSColor(red: 0.90, green: 0.33, blue: 0.26, alpha: 1)
            }
            let cream = NSColor(red: 0.97, green: 0.94, blue: 0.84, alpha: 1)
            light = base.blended(withFraction: 0.35, of: cream) ?? base
            mid = base
            dark = base.blended(withFraction: 0.30, of: .black) ?? base
        }
    }

    // MARK: Rendering

    private static func render(lit: Int, palette: Palette, scale: CGFloat) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                   pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        let ctx = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.current = ctx
        ctx.shouldAntialias = true
        let t = NSAffineTransform()
        t.scale(by: scale)
        t.translateX(by: gridOffset.x, yBy: gridOffset.y)
        t.scale(by: gridScale)
        t.concat()
        draw(lit: lit, palette: palette)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    private static func downsample(_ source: NSBitmapImageRep, scale: CGFloat) -> NSBitmapImageRep? {
        guard let cg = source.cgImage else { return nil }
        let w = Int(size.width * scale), h = Int(size.height * scale)
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let out = context.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: out)
        rep.size = size
        return rep
    }

    /// Fills `path` with a top-left-lit gradient, then outlines it in ink.
    private static func shaded(_ path: NSBezierPath, light: NSColor, dark: NSColor, ink: CGFloat = 0.55) {
        NSGradient(starting: light, ending: dark)?.draw(in: path, angle: -60)
        Palette.ink.set()
        path.lineWidth = ink
        path.stroke()
    }

    // MARK: Headphones

    /// The band as one cubic from the near earpad, over the crown, down behind the far
    /// side of the head. It is drawn in two pieces split at `bandSplit`, a point above
    /// the head: the back piece before the head (so the head hides its end) and the
    /// front piece after it. Both are black with round caps, so the join is invisible.
    static let band = (p0: NSPoint(x: 17.4, y: 10.4), p1: NSPoint(x: 17.6, y: 17.6),
                       p2: NSPoint(x: 25.0, y: 18.2), p3: NSPoint(x: 24.8, y: 12.0))
    static let bandSplit: CGFloat = 0.6
    static let cupRect = NSRect(x: 16.1, y: 6.8, width: 3.4, height: 5.0)

    /// The part of the band's cubic between parameters `t0` and `t1` (de Casteljau).
    static func bandPath(from t0: CGFloat, to t1: CGFloat) -> NSBezierPath {
        func split(_ p: [NSPoint], at t: CGFloat) -> (left: [NSPoint], right: [NSPoint]) {
            func lerp(_ a: NSPoint, _ b: NSPoint) -> NSPoint { NSPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t) }
            let a = lerp(p[0], p[1]), b = lerp(p[1], p[2]), c = lerp(p[2], p[3])
            let d = lerp(a, b), e = lerp(b, c), f = lerp(d, e)
            return ([p[0], a, d, f], [f, e, c, p[3]])
        }
        var pts = [band.p0, band.p1, band.p2, band.p3]
        pts = split(pts, at: t0).right
        pts = split(pts, at: t0 >= 1 ? 0 : (t1 - t0) / (1 - t0)).left
        let path = NSBezierPath()
        path.move(to: pts[0])
        path.curve(to: pts[3], controlPoint1: pts[1], controlPoint2: pts[2])
        path.lineCapStyle = .round
        return path
    }

    private static func draw(lit: Int, palette: Palette) {
        let groundY: CGFloat = 3.2

        // Light rims for the headphones go down first, so they show only against the
        // background (keeping the parts readable on a dark bar), never over the face.
        Palette.rim.set()
        let rimBand = bandPath(from: 0, to: 1)
        rimBand.lineWidth = 1.9; rimBand.stroke()
        let rimCup = NSBezierPath(roundedRect: cupRect.insetBy(dx: -0.3, dy: -0.3), xRadius: 1.6, yRadius: 1.6)
        rimCup.fill()

        // Body: tail first so each segment overlaps the one behind it.
        let firstX: CGFloat = 15.4, spacing: CGFloat = 2.95
        for i in (0..<bodySegments).reversed() {
            let cx = firstX - CGFloat(i) * spacing
            let r: CGFloat = 3.25 - CGFloat(max(0, i - 2)) * 0.35
            let lift: CGFloat = i % 2 == 0 ? 0.5 : 0
            let bottom = groundY + 0.6 + lift

            // leg with a little round foot, rimmed in light so it reads on a dark bar
            let leg = NSBezierPath()
            leg.move(to: NSPoint(x: cx, y: bottom + 0.8))
            leg.line(to: NSPoint(x: cx, y: groundY - 0.2))
            leg.lineCapStyle = .round
            let foot = NSBezierPath(ovalIn: NSRect(x: cx - 0.85, y: groundY - 0.75, width: 1.7, height: 1.0))
            Palette.legRim.set()
            leg.lineWidth = 1.45; leg.stroke()
            foot.lineWidth = 0.7; foot.stroke()
            Palette.ink.set()
            leg.lineWidth = 0.75; leg.stroke()
            foot.fill()

            let segment = NSBezierPath(ovalIn: NSRect(x: cx - r, y: bottom, width: r * 2, height: r * 2))
            shaded(segment, light: palette.light, dark: palette.dark)
            // each running effect: a bright highlight on top of its segment
            if i < lit {
                NSColor(white: 1, alpha: 0.85).set()
                NSBezierPath(ovalIn: NSRect(x: cx - r * 0.5, y: bottom + r * 1.25, width: r * 0.95, height: r * 0.5)).fill()
            }
        }

        // Back piece of the band: goes behind the head.
        Palette.phones.set()
        let back = bandPath(from: bandSplit, to: 1)
        back.lineWidth = 1.3; back.stroke()

        // Head.
        let head = NSBezierPath(ovalIn: NSRect(x: 16.6, y: 4.4, width: 10.2, height: 10.2))
        shaded(head, light: palette.light, dark: palette.dark, ink: 0.6)
        Palette.cheek.set()
        NSBezierPath(ovalIn: NSRect(x: 20.6, y: 6.2, width: 2.4, height: 1.5)).fill()

        // Eye: white, pupil, glint.
        let eye = NSBezierPath(ovalIn: NSRect(x: 22.3, y: 9.0, width: 2.7, height: 3.1))
        NSColor.white.set(); eye.fill()
        Palette.ink.set(); eye.lineWidth = 0.4; eye.stroke()
        NSBezierPath(ovalIn: NSRect(x: 23.5, y: 9.6, width: 1.3, height: 1.7)).fill()
        NSColor.white.set()
        NSBezierPath(ovalIn: NSRect(x: 24.0, y: 10.6, width: 0.5, height: 0.5)).fill()

        // Smile.
        Palette.ink.set()
        let smile = NSBezierPath()
        smile.move(to: NSPoint(x: 22.4, y: 7.1))
        smile.curve(to: NSPoint(x: 25.6, y: 7.7), controlPoint1: NSPoint(x: 23.4, y: 5.9), controlPoint2: NSPoint(x: 25.0, y: 6.2))
        smile.lineWidth = 0.55; smile.lineCapStyle = .round; smile.stroke()

        // Front piece of the band and the near earpad, over the head.
        Palette.phones.set()
        let front = bandPath(from: 0, to: bandSplit)
        front.lineWidth = 1.3; front.stroke()
        let cup = NSBezierPath(roundedRect: cupRect, xRadius: 1.4, yRadius: 1.4)
        NSGradient(starting: Palette.phonesSheen, ending: Palette.phones)?.draw(in: cup, angle: -70)
        // sheen along the band
        Palette.phonesSheen.withAlphaComponent(0.8).set()
        let sheen = NSBezierPath()
        sheen.move(to: NSPoint(x: 19.0, y: 14.8))
        sheen.curve(to: NSPoint(x: 22.6, y: 16.4), controlPoint1: NSPoint(x: 19.8, y: 16.0), controlPoint2: NSPoint(x: 21.2, y: 16.5))
        sheen.lineWidth = 0.35; sheen.lineCapStyle = .round; sheen.stroke()
    }
}
