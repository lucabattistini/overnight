import Foundation

/// The geometry of Overnight's menu bar glyph: one curved band, drawn whole when Overnight is
/// holding the machine awake and broken in the middle when it is not.
///
/// This is plain math with no drawing framework attached, which is the point. It lives in
/// OvernightCore so the shape can be asserted in tests without a menu bar, a screen, or a
/// running app; `MenuBarIcon` in the app target is the thin part that turns these curves into
/// an `NSImage`. Keeping it as curves rather than a rasterised asset also means the glyph is
/// resolution independent: AppKit re-strokes it at whatever backing scale it needs, so it is
/// as crisp on a Retina menu bar as on a 1x one.
public enum MenuBarBand {

    /// A point in the unit square, with y increasing upward as AppKit's unflipped contexts do.
    public struct Point: Equatable, Sendable {
        public let x: Double
        public let y: Double

        public init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }
    }

    /// One cubic Bézier of the band, in the same unit square.
    public struct Curve: Equatable, Sendable {
        public let start: Point
        public let control1: Point
        public let control2: Point
        public let end: Point

        public init(start: Point, control1: Point, control2: Point, end: Point) {
            self.start = start
            self.control1 = control1
            self.control2 = control2
            self.end = end
        }
    }

    /// The size the glyph is designed for, in points. macOS gives a menu bar item an 18pt box.
    public static let nominalSide: Double = 18

    /// Stroke width as a fraction of the side. 2pt at 18pt reads as a band rather than a
    /// hairline, and still sits at roughly the weight of the system's own menu bar glyphs.
    public static let strokeFraction: Double = 2.0 / 18.0

    /// Where the band starts and ends. A diagonal, echoing the app icon's galactic band.
    public static let chordStart = Point(x: 0.10, y: 0.16)
    public static let chordEnd = Point(x: 0.90, y: 0.84)

    /// How far both control points are pushed off the chord, perpendicular to it, toward the
    /// upper left. The rendered curve bows by three quarters of this.
    ///
    /// Small on purpose: enough that the band is visibly curved rather than a plain diagonal,
    /// not so much that it turns into a swoosh.
    public static let bow: Double = 0.06

    /// The share of the band removed from the middle when Overnight is off.
    ///
    /// It is deliberately large. The two states have to be told apart at a glance, in
    /// peripheral vision, at 18pt, so a hairline nick would not do.
    public static let gapFraction: Double = 0.28

    /// The unbroken band.
    public static let whole: Curve = {
        let start = Self.chordStart
        let end = Self.chordEnd
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = (dx * dx + dy * dy).squareRoot()
        // Unit normal pointing to the left of travel, so the band bows up and away from a
        // straight diagonal.
        let normal = Point(x: -dy / length, y: dx / length)
        return Curve(
            start: start,
            control1: Point(
                x: start.x + dx / 3 + normal.x * Self.bow,
                y: start.y + dy / 3 + normal.y * Self.bow
            ),
            control2: Point(
                x: end.x - dx / 3 + normal.x * Self.bow,
                y: end.y - dy / 3 + normal.y * Self.bow
            ),
            end: end
        )
    }()

    /// The curves to stroke for a given state.
    ///
    /// Active is one continuous curve; inactive is the same curve with a centred gap, so the
    /// two glyphs share a silhouette and differ only in the interruption.
    public static func curves(active: Bool) -> [Curve] {
        guard !active else { return [whole] }
        let half = gapFraction / 2
        return [
            subcurve(from: 0, to: 0.5 - half),
            subcurve(from: 0.5 + half, to: 1),
        ]
    }

    /// The portion of the band between two parameter values, as its own cubic.
    ///
    /// Subdividing exactly, rather than approximating the band with a polyline, keeps the
    /// glyph a real curve at every scale.
    public static func subcurve(from start: Double, to end: Double) -> Curve {
        precondition(start >= 0 && end <= 1 && start < end, "expected 0 <= start < end <= 1")
        // de Casteljau twice: keep the left part up to `end`, then the right part of that from
        // the rescaled `start`.
        let left = split(whole, at: end).0
        return split(left, at: start / end).1
    }

    /// The point on the unbroken band at parameter `t`.
    public static func point(at t: Double) -> Point {
        precondition(t >= 0 && t <= 1, "expected 0 <= t <= 1")
        let u = 1 - t
        let a = u * u * u
        let b = 3 * u * u * t
        let c = 3 * u * t * t
        let d = t * t * t
        return Point(
            x: a * whole.start.x + b * whole.control1.x + c * whole.control2.x + d * whole.end.x,
            y: a * whole.start.y + b * whole.control1.y + c * whole.control2.y + d * whole.end.y
        )
    }

    // MARK: - Private

    private static func split(_ curve: Curve, at t: Double) -> (Curve, Curve) {
        let p01 = lerp(curve.start, curve.control1, t)
        let p12 = lerp(curve.control1, curve.control2, t)
        let p23 = lerp(curve.control2, curve.end, t)
        let p012 = lerp(p01, p12, t)
        let p123 = lerp(p12, p23, t)
        let mid = lerp(p012, p123, t)
        return (
            Curve(start: curve.start, control1: p01, control2: p012, end: mid),
            Curve(start: mid, control1: p123, control2: p23, end: curve.end)
        )
    }

    private static func lerp(_ a: Point, _ b: Point, _ t: Double) -> Point {
        Point(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }
}
