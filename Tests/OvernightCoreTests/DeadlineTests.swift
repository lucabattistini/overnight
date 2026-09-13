import XCTest
@testable import OvernightCore

final class DeadlineTests: XCTestCase {

    private let calendar = Fixtures.romeCalendar

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        Fixtures.date(year, month, day, hour, minute)
    }

    func testLateNightTimeResolvesToTomorrow() throws {
        // AE1: 23:10 with a 07:30 target lands on the following calendar day.
        let now = date(2026, 9, 9, 23, 10)
        let deadline = try Deadline(hour: 7, minute: 30, now: now, calendar: calendar)
        XCTAssertEqual(deadline.date, date(2026, 9, 10, 7, 30))
    }

    func testEarlyMorningTimeResolvesToToday() throws {
        // AE2: 05:00 with a 07:30 target stays on the same day.
        let now = date(2026, 9, 9, 5, 0)
        let deadline = try Deadline(hour: 7, minute: 30, now: now, calendar: calendar)
        XCTAssertEqual(deadline.date, date(2026, 9, 9, 7, 30))
    }

    func testTimeExactlyEqualToNowResolvesToTomorrow() throws {
        let now = date(2026, 9, 9, 7, 30)
        let deadline = try Deadline(hour: 7, minute: 30, now: now, calendar: calendar)
        XCTAssertEqual(deadline.date, date(2026, 9, 10, 7, 30))
    }

    func testRollsOverMonthBoundary() throws {
        let now = date(2026, 9, 30, 23, 45)
        let deadline = try Deadline(hour: 7, minute: 30, now: now, calendar: calendar)
        XCTAssertEqual(deadline.date, date(2026, 10, 1, 7, 30))
    }

    func testCalendarIntervalMatchesResolvedDate() throws {
        let now = date(2026, 9, 9, 23, 10)
        let deadline = try Deadline(hour: 7, minute: 30, now: now, calendar: calendar)
        let interval = try deadline.calendarInterval(calendar: calendar)
        XCTAssertEqual(interval.month, 9)
        XCTAssertEqual(interval.day, 10)
        XCTAssertEqual(interval.hour, 7)
        XCTAssertEqual(interval.minute, 30)
    }

    func testRejectsOutOfRangeHour() {
        XCTAssertThrowsError(try Deadline(hour: 24, minute: 0, calendar: calendar)) { error in
            XCTAssertEqual(error as? Deadline.DeadlineError, .hourOutOfRange(24))
        }
        XCTAssertThrowsError(try Deadline(hour: -1, minute: 0, calendar: calendar))
    }

    func testRejectsOutOfRangeMinute() {
        XCTAssertThrowsError(try Deadline(hour: 7, minute: 60, calendar: calendar)) { error in
            XCTAssertEqual(error as? Deadline.DeadlineError, .minuteOutOfRange(60))
        }
    }

    func testExtendingRecomputesFromTheCurrentTimeNotThePreviousDeadline() throws {
        // Extending at 06:00 to 09:00 must resolve to 09:00 today, not to a second day out.
        let firstNow = date(2026, 9, 9, 23, 10)
        let first = try Deadline(hour: 7, minute: 30, now: firstNow, calendar: calendar)
        XCTAssertEqual(first.date, date(2026, 9, 10, 7, 30))

        let laterNow = date(2026, 9, 10, 6, 0)
        let extended = try Deadline(hour: 9, minute: 0, now: laterNow, calendar: calendar)
        XCTAssertEqual(extended.date, date(2026, 9, 10, 9, 0))
    }

    func testShortLabelIsZeroPadded() throws {
        let deadline = try Deadline(hour: 7, minute: 5, calendar: calendar)
        XCTAssertEqual(deadline.shortLabel, "07:05")
    }

    func testEpochSecondsMatchesResolvedDate() throws {
        let now = date(2026, 9, 9, 23, 10)
        let deadline = try Deadline(hour: 7, minute: 30, now: now, calendar: calendar)
        XCTAssertEqual(deadline.epochSeconds, Int(date(2026, 9, 10, 7, 30).timeIntervalSince1970))
    }

    // MARK: - Minutes since midnight

    func testMinutesSinceMidnightRoundTrips() throws {
        for (minutes, hour, minute) in [(0, 0, 0), (435, 7, 15), (720, 12, 0), (1439, 23, 59)] {
            let deadline = try Deadline(minutesSinceMidnight: minutes, now: date(2026, 9, 13, 0, 1), calendar: calendar)
            XCTAssertEqual(deadline.hour, hour)
            XCTAssertEqual(deadline.minute, minute)
            XCTAssertEqual(deadline.minutesSinceMidnight, minutes)
        }
    }

    func testMinutesSinceMidnightRejectsAnOutOfRangeValue() {
        // The stored value comes from UserDefaults, so a poisoned value must not reach the
        // privileged argument path. It throws Deadline's own typed error, not a new one.
        let now = date(2026, 9, 13, 0, 1)
        XCTAssertThrowsError(try Deadline(minutesSinceMidnight: 1440, now: now, calendar: calendar)) { error in
            XCTAssertEqual(error as? Deadline.DeadlineError, .hourOutOfRange(24))
        }
        XCTAssertThrowsError(try Deadline(minutesSinceMidnight: -1, now: now, calendar: calendar))
    }
}
