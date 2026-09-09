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
        func at(_ t: Double) -> MenuBarBand.Point {
            let u = 1 - t
            return MenuBarBand.Point(
                x: u * u * u * curve.start.x + 3 * u * u * t * curve.control1.x
                    + 3 * u * t * t * curve.control2.x + t * t * t * curve.end.x,
                y: u * u * u * curve.start.y + 3 * u * u * t * curve.control1.y
                    + 3 * u * t * t * curve.control2.y + t * t * t * curve.end.y
            )
        }
        var total = 0.0
        var previous = at(0)
        for step in 1...steps {
            let next = at(Double(step) / Double(steps))
            total += distance(previous, next)
            previous = next
        }
        return total
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
        XCTAssertEqual(before, after, accuracy: 1e-6, "an off-centre gap would look like a mistake")
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
        XCTAssertGreaterThan(gap - caps, 3.0, "the gap closes up once the round caps are drawn")
    }

    // MARK: - Shape

    func testTheBandIsCurvedAwayFromItsChord() {
        let chordMidpoint = MenuBarBand.Point(
            x: (MenuBarBand.chordStart.x + MenuBarBand.chordEnd.x) / 2,
            y: (MenuBarBand.chordStart.y + MenuBarBand.chordEnd.y) / 2
        )
        // For a cubic with both control points pushed the same distance off the chord, the
        // curve's own midpoint lands at three quarters of that distance.
        let expected = 0.75 * MenuBarBand.bow
        XCTAssertEqual(
            distance(MenuBarBand.point(at: 0.5), chordMidpoint),
            expected,
            accuracy: 1e-9
        )
        XCTAssertGreaterThan(expected, 0.02, "any less and the band reads as a plain diagonal")
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

    // MARK: - Subdivision

    /// Subdividing must reproduce the band exactly, not merely approximately: the whole point of
    /// splitting the cubic rather than drawing a polyline is that the pieces stay true curves at
    /// any backing scale.
    func testSubdivisionReproducesTheBandItWasCutFrom() {
        let piece = MenuBarBand.subcurve(from: 0.2, to: 0.7)
        for step in 0...20 {
            let local = Double(step) / 20
            let global = 0.2 + local * 0.5
            let u = 1 - local
            let sampled = MenuBarBand.Point(
                x: u * u * u * piece.start.x + 3 * u * u * local * piece.control1.x
                    + 3 * u * local * local * piece.control2.x + local * local * local * piece.end.x,
                y: u * u * u * piece.start.y + 3 * u * u * local * piece.control1.y
                    + 3 * u * local * local * piece.control2.y + local * local * local * piece.end.y
            )
            assertClose(sampled, MenuBarBand.point(at: global), accuracy: 1e-12)
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
