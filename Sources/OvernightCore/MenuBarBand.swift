import Foundation

/// The geometry of Overnight's menu bar glyph: one galactic band, drawn whole when Overnight is
/// holding the machine awake and broken in the middle when it is not.
///
/// The band is an S, not an arc. It leaves each end almost flat, sweeps steeply through the
/// middle, and settles flat again — the silhouette of the light band across the app icon, seen
/// edge-on. A single-sided bow was the earlier shape and it read as a plain diagonal at 18pt;
/// the inflection is what makes the mark recognisable at menu bar size.
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
    ///
    /// The band is stroked at one constant width. The artwork it derives from tapers at its
    /// ends, but a tapered outline would have to be a filled shape rather than a stroked path,
    /// and at 18pt with round caps the taper is below the resolution of the thing anyway.
    public static let strokeFraction: Double = 2.0 / 18.0

    /// Where the band starts and ends: a shallow diagonal, low on the left, high on the right.
    ///
    /// Wider than it is tall on purpose. The band has to sit in the menu bar next to Wi-Fi and
    /// Spotlight without towering over them, and the S needs horizontal room to be an S.
    public static let chordStart = Point(x: 0.10, y: 0.30)
    public static let chordEnd = Point(x: 0.90, y: 0.70)

    /// The angle above horizontal at which the band leaves each end, in degrees.
    ///
    /// Shallower than the chord's own 26.6°, which is what bends the curve into an S: the band
    /// leaves the low end below the chord, crosses it dead centre, and arrives at the high end
    /// from above. Set this equal to the chord's angle and the band straightens into a line;
    /// set it steeper and the S inverts.
    public static let armAngleDegrees: Double = 10

    /// How far each control point reaches from its own end, as a fraction of the chord.
    ///
    /// This is the knob for how pronounced the S is: the two lobes grow with it. It has a hard
    /// ceiling — once `armReach * cos(armAngle) * chordLength` reaches the chord's horizontal
    /// span the band stops advancing left to right and starts hooking back on itself, which
    /// reads as a knot rather than a band. At 0.52 it sits comfortably below that.
    public static let armReach: Double = 0.52

    /// The share of the band removed from the middle when Overnight is off.
    ///
    /// It is deliberately large. The two states have to be told apart at a glance, in
    /// peripheral vision, at 18pt, so a hairline nick would not do. The break lands on the
    /// inflection, where the band is steepest and the eye is already looking.
    public static let gapFraction: Double = 0.34

    /// The unbroken band.
    ///
    /// Both control points are placed by reflecting one offset vector through the chord's
    /// midpoint, which makes the whole control polygon — and therefore the curve — symmetric
    /// under a half turn about that midpoint. That symmetry is not decoration: it puts the
    /// inflection exactly at t = 0.5, makes the two lobes mirror images, and makes a centred
    /// gap actually centred rather than centred to within a rounding error.
    public static let whole: Curve = {
        let start = Self.chordStart
        let end = Self.chordEnd
        let dx = end.x - start.x
        let dy = end.y - start.y
        let reach = Self.armReach * (dx * dx + dy * dy).squareRoot()
        let angle = Self.armAngleDegrees * Double.pi / 180
        let arm = Point(x: reach * cos(angle), y: reach * sin(angle))
        return Curve(
            start: start,
            control1: Point(x: start.x + arm.x, y: start.y + arm.y),
            control2: Point(x: end.x - arm.x, y: end.y - arm.y),
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

    /// How far the band sits off its own chord at `t`, positive to the left of travel.
    ///
    /// The sign is the whole point: an arc keeps one sign, an S changes it. Tests use this to
    /// assert the band actually inflects rather than merely bulging.
    public static func offsetFromChord(at t: Double) -> Double {
        let dx = chordEnd.x - chordStart.x
        let dy = chordEnd.y - chordStart.y
        let length = (dx * dx + dy * dy).squareRoot()
        // Unit normal, ninety degrees left of the chord's direction of travel.
        let normalX = -dy / length
        let normalY = dx / length
        let here = point(at: t)
        return (here.x - chordStart.x) * normalX + (here.y - chordStart.y) * normalY
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
