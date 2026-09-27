// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import AppKit

/// SoundChain's menu-bar character, drawn in a storybook style (ink outlines, soft
/// shading): a caterpillar in black headphones. Its body is always five segments;
/// the segments nearest the head light up, one per running effect, and the rest stay
/// pale. Its colour is the app's state. Every variant shares one 36x22pt canvas so
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
        let paleLight, paleDark: NSColor       // unlit segments
        static let ink = NSColor(red: 0.22, green: 0.14, blue: 0.09, alpha: 1)
        static let cheek = NSColor(red: 0.98, green: 0.66, blue: 0.68, alpha: 0.9)
        static let phones = NSColor(white: 0.07, alpha: 1)
        static let phonesSheen = NSColor(white: 0.42, alpha: 1)

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
            paleLight = base.blended(withFraction: 0.72, of: cream) ?? base
            paleDark = base.blended(withFraction: 0.50, of: cream) ?? base
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

    private static func draw(lit: Int, palette: Palette) {
        let groundY: CGFloat = 3.2

        // Body: tail first so each segment overlaps the one behind it.
        let firstX: CGFloat = 15.4, spacing: CGFloat = 2.95
        for i in (0..<bodySegments).reversed() {
            let cx = firstX - CGFloat(i) * spacing
            let r: CGFloat = 3.25 - CGFloat(max(0, i - 2)) * 0.35
            let lift: CGFloat = i % 2 == 0 ? 0.5 : 0
            let bottom = groundY + 0.6 + lift

            // leg with a little round foot
            Palette.ink.set()
            let leg = NSBezierPath()
            leg.move(to: NSPoint(x: cx, y: bottom + 0.8))
            leg.line(to: NSPoint(x: cx, y: groundY - 0.2))
            leg.lineWidth = 0.75; leg.lineCapStyle = .round; leg.stroke()
            NSBezierPath(ovalIn: NSRect(x: cx - 0.85, y: groundY - 0.75, width: 1.7, height: 1.0)).fill()

            let isLit = i < lit
            let segment = NSBezierPath(ovalIn: NSRect(x: cx - r, y: bottom, width: r * 2, height: r * 2))
            shaded(segment, light: isLit ? palette.light : palette.paleLight,
                   dark: isLit ? palette.dark : palette.paleDark)
            // a soft highlight on the upper back of each segment
            NSColor(white: 1, alpha: isLit ? 0.35 : 0.25).set()
            NSBezierPath(ovalIn: NSRect(x: cx - r * 0.55, y: bottom + r * 1.15, width: r * 0.8, height: r * 0.45)).fill()
        }

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

        // Glossy black headphones, with a faint light rim so they read on a dark bar.
        let band = NSBezierPath()
        band.move(to: NSPoint(x: 17.4, y: 10.4))
        band.curve(to: NSPoint(x: 25.9, y: 12.4), controlPoint1: NSPoint(x: 17.6, y: 17.6), controlPoint2: NSPoint(x: 25.2, y: 18.2))
        band.lineCapStyle = .round
        let cup = NSBezierPath(roundedRect: NSRect(x: 16.1, y: 6.8, width: 3.4, height: 5.0), xRadius: 1.4, yRadius: 1.4)
        NSColor(white: 1, alpha: 0.35).set()
        band.lineWidth = 1.9; band.stroke()
        cup.lineWidth = 0.6; cup.stroke()
        Palette.phones.set()
        band.lineWidth = 1.3; band.stroke()
        NSGradient(starting: Palette.phonesSheen, ending: Palette.phones)?.draw(in: cup, angle: -70)
        // sheen along the band
        Palette.phonesSheen.withAlphaComponent(0.8).set()
        let sheen = NSBezierPath()
        sheen.move(to: NSPoint(x: 19.0, y: 14.8))
        sheen.curve(to: NSPoint(x: 22.6, y: 16.4), controlPoint1: NSPoint(x: 19.8, y: 16.0), controlPoint2: NSPoint(x: 21.2, y: 16.5))
        sheen.lineWidth = 0.35; sheen.lineCapStyle = .round; sheen.stroke()
    }
}
