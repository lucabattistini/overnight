import AppKit
import OvernightCore

/// Strokes `MenuBarBand` into the template images the menu bar item shows.
///
/// These are template images, so AppKit inverts them for a light or dark menu bar and for the
/// highlighted state; nothing here picks a colour. They are also drawn on demand rather than
/// rasterised once, which is what keeps the band crisp when the same 18pt item is composited
/// at 2x on a Retina display.
///
/// The stroke is one constant width with round caps and joins. `MenuBarBand` says why: the
/// artwork the glyph comes from tapers at its ends, and a tapered outline would have to be a
/// filled shape rather than a stroked path for no gain at the size this is actually seen.
enum MenuBarIcon {

    /// Overnight is holding the machine awake: the S is continuous.
    static let active = make(active: true)

    /// Overnight is off: the same S, interrupted at its inflection.
    static let inactive = make(active: false)

    static func image(active: Bool) -> NSImage {
        active ? Self.active : Self.inactive
    }

    /// Spoken by VoiceOver in place of the glyph. The two states differ in shape rather than
    /// only in colour, and they say which state they are in.
    static func label(active: Bool) -> String {
        active ? "Overnight is on" : "Overnight is off"
    }

    private static func make(active: Bool) -> NSImage {
        let side = CGFloat(MenuBarBand.nominalSide)
        let curves = MenuBarBand.curves(active: active)
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let path = NSBezierPath()
            for curve in curves {
                path.move(to: place(curve.start, in: rect))
                path.curve(
                    to: place(curve.end, in: rect),
                    controlPoint1: place(curve.control1, in: rect),
                    controlPoint2: place(curve.control2, in: rect)
                )
            }
            path.lineWidth = CGFloat(MenuBarBand.strokeFraction) * min(rect.width, rect.height)
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            NSColor.black.setStroke()
            path.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = label(active: active)
        return image
    }

    private static func place(_ point: MenuBarBand.Point, in rect: NSRect) -> NSPoint {
        NSPoint(
            x: rect.minX + CGFloat(point.x) * rect.width,
            y: rect.minY + CGFloat(point.y) * rect.height
        )
    }
}
