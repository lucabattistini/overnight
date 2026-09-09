import XCTest
@testable import OvernightCore

final class OvernightStatusTests: XCTestCase {

    private let deadlineEpoch = 1_788_000_000
    private var capture: PowerCapture {
        PowerCapture(ac: [.sleep: 30], battery: [.sleep: 1], priorSleepDisabled: false, deadlineEpoch: deadlineEpoch)
    }

    func testOffWhenSleepEnabledAndNoCapture() {
        let status = OvernightStatus.derive(sleepDisabled: false, capture: nil, jobInstalled: false)
        XCTAssertEqual(status, .off)
        XCTAssertFalse(status.isActive)
        XCTAssertFalse(status.canRestore)
    }

    func testActiveWhenSleepDisabledWithCaptureAndJob() {
        let status = OvernightStatus.derive(sleepDisabled: true, capture: capture, jobInstalled: true)
        XCTAssertEqual(status, .active(deadline: Date(timeIntervalSince1970: TimeInterval(deadlineEpoch))))
        XCTAssertTrue(status.isActive)
        XCTAssertTrue(status.canRestore)
    }

    func testActiveTimerMissingWhenJobIsGone() {
        let status = OvernightStatus.derive(sleepDisabled: true, capture: capture, jobInstalled: false)
        XCTAssertEqual(status, .activeTimerMissing(deadline: Date(timeIntervalSince1970: TimeInterval(deadlineEpoch))))
        XCTAssertTrue(status.isActive)
        XCTAssertTrue(status.canRestore)
    }

    func testExternallyDisabledOffersNoRestore() {
        // AE5: sleep is disabled but Overnight has no baseline, so it must not offer a restore.
        let status = OvernightStatus.derive(sleepDisabled: true, capture: nil, jobInstalled: false)
        XCTAssertEqual(status, .externallyDisabled)
        XCTAssertFalse(status.canRestore)
        XCTAssertNil(status.deadline)
    }

    func testStaleStateFileIsFlaggedForCleanup() {
        let status = OvernightStatus.derive(sleepDisabled: false, capture: capture, jobInstalled: false)
        XCTAssertEqual(status, .offWithStaleState)
        XCTAssertFalse(status.isActive)
        XCTAssertTrue(status.canRestore, "the leftover file can still be cleaned up")
    }

    func testPastDeadlineWithMissingJobIsStillActive() {
        // A deadline that already passed while the job is gone means nothing restored it.
        let past = PowerCapture(ac: [.sleep: 30], priorSleepDisabled: false, deadlineEpoch: 1_000_000)
        let status = OvernightStatus.derive(sleepDisabled: true, capture: past, jobInstalled: false)
        XCTAssertEqual(status, .activeTimerMissing(deadline: past.deadline))
    }

    func testUnreportedFlagFallsBackToTheCapture() {
        // When `pmset -g` does not surface SleepDisabled, an existing capture is the better
        // evidence: the app still offers a restore instead of claiming to be off.
        let status = OvernightStatus.derive(sleepDisabled: nil, capture: capture, jobInstalled: true)
        XCTAssertEqual(status, .active(deadline: capture.deadline))

        let none = OvernightStatus.derive(sleepDisabled: nil, capture: nil, jobInstalled: false)
        XCTAssertEqual(none, .off)
    }
}
