import XCTest
@testable import OvernightCore

final class PMSetParserTests: XCTestCase {

    // MARK: - pmset -g custom

    func testParsesBothProfilesFromLaptopOutput() throws {
        let result = try PMSetParser.parseCustom(Fixtures.customLaptop)

        XCTAssertEqual(result.ac[.sleep], 30)
        XCTAssertEqual(result.ac[.disksleep], 10)
        XCTAssertEqual(result.ac[.displaysleep], 10)
        XCTAssertEqual(result.ac[.powernap], 1)
        XCTAssertEqual(result.ac[.tcpkeepalive], 1)

        XCTAssertEqual(result.battery[.sleep], 1)
        XCTAssertEqual(result.battery[.displaysleep], 5)
        XCTAssertEqual(result.battery[.powernap], 0)
    }

    func testIgnoresUnmanagedKeysIncludingNonNumericOnes() throws {
        let result = try PMSetParser.parseCustom(Fixtures.customLaptop)
        // `hibernatemode`, `standbydelay` and the non-numeric `hibernatefile` are all outside
        // the managed set, so they must neither appear nor cause a parse failure.
        XCTAssertEqual(Set(result.ac.keys).count, ManagedSetting.allCases.count)
        XCTAssertEqual(Set(result.ac.keys), Set(ManagedSetting.allCases))
    }

    func testParsesDesktopOutputWithNoBatterySection() throws {
        let result = try PMSetParser.parseCustom(Fixtures.customDesktop)
        XCTAssertTrue(result.battery.isEmpty)
        XCTAssertEqual(result.ac[.sleep], 60)
        XCTAssertNil(result.ac[.tcpkeepalive])
    }

    func testReportsAbsenceRatherThanZeroForMissingKey() throws {
        // AE4: a machine that does not expose `tcpkeepalive` must record it as absent, so it
        // is never passed to pmset in either direction.
        let result = try PMSetParser.parseCustom(Fixtures.customNoTCPKeepAlive)
        XCTAssertNil(result.ac[.tcpkeepalive])
        XCTAssertNil(result.battery[.tcpkeepalive])
        XCTAssertEqual(result.ac[.powernap], 1)
    }

    func testRejectsNonNumericValueForManagedKey() {
        let output = """
        AC Power:
         sleep                notanumber
        """
        XCTAssertThrowsError(try PMSetParser.parseCustom(output)) { error in
            XCTAssertEqual(error as? CaptureError, .nonNumericValue(key: "sleep", raw: "notanumber"))
        }
    }

    func testSectionMembershipFollowsHeadersNotOrder() throws {
        let acFirst = """
        AC Power:
         sleep                30
        Battery Power:
         sleep                1
        """
        let result = try PMSetParser.parseCustom(acFirst)
        XCTAssertEqual(result.ac[.sleep], 30)
        XCTAssertEqual(result.battery[.sleep], 1)
    }

    // MARK: - pmset -g

    func testExtractsSleepDisabledOn() throws {
        XCTAssertEqual(try PMSetParser.parseSleepDisabled(Fixtures.liveSleepDisabledOn), true)
    }

    func testExtractsSleepDisabledOff() throws {
        XCTAssertEqual(try PMSetParser.parseSleepDisabled(Fixtures.liveSleepDisabledOff), false)
    }

    func testReportsNilWhenSleepDisabledIsNotPresent() throws {
        XCTAssertNil(try PMSetParser.parseSleepDisabled(Fixtures.liveNoSleepDisabled))
    }

    // MARK: - Saved state

    func testStateRoundTripPreservesAbsentKeys() throws {
        let original = PowerCapture(
            ac: [.sleep: 30, .disksleep: 10, .displaysleep: 10, .powernap: 1],
            battery: [.sleep: 1, .displaysleep: 5],
            priorSleepDisabled: false,
            deadlineEpoch: 1_788_000_000
        )
        let restored = try PMSetParser.parseState(PMSetParser.renderState(original))
        XCTAssertEqual(restored, original)
        XCTAssertNil(restored.ac[.tcpkeepalive])
    }

    func testRejectsInjectionAttemptInStateFile() {
        let tampered = """
        version 1
        ac_sleep 0;
        """
        XCTAssertThrowsError(try PMSetParser.parseState(tampered))
    }

    func testRejectsShellMetacharactersInStateValue() {
        let tampered = "version 1\nac_sleep $(id)\n"
        XCTAssertThrowsError(try PMSetParser.parseState(tampered))
    }

    func testRejectsOverlongStateValue() {
        let tampered = "version 1\nac_sleep 123456\n"
        XCTAssertThrowsError(try PMSetParser.parseState(tampered)) { error in
            XCTAssertEqual(error as? CaptureError, .valueOutOfRange(key: "ac_sleep", raw: "123456"))
        }
    }

    func testRejectsUnknownStateKey() {
        XCTAssertThrowsError(try PMSetParser.parseState("version 1\nac_hibernatemode 3\n")) { error in
            XCTAssertEqual(error as? CaptureError, .unknownStateKey("ac_hibernatemode"))
        }
    }

    func testRejectsStateFileWithoutVersion() {
        XCTAssertThrowsError(try PMSetParser.parseState("ac_sleep 30\n"))
    }

    func testRejectsUnsupportedStateVersion() {
        XCTAssertThrowsError(try PMSetParser.parseState("version 2\nac_sleep 30\n"))
    }

    // MARK: - Write vectors

    func testApplyArgumentsScopeTimersToACAndDisableSleepGlobally() {
        let args = PMSetParser.applyArguments()
        XCTAssertEqual(args.first, "-c")
        XCTAssertFalse(args.contains("-b"), "the battery profile must never be written on enable")

        // disablesleep has no per-power-source form, so it is the only `-a` write.
        XCTAssertEqual(args.filter { $0 == "-a" }.count, 1)
        XCTAssertEqual(Array(args.suffix(3)), ["-a", "disablesleep", "1"])

        // The AC half must carry exactly the overnight profile.
        let acHalf = Array(args[1..<(args.count - 3)])
        XCTAssertEqual(acHalf.count, overnightACProfile.count * 2)
        XCTAssertTrue(acHalf.contains("displaysleep"))
        XCTAssertTrue(acHalf.contains("2"))
    }

    func testApplyArgumentsNeverWriteTCPKeepAlive() {
        // Its `-c` scoping is unverified, so Overnight does not write it at all.
        XCTAssertFalse(PMSetParser.applyArguments().contains("tcpkeepalive"))
    }

    func testRestoreNeverWritesASettingOvernightDidNotApply() throws {
        // tcpkeepalive is captured for diagnostics, but replaying it would be a write to a
        // setting Overnight never changed.
        let capture = PowerCapture(
            ac: [.sleep: 30, .tcpkeepalive: 1],
            battery: [.tcpkeepalive: 1],
            priorSleepDisabled: false
        )
        let args = try XCTUnwrap(PMSetParser.restoreArguments(capture))
        XCTAssertFalse(args.contains("tcpkeepalive"))
        XCTAssertEqual(args, ["-c", "sleep", "30", "-a", "disablesleep", "0"])
    }

    func testRestoreArgumentsEmitOnlyCapturedACKeys() throws {
        let capture = PowerCapture(
            ac: [.sleep: 30, .displaysleep: 10],
            battery: [.sleep: 1, .displaysleep: 5],
            priorSleepDisabled: false
        )
        let args = try XCTUnwrap(PMSetParser.restoreArguments(capture))

        XCTAssertFalse(args.contains("-b"), "battery values are captured but never replayed")
        XCTAssertFalse(args.contains("disksleep"), "a key the capture did not record is never written")
        XCTAssertEqual(args, ["-c", "displaysleep", "10", "sleep", "30", "-a", "disablesleep", "0"])
    }

    func testRestoreArgumentsOmitSleepDisabledWhenItWasNeverCaptured() throws {
        let capture = PowerCapture(ac: [.sleep: 30], battery: [:], priorSleepDisabled: nil)
        let args = try XCTUnwrap(PMSetParser.restoreArguments(capture))
        XCTAssertFalse(args.contains("disablesleep"))
    }

    func testRestoreArgumentsAreNilForAnEmptyCapture() {
        XCTAssertNil(PMSetParser.restoreArguments(PowerCapture()))
    }
}
