import Foundation
import XCTest
@testable import OvernightCore

/// The menu bar glyph is the only thing most people ever see of Overnight, and the difference
/// between "this Mac will not sleep tonight" and "it will" is carried entirely by whether the
/// band is broken. These assertions pin the properties that difference depends on.
final class MenuBarBandTests: XCTestCase {

    private let tolerance = 1e-9

    // MARK: - Helpers

    private func distance(_ a: MenuBarBand.Point, _ b: MenuBarBand.Point) -> Double {
        ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot()
    }

    private func assertClose(
        _ a: MenuBarBand.Point,
        _ b: MenuBarBand.Point,
        accuracy: Double = 1e-9,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(a.x, b.x, accuracy: accuracy, message, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: accuracy, message, file: file, line: line)
    }

    /// Polyline length of one cubic, fine enough that the error is far below what is asserted.
    private func length(of curve: MenuBarBand.Curve, steps: Int = 2000) -> Double {
        var total = 0.0
        var previous = point(on: curve, at: 0)
        for step in 1...steps {
            let next = point(on: curve, at: Double(step) / Double(steps))
            total += distance(previous, next)
            previous = next
        }
        return total
    }

    private func point(on curve: MenuBarBand.Curve, at t: Double) -> MenuBarBand.Point {
        let u = 1 - t
        return MenuBarBand.Point(
            x: u * u * u * curve.start.x + 3 * u * u * t * curve.control1.x
                + 3 * u * t * t * curve.control2.x + t * t * t * curve.end.x,
            y: u * u * u * curve.start.y + 3 * u * u * t * curve.control1.y
                + 3 * u * t * t * curve.control2.y + t * t * t * curve.end.y
        )
    }

    private var chordMidpoint: MenuBarBand.Point {
        MenuBarBand.Point(
            x: (MenuBarBand.chordStart.x + MenuBarBand.chordEnd.x) / 2,
            y: (MenuBarBand.chordStart.y + MenuBarBand.chordEnd.y) / 2
        )
    }

    // MARK: - The two states

    func testActiveIsOneUnbrokenBand() {
        let curves = MenuBarBand.curves(active: true)
        XCTAssertEqual(curves.count, 1)
        XCTAssertEqual(curves[0], MenuBarBand.whole)
    }

    func testInactiveIsTheSameBandBrokenInTwo() {
        let curves = MenuBarBand.curves(active: false)
        XCTAssertEqual(curves.count, 2)
        assertClose(curves[0].start, MenuBarBand.chordStart, "the band must start where it always does")
        assertClose(curves[1].end, MenuBarBand.chordEnd, "the band must end where it always does")
    }

    /// Off and on have to share a silhouette. If the pieces drifted off the band, the two icons
    /// would read as two different marks rather than one mark in two states.
    func testTheBrokenPiecesLieOnTheUnbrokenBand() {
        let curves = MenuBarBand.curves(active: false)
        let half = MenuBarBand.gapFraction / 2
        assertClose(curves[0].end, MenuBarBand.point(at: 0.5 - half))
        assertClose(curves[1].start, MenuBarBand.point(at: 0.5 + half))
    }

    func testTheGapIsCentred() {
        let curves = MenuBarBand.curves(active: false)
        let before = length(of: curves[0])
        let after = length(of: curves[1])
        XCTAssertEqual(before, after, accuracy: 1e-9, "an off-centre gap would look like a mistake")
    }

    /// The break lands on the inflection, which is the one place on the band the eye is already
    /// drawn to and the one place where both pieces end on the steepest part of the curve.
    func testTheGapIsCentredOnTheInflection() {
        let curves = MenuBarBand.curves(active: false)
        let midOfGap = MenuBarBand.Point(
            x: (curves[0].end.x + curves[1].start.x) / 2,
            y: (curves[0].end.y + curves[1].start.y) / 2
        )
        assertClose(midOfGap, chordMidpoint, accuracy: 1e-12)
    }

    /// At the size this is actually drawn, the interruption has to survive two round line caps
    /// eating into it from either side and still be obvious in peripheral vision.
    func testTheGapStaysVisibleAt18Points() {
        let half = MenuBarBand.gapFraction / 2
        let gap = distance(
            MenuBarBand.point(at: 0.5 - half),
            MenuBarBand.point(at: 0.5 + half)
        ) * MenuBarBand.nominalSide
        let caps = MenuBarBand.strokeFraction * MenuBarBand.nominalSide
        // 2pt of clear space between two 2pt-wide stroke ends: the break is as wide as the band
        // itself, which is the point at which it stops reading as a nick in a continuous line.
        XCTAssertGreaterThan(gap - caps, 2.0, "the gap closes up once the round caps are drawn")
    }

    /// Both halves have to stay long enough to still read as pieces of a band rather than as
    /// two dots, or the off state loses the shared silhouette that ties it to the on state.
    func testTheBrokenPiecesAreStillBands() {
        for piece in MenuBarBand.curves(active: false) {
            let drawn = length(of: piece) * MenuBarBand.nominalSide
            XCTAssertGreaterThan(drawn, 4.0, "a piece this short reads as a dash, not a band")
        }
    }

    // MARK: - Shape

    /// The mark is an S. An arc stays on one side of its chord; this has to cross it, or it is
    /// the lightly bowed diagonal this replaced and it reads as a plain slash at 18pt.
    func testTheBandInflectsAcrossItsChord() {
        let below = MenuBarBand.offsetFromChord(at: 0.25)
        let above = MenuBarBand.offsetFromChord(at: 0.75)
        XCTAssertLessThan(below, 0, "the first half must leave the chord on one side")
        XCTAssertGreaterThan(above, 0, "the second half must leave it on the other")
    }

    /// The band crosses its chord exactly once, at the middle. More crossings would be a wobble
    /// rather than an S.
    func testTheBandCrossesItsChordExactlyOnce() {
        // The crossing itself sits at t = 0.5, where the offset is zero to within rounding.
        // Samples inside that deadband carry no sign, so they are skipped rather than counted
        // as a crossing in whichever direction the last bit happened to fall.
        var crossings = 0
        var previousSign = 0
        for step in 0...2000 {
            let here = MenuBarBand.offsetFromChord(at: Double(step) / 2000)
            let sign = here > 1e-12 ? 1 : (here < -1e-12 ? -1 : 0)
            guard sign != 0 else { continue }
            if previousSign != 0 && sign != previousSign { crossings += 1 }
            previousSign = sign
        }
        XCTAssertEqual(crossings, 1)
        XCTAssertEqual(MenuBarBand.offsetFromChord(at: 0.5), 0, accuracy: 1e-12)
    }

    /// Both lobes have to be deep enough to see. This is the measurement that failed on the old
    /// single-sided bow: it swung 0.045 of the box in one direction only, where the S swings
    /// most of that in each direction and reverses in between.
    func testBothLobesAreDeepEnoughToRead() {
        var lowest = 0.0
        var highest = 0.0
        for step in 0...2000 {
            let offset = MenuBarBand.offsetFromChord(at: Double(step) / 2000)
            lowest = min(lowest, offset)
            highest = max(highest, offset)
        }
        XCTAssertGreaterThan(-lowest, 0.03, "the lower lobe is too shallow to see at 18pt")
        XCTAssertGreaterThan(highest, 0.03, "the upper lobe is too shallow to see at 18pt")
        XCTAssertEqual(-lowest, highest, accuracy: 1e-9, "the two lobes must mirror each other")
        XCTAssertGreaterThan(
            (highest - lowest) * MenuBarBand.nominalSide,
            1.0,
            "the whole S has to swing more than a stroke width or it is a straight line"
        )
    }

    /// The control polygon is built by reflecting one arm through the chord's midpoint, so the
    /// curve is symmetric under a half turn about that point. Everything above depends on it.
    func testTheBandIsSymmetricUnderAHalfTurn() {
        for step in 0...100 {
            let t = Double(step) / 100
            let here = MenuBarBand.point(at: t)
            let opposite = MenuBarBand.point(at: 1 - t)
            let reflected = MenuBarBand.Point(
                x: 2 * chordMidpoint.x - opposite.x,
                y: 2 * chordMidpoint.y - opposite.y
            )
            assertClose(here, reflected, accuracy: 1e-12, "the band is not half-turn symmetric")
        }
    }

    /// The band sweeps left to right and low to high without ever doubling back. Once the arms
    /// reach further right than the chord travels — `armReach * chordLength * cos(armAngle)`
    /// past the chord's horizontal span — the ends hook backwards into a knot, and this is the
    /// assertion that catches that.
    func testTheBandNeverDoublesBackOnItself() {
        var previous = MenuBarBand.point(at: 0)
        for step in 1...2000 {
            let here = MenuBarBand.point(at: Double(step) / 2000)
            XCTAssertGreaterThanOrEqual(here.x, previous.x, "the band turns back on itself in x")
            XCTAssertGreaterThanOrEqual(here.y, previous.y, "the band turns back on itself in y")
            previous = here
        }

        let dx = MenuBarBand.chordEnd.x - MenuBarBand.chordStart.x
        let dy = MenuBarBand.chordEnd.y - MenuBarBand.chordStart.y
        let chord = (dx * dx + dy * dy).squareRoot()
        let advance = MenuBarBand.armReach * chord * cos(MenuBarBand.armAngleDegrees * Double.pi / 180)
        XCTAssertLessThan(advance, dx, "the arms reach further right than the band travels")
    }

    /// Shallower arms than the chord is what makes the S lean the way the app icon's band does:
    /// low and flat on the left, rising through the middle, flat and high on the right.
    func testTheArmsAreShallowerThanTheChord() {
        let dx = MenuBarBand.chordEnd.x - MenuBarBand.chordStart.x
        let dy = MenuBarBand.chordEnd.y - MenuBarBand.chordStart.y
        let chordDegrees = atan2(dy, dx) * 180 / Double.pi
        XCTAssertGreaterThan(MenuBarBand.armAngleDegrees, 0, "flat arms would drop the diagonal")
        XCTAssertLessThan(
            MenuBarBand.armAngleDegrees,
            chordDegrees,
            "arms at or past the chord's own angle straighten the band or invert the S"
        )
    }

    /// Wider than tall, so the band sits beside Wi-Fi and Spotlight rather than looming over
    /// them, and so the S has the horizontal room to be an S.
    func testTheBandIsWiderThanItIsTall() {
        let width = MenuBarBand.chordEnd.x - MenuBarBand.chordStart.x
        let height = MenuBarBand.chordEnd.y - MenuBarBand.chordStart.y
        XCTAssertGreaterThan(width, 1.5 * height)
    }

    /// The convex hull of a cubic's control points contains the curve, so bounding the control
    /// points bounds the ink. Anything outside the 18pt box would be clipped by the menu bar.
    func testTheGlyphAndItsStrokeFitTheMenuBarBox() {
        let inset = MenuBarBand.strokeFraction / 2
        for curve in MenuBarBand.curves(active: false) + MenuBarBand.curves(active: true) {
            for point in [curve.start, curve.control1, curve.control2, curve.end] {
                XCTAssertGreaterThanOrEqual(point.x, inset)
                XCTAssertLessThanOrEqual(point.x, 1 - inset)
                XCTAssertGreaterThanOrEqual(point.y, inset)
                XCTAssertLessThanOrEqual(point.y, 1 - inset)
            }
        }
    }

    /// Because the band never doubles back, its bounding box is exactly its chord's — the hull
    /// bound above is loose, and this is the real extent of the ink.
    func testTheDrawnBandFillsExactlyTheChordsBox() {
        var minX = Double.greatestFiniteMagnitude
        var maxX = -Double.greatestFiniteMagnitude
        var minY = Double.greatestFiniteMagnitude
        var maxY = -Double.greatestFiniteMagnitude
        for step in 0...4000 {
            let here = MenuBarBand.point(at: Double(step) / 4000)
            minX = min(minX, here.x); maxX = max(maxX, here.x)
            minY = min(minY, here.y); maxY = max(maxY, here.y)
        }
        XCTAssertEqual(minX, MenuBarBand.chordStart.x, accuracy: 1e-12)
        XCTAssertEqual(maxX, MenuBarBand.chordEnd.x, accuracy: 1e-12)
        XCTAssertEqual(minY, MenuBarBand.chordStart.y, accuracy: 1e-12)
        XCTAssertEqual(maxY, MenuBarBand.chordEnd.y, accuracy: 1e-12)

        let half = MenuBarBand.strokeFraction / 2
        XCTAssertGreaterThan((minX - half) * MenuBarBand.nominalSide, 0)
        XCTAssertLessThan((maxX + half) * MenuBarBand.nominalSide, MenuBarBand.nominalSide)
        XCTAssertGreaterThan((minY - half) * MenuBarBand.nominalSide, 0)
        XCTAssertLessThan((maxY + half) * MenuBarBand.nominalSide, MenuBarBand.nominalSide)
    }

    // MARK: - Subdivision

    /// Subdividing must reproduce the band exactly, not merely approximately: the whole point of
    /// splitting the cubic rather than drawing a polyline is that the pieces stay true curves at
    /// any backing scale.
    func testSubdivisionReproducesTheBandItWasCutFrom() {
        let piece = MenuBarBand.subcurve(from: 0.2, to: 0.7)
        for step in 0...20 {
            let local = Double(step) / 20
            let global = 0.2 + local * 0.5
            assertClose(point(on: piece, at: local), MenuBarBand.point(at: global), accuracy: 1e-12)
        }
    }

    func testTheWholeBandIsItsOwnSubcurve() {
        let piece = MenuBarBand.subcurve(from: 0, to: 1)
        assertClose(piece.start, MenuBarBand.whole.start, accuracy: tolerance)
        assertClose(piece.control1, MenuBarBand.whole.control1, accuracy: tolerance)
        assertClose(piece.control2, MenuBarBand.whole.control2, accuracy: tolerance)
        assertClose(piece.end, MenuBarBand.whole.end, accuracy: tolerance)
    }
}
