import XCTest
@testable import OvernightCore

final class SafeArgumentTests: XCTestCase {

    func testAcceptsPlainDigits() throws {
        XCTAssertEqual(try SafeArgument.number("30"), "30")
        XCTAssertEqual(try SafeArgument.number(7), "7")
    }

    func testRejectsCommandInjectionAttempts() {
        XCTAssertThrowsError(try SafeArgument.number("1; touch /tmp/x"))
        XCTAssertThrowsError(try SafeArgument.number("$(id)"))
        XCTAssertThrowsError(try SafeArgument.number("`id`"))
        XCTAssertThrowsError(try SafeArgument.number("1 2"))
        XCTAssertThrowsError(try SafeArgument.number("1\nrm -rf /"))
        XCTAssertThrowsError(try SafeArgument.number("-1"))
        XCTAssertThrowsError(try SafeArgument.number(""))
    }

    func testRejectsOverlongNumbers() {
        XCTAssertThrowsError(try SafeArgument.number("123456")) { error in
            XCTAssertEqual(error as? SafeArgument.ValidationError, .tooManyDigits("123456"))
        }
    }

    func testRejectsNonAbsolutePath() {
        XCTAssertThrowsError(try SafeArgument.path("relative/path")) { error in
            XCTAssertEqual(error as? SafeArgument.ValidationError, .notAbsolutePath("relative/path"))
        }
    }

    func testRejectsPathWithControlCharacter() {
        XCTAssertThrowsError(try SafeArgument.path("/Applications/Over\nnight.app"))
    }

    func testAcceptsPathWithSpacesAndQuotes() throws {
        // The app bundle can be renamed to anything the Finder allows; the escaping layers
        // handle it rather than the validator rejecting it.
        let path = #"/Applications/My "Overnight" App.app"#
        XCTAssertEqual(try SafeArgument.path(path), path)
    }

    func testAppleScriptLiteralEscapesDoubleQuote() {
        let literal = SafeArgument.appleScriptLiteral(#"/Applications/My "App".app"#)
        XCTAssertEqual(literal, #""/Applications/My \"App\".app""#)
    }

    func testAppleScriptLiteralEscapesBackslash() {
        let literal = SafeArgument.appleScriptLiteral(#"/tmp/a\b"#)
        XCTAssertEqual(literal, #""/tmp/a\\b""#)
    }

    func testAppleScriptLiteralLeavesSingleQuoteIntact() {
        // A single quote is not special in an AppleScript string literal; the shell layer is
        // handled separately by `quoted form of`.
        let literal = SafeArgument.appleScriptLiteral("/Users/luca/Luca's Apps/Overnight.app")
        XCTAssertEqual(literal, "\"/Users/luca/Luca's Apps/Overnight.app\"")
    }
}
