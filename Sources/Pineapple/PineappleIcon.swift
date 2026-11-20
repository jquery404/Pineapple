import AppKit

/// The pineapple artwork, drawn in code so there are no image files to keep in sync.
enum PineappleIcon {
    /// Full-colour app icon (Finder, Dock, permission prompts). Drawn into a square `size` canvas.
    static func appIcon(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let s = rect.width / 1024
            func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
                NSRect(x: x * s, y: y * s, width: w * s, height: h * s)
            }

            // Background tile, inset like Apple's icon grid.
            let tile = NSBezierPath(roundedRect: r(100, 100, 824, 824), xRadius: 185 * s, yRadius: 185 * s)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
            shadow.shadowBlurRadius = 24 * s
            shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
            shadow.set()
            NSColor(red: 0.06, green: 0.24, blue: 0.30, alpha: 1).setFill()
            tile.fill()
            NSGraphicsContext.restoreGraphicsState()
            NSGradient(starting: NSColor(red: 0.09, green: 0.36, blue: 0.42, alpha: 1),
                       ending: NSColor(red: 0.04, green: 0.17, blue: 0.22, alpha: 1))!.draw(in: tile, angle: -90)

            // Crown: back leaves darker, front leaves lighter.
            let base = NSPoint(x: 512 * s, y: 585 * s)
            let leaves: [(angle: CGFloat, length: CGFloat, width: CGFloat, front: Bool)] = [
                (-48, 190, 62, false), (48, 190, 62, false),
                (-26, 240, 70, false), (26, 240, 70, false),
                (-12, 250, 68, true), (12, 250, 68, true), (0, 280, 74, true),
            ]
            for leaf in leaves {
                let path = leafPath(base: base, angle: leaf.angle, length: leaf.length * s, width: leaf.width * s)
                let top = leaf.front ? NSColor(red: 0.50, green: 0.84, blue: 0.40, alpha: 1)
                                     : NSColor(red: 0.30, green: 0.64, blue: 0.30, alpha: 1)
                let bottom = leaf.front ? NSColor(red: 0.20, green: 0.56, blue: 0.27, alpha: 1)
                                        : NSColor(red: 0.13, green: 0.40, blue: 0.20, alpha: 1)
                NSGradient(starting: top, ending: bottom)!.draw(in: path, angle: -90)
            }

            // Body with a criss-cross skin.
            let body = NSBezierPath(ovalIn: r(332, 175, 360, 450))
            NSGradient(starting: NSColor(red: 1.00, green: 0.84, blue: 0.32, alpha: 1),
                       ending: NSColor(red: 0.93, green: 0.58, blue: 0.10, alpha: 1))!.draw(in: body, angle: -60)
            NSGraphicsContext.saveGraphicsState()
            body.addClip()
            let lines = NSBezierPath()
            lines.lineWidth = 13 * s
            var x: CGFloat = -600
            while x < 1600 {
                lines.move(to: NSPoint(x: x * s, y: 0))
                lines.line(to: NSPoint(x: (x + 1024) * s, y: 1024 * s))
                lines.move(to: NSPoint(x: x * s, y: 1024 * s))
                lines.line(to: NSPoint(x: (x + 1024) * s, y: 0))
                x += 82
            }
            NSColor(red: 0.72, green: 0.42, blue: 0.04, alpha: 0.75).setStroke()
            lines.stroke()
            // Soft highlight on the upper left.
            NSGradient(starting: NSColor.white.withAlphaComponent(0.25), ending: NSColor.white.withAlphaComponent(0))!
                .draw(in: NSBezierPath(ovalIn: r(355, 360, 180, 230)), relativeCenterPosition: NSPoint(x: -0.2, y: 0.3))
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
    }

    /// Small pineapple for the menu bar. A template image, so macOS colours it for light/dark menus.
    static func menuBarIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setFill()
            for (angle, length) in [(-34.0, 6.0), (34.0, 6.0), (0.0, 7.5)] as [(CGFloat, CGFloat)] {
                leafPath(base: NSPoint(x: 9, y: 10.5), angle: angle, length: length, width: 2.6).fill()
            }
            let body = NSBezierPath(ovalIn: NSRect(x: 4.5, y: 0.5, width: 9, height: 11))
            body.fill()
            // Cut the criss-cross into the body.
            NSGraphicsContext.saveGraphicsState()
            body.addClip()
            NSGraphicsContext.current?.compositingOperation = .clear
            let lines = NSBezierPath()
            lines.lineWidth = 0.9
            for x in stride(from: CGFloat(-14), through: 18, by: 3.6) {
                lines.move(to: NSPoint(x: x, y: 0)); lines.line(to: NSPoint(x: x + 14, y: 14))
                lines.move(to: NSPoint(x: x, y: 14)); lines.line(to: NSPoint(x: x + 14, y: 0))
            }
            lines.stroke()
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Pineapple"
        return image
    }

    /// A pointed leaf growing from `base`, tilted `angle` degrees from vertical.
    private static func leafPath(base: NSPoint, angle: CGFloat, length: CGFloat, width: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: -width / 2, y: 0))
        path.curve(to: NSPoint(x: 0, y: length),
                   controlPoint1: NSPoint(x: -width / 2, y: length * 0.45),
                   controlPoint2: NSPoint(x: -width * 0.1, y: length * 0.8))
        path.curve(to: NSPoint(x: width / 2, y: 0),
                   controlPoint1: NSPoint(x: width * 0.1, y: length * 0.8),
                   controlPoint2: NSPoint(x: width / 2, y: length * 0.45))
        path.close()
        var t = AffineTransform(translationByX: base.x, byY: base.y)
        t.rotate(byDegrees: -angle)
        path.transform(using: t)
        return path
    }
}
