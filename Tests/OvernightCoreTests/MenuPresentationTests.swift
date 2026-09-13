import XCTest
@testable import OvernightCore

final class MenuPresentationTests: XCTestCase {

    /// Fixed calendar so these assertions do not depend on the machine's time zone, the same
    /// reason DeadlineTests pins one.
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Rome")!
        return calendar
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = 0
        return calendar.date(from: components)!
    }

    private func capture(deadline: Date?) -> PowerCapture {
        PowerCapture(
            ac: [.sleep: 30],
            battery: [.sleep: 1],
            priorSleepDisabled: false,
            deadlineEpoch: deadline.map { Int($0.timeIntervalSince1970) }
        )
    }

    private func present(
        _ status: OvernightStatus,
        onBattery: Bool = false,
        lastError: String? = nil,
        isBusy: Bool = false
    ) -> MenuPresentation {
        MenuPresentation.make(
            status: status,
            onBatteryWhileActive: onBattery,
            lastError: lastError,
            isBusy: isBusy,
            calendar: calendar
        )
    }

    // MARK: - The submenu is withheld where Overnight may not act

    func testExternallyDisabledOffersNoWayToEnable() {
        // AE6: the submenu is the enable path, and enabling here would capture a foreign
        // SleepDisabled 1 as Overnight's baseline.
        let menu = present(.externallyDisabled)
        XCTAssertNil(menu.submenu(titled: MenuPresentation.wakeAtTitle))
        XCTAssertFalse(menu.containsAction { if case .enable = $0 { return true } else { return false } })
        XCTAssertFalse(menu.containsAction { $0 == .chooseCustomTime })
    }

    func testExternallyDisabledOffersTheRecoveryCopy() {
        let menu = present(.externallyDisabled)
        XCTAssertTrue(menu.containsAction { $0 == .copyRecoveryCommand })
        let item = menu.item(withAction: .copyRecoveryCommand)
        XCTAssertEqual(item?.tooltip, OvernightPaths.recoveryCommand)
    }

    func testEveryOtherStatusOffersTheSubmenu() {
        for status: OvernightStatus in [
            .off,
            .offWithStaleState,
            .active(deadline: date(2026, 9, 13, 7, 30)),
            .activeTimerMissing(deadline: date(2026, 9, 13, 7, 30)),
        ] {
            XCTAssertNotNil(
                present(status).submenu(titled: MenuPresentation.wakeAtTitle),
                "\(status) should offer the wake-at submenu"
            )
        }
    }

    // MARK: - Check marks

    func testAnExactPresetIsChecked() {
        let menu = present(.active(deadline: date(2026, 9, 13, 7, 30)))
        let submenu = menu.submenu(titled: MenuPresentation.wakeAtTitle)!
        XCTAssertEqual(submenu.filter(\.isChecked).map(\.title), ["07:30"])
    }

    func testAnUnmatchedDeadlineChecksTheCustomItem() {
        // AE3: 07:15 matches no preset, so Custom carries the check mark.
        let menu = present(.active(deadline: date(2026, 9, 13, 7, 15)))
        let submenu = menu.submenu(titled: MenuPresentation.wakeAtTitle)!
        XCTAssertEqual(submenu.filter(\.isChecked).map(\.title), [MenuPresentation.customTitle])
    }

    func testAnUnknownDeadlineChecksNothing() {
        // AE7: an active status with no recorded deadline must not assert a custom time.
        let menu = present(.active(deadline: nil))
        let submenu = menu.submenu(titled: MenuPresentation.wakeAtTitle)!
        XCTAssertTrue(submenu.filter(\.isChecked).isEmpty)
    }

    func testOneMinuteEitherSideOfAPresetDoesNotMatchIt() {
        for minute in [29, 31] {
            let menu = present(.active(deadline: date(2026, 9, 13, 7, minute)))
            let submenu = menu.submenu(titled: MenuPresentation.wakeAtTitle)!
            XCTAssertEqual(
                submenu.filter(\.isChecked).map(\.title),
                [MenuPresentation.customTitle],
                "07:\(minute) is not 07:30"
            )
        }
    }

    func testNothingIsCheckedWhileOvernightIsOff() {
        let submenu = present(.off).submenu(titled: MenuPresentation.wakeAtTitle)!
        XCTAssertTrue(submenu.filter(\.isChecked).isEmpty)
    }

    // MARK: - Warning precedence

    func testAtMostOneWarningIsShown() {
        // AE9: a failed operation outranks both the missing timer and the battery warning.
        let menu = present(
            .activeTimerMissing(deadline: date(2026, 9, 13, 7, 30)),
            onBattery: true,
            lastError: "osascript: something went wrong"
        )
        XCTAssertEqual(menu.warnings.count, 1)
        XCTAssertEqual(menu.warnings.first?.title, MenuPresentation.errorWarningTitle)
    }

    func testMissingTimerOutranksTheBatteryWarning() {
        let menu = present(.activeTimerMissing(deadline: date(2026, 9, 13, 7, 30)), onBattery: true)
        XCTAssertEqual(menu.warnings.map(\.title), [MenuPresentation.timerWarningTitle])
    }

    func testTheBatteryWarningShowsWhenItIsTheOnlyCondition() {
        let menu = present(.active(deadline: date(2026, 9, 13, 7, 30)), onBattery: true)
        XCTAssertEqual(menu.warnings.map(\.title), [MenuPresentation.batteryWarningTitle])
    }

    func testNoWarningWhenNothingIsWrong() {
        XCTAssertTrue(present(.active(deadline: date(2026, 9, 13, 7, 30))).warnings.isEmpty)
    }

    func testEveryWarningCarriesAnExplanationDistinctFromItsTitle() {
        let menus = [
            present(.active(deadline: date(2026, 9, 13, 7, 30)), onBattery: true),
            present(.activeTimerMissing(deadline: date(2026, 9, 13, 7, 30))),
            present(.active(deadline: date(2026, 9, 13, 7, 30)), lastError: "boom"),
        ]
        for menu in menus {
            let warning = menu.warnings.first
            XCTAssertNotNil(warning)
            XCTAssertEqual(warning?.symbol, .warning)
            XCTAssertFalse(warning?.isEnabled ?? true, "a warning is informational, not actionable")
            let tooltip = warning?.tooltip ?? ""
            XCTAssertFalse(tooltip.isEmpty, "the panel's explanation must survive as a tooltip")
            XCTAssertNotEqual(tooltip, warning?.title)
        }
    }

    func testTheWarningSitsAboveEveryActionableItem() {
        // AE5: the warning must not displace the item people aim at.
        let menu = present(.active(deadline: date(2026, 9, 13, 7, 30)), onBattery: true)
        let warningIndex = menu.items.firstIndex { $0.symbol == .warning }
        let firstActionable = menu.items.firstIndex { $0.isEnabled && $0.action != nil }
        XCTAssertNotNil(warningIndex)
        XCTAssertNotNil(firstActionable)
        XCTAssertLessThan(warningIndex!, firstActionable!)
        XCTAssertEqual(menu.items[firstActionable!].action, .turnOff)
    }

    // MARK: - The state item

    func testTheStateItemIsFirstAndNotActionable() {
        let menu = present(.active(deadline: date(2026, 9, 13, 7, 30)))
        let first = menu.items.first
        XCTAssertEqual(first?.title, "On until Sun 07:30.")
        XCTAssertFalse(first?.isEnabled ?? true)
        XCTAssertNil(first?.action)
    }

    func testTheStateWordingIsCarriedOverForEveryStatus() {
        let deadline = date(2026, 9, 13, 7, 30)
        let expected: [(OvernightStatus, String)] = [
            (.off, "Off. This Mac sleeps normally."),
            (.offWithStaleState, "Off, with a leftover state file to clean up."),
            (.active(deadline: deadline), "On until Sun 07:30."),
            (.activeTimerMissing(deadline: deadline), "On, but the Sun 07:30 timer is missing."),
            (.externallyDisabled, "Sleep is disabled, but not by Overnight."),
        ]
        for (status, line) in expected {
            XCTAssertEqual(present(status).items.first?.title, line)
        }
    }

    func testAnUnknownDeadlineKeepsTheCarriedOverWording() {
        XCTAssertEqual(present(.active(deadline: nil)).items.first?.title, "On until an unknown time.")
    }

    func testTheStateLineFollowsTheInjectedCalendar() {
        // The same instant reads differently in another zone; nothing here may depend on the host.
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let instant = date(2026, 9, 13, 23, 30)

        let rome = MenuPresentation.make(
            status: .active(deadline: instant),
            onBatteryWhileActive: false,
            lastError: nil,
            isBusy: false,
            calendar: calendar
        )
        let japan = MenuPresentation.make(
            status: .active(deadline: instant),
            onBatteryWhileActive: false,
            lastError: nil,
            isBusy: false,
            calendar: tokyo
        )
        XCTAssertEqual(rome.items.first?.title, "On until Sun 23:30.")
        XCTAssertEqual(japan.items.first?.title, "On until Mon 06:30.")
    }

    // MARK: - Busy

    func testBusyDisablesEveryPrivilegedActionAndSaysSo() {
        // AE8: a menu closes on click, so a dropped pick must be impossible rather than silent.
        let menu = present(.active(deadline: date(2026, 9, 13, 7, 30)), isBusy: true)
        XCTAssertEqual(menu.items.first?.title, MenuPresentation.busyTitle)
        XCTAssertNil(menu.submenu(titled: MenuPresentation.wakeAtTitle))
        for item in menu.items where item.action?.isPrivileged == true {
            XCTAssertFalse(item.isEnabled, "\(item.title) must not accept a pick while busy")
        }
        XCTAssertFalse(menu.containsAction { $0.isPrivileged && $0 != .turnOff })
    }

    func testBusyLeavesRefreshAndQuitReachable() {
        // Neither goes through AppModel.perform, so neither can be dropped -- and disabling
        // Quit would strand the user behind a hung authorization prompt.
        let menu = present(.active(deadline: date(2026, 9, 13, 7, 30)), isBusy: true)
        for action: MenuPresentation.Action in [.refresh, .quit] {
            let item = menu.item(withAction: action)
            XCTAssertNotNil(item, "\(action) must stay in the menu")
            XCTAssertTrue(item?.isEnabled ?? false, "\(action) must stay usable while busy")
        }
    }

    // MARK: - Per-status actions

    func testTurnOffIsOfferedOnlyWhileActive() {
        let deadline = date(2026, 9, 13, 7, 30)
        for status: OvernightStatus in [.active(deadline: deadline), .activeTimerMissing(deadline: deadline)] {
            XCTAssertTrue(present(status).containsAction { $0 == .turnOff }, "\(status)")
        }
        for status: OvernightStatus in [.off, .offWithStaleState, .externallyDisabled] {
            XCTAssertFalse(present(status).containsAction { $0 == .turnOff }, "\(status)")
        }
    }

    func testTheCleanupActionIsOfferedOnlyForAStaleStateFile() {
        XCTAssertTrue(present(.offWithStaleState).containsAction { $0 == .cleanUpStaleState })
        XCTAssertFalse(present(.off).containsAction { $0 == .cleanUpStaleState })
    }

    func testRefreshAndQuitAreAlwaysLastAndBelowASeparator() {
        let menu = present(.off)
        let titles = menu.items.filter { !$0.isSeparator }.map(\.title)
        XCTAssertEqual(Array(titles.suffix(2)), ["Refresh", "Quit"])
        let refreshIndex = menu.items.firstIndex { $0.action == .refresh }!
        XCTAssertTrue(menu.items[..<refreshIndex].contains(where: \.isSeparator))
    }

    func testPresetsCarryTheirWakeTimeAsTheAction() {
        let submenu = present(.off).submenu(titled: MenuPresentation.wakeAtTitle)!
        XCTAssertEqual(
            submenu.compactMap(\.action),
            [
                .enable(hour: 6, minute: 30),
                .enable(hour: 7, minute: 30),
                .enable(hour: 8, minute: 30),
                .chooseCustomTime,
            ]
        )
        XCTAssertEqual(submenu.map(\.title), ["06:30", "07:30", "08:30", MenuPresentation.customTitle])
    }

    func testTheCustomItemKeepsItsEllipsis() {
        // The HIG reserves an ellipsis for an action that needs more input first.
        XCTAssertTrue(MenuPresentation.customTitle.hasSuffix("…"))
        XCTAssertFalse(MenuPresentation.turnOffTitle.contains("…"))
    }
}
