import Foundation

public struct MenuPresentation: Equatable, Sendable {

    public enum Action: Equatable, Sendable {
        case enable(hour: Int, minute: Int)
        case chooseCustomTime
        case turnOff
        case cleanUpStaleState
        case copyRecoveryCommand
        case refresh
        case quit

        public var isPrivileged: Bool {
            switch self {
            case .enable, .chooseCustomTime, .turnOff, .cleanUpStaleState: return true
            case .copyRecoveryCommand, .refresh, .quit: return false
            }
        }
    }

    public enum Symbol: Equatable, Sendable {
        case warning
    }

    public struct Item: Equatable, Sendable {
        public let title: String
        public let tooltip: String?
        public let symbol: Symbol?
        public let isEnabled: Bool
        public let isChecked: Bool
        public let action: Action?
        public let children: [Item]?
        public let isSeparator: Bool

        static func separator() -> Item {
            Item(title: "", tooltip: nil, symbol: nil, isEnabled: false, isChecked: false, action: nil, children: nil, isSeparator: true)
        }

        static func label(_ title: String, tooltip: String? = nil, symbol: Symbol? = nil) -> Item {
            Item(title: title, tooltip: tooltip, symbol: symbol, isEnabled: false, isChecked: false, action: nil, children: nil, isSeparator: false)
        }

        static func action(_ title: String, _ action: Action, enabled: Bool = true, checked: Bool = false, tooltip: String? = nil) -> Item {
            Item(title: title, tooltip: tooltip, symbol: nil, isEnabled: enabled, isChecked: checked, action: action, children: nil, isSeparator: false)
        }

        static func submenu(_ title: String, _ children: [Item]) -> Item {
            Item(title: title, tooltip: nil, symbol: nil, isEnabled: true, isChecked: false, action: nil, children: children, isSeparator: false)
        }
    }

    public let items: [Item]

    // MARK: - Fixed strings

    public static let wakeAtTitle = "Wake at"
    public static let customTitle = "Custom…"
    public static let turnOffTitle = "Turn Off Now"
    public static let cleanUpTitle = "Clean up leftover state"
    public static let copyCommandTitle = "Copy Command to Clipboard"
    public static let refreshTitle = "Refresh"
    public static let quitTitle = "Quit"
    public static let busyTitle = "Working…"

    public static let batteryWarningTitle = "Running on battery"
    public static let timerWarningTitle = "No automatic restore"
    public static let errorWarningTitle = "Something went wrong"

    private static let batteryWarningDetail =
        "Sleep is disabled system-wide, so this Mac will not sleep on battery. Restore now."
    private static let timerWarningDetail =
        "The timer that would turn Overnight off is gone. Re-arm it, or turn Overnight off now."

    public static let defaultPresets = [6 * 60 + 30, 7 * 60 + 30, 8 * 60 + 30]

    // MARK: - Building

    public static func make(
        status: OvernightStatus,
        onBatteryWhileActive: Bool,
        lastError: String?,
        isBusy: Bool,
        presets: [Int] = MenuPresentation.defaultPresets,
        calendar: Calendar = .current
    ) -> MenuPresentation {
        var items: [Item] = [.label(isBusy ? busyTitle : stateLine(for: status, calendar: calendar))]

        if let warning = warning(status: status, onBatteryWhileActive: onBatteryWhileActive, lastError: lastError) {
            items.append(.separator())
            items.append(warning)
        }
        var actions: [Item] = []
        if status.canEnable && allows(.chooseCustomTime, isBusy: isBusy) {
            actions.append(.submenu(wakeAtTitle, wakeAtItems(status: status, presets: presets, calendar: calendar)))
        }
        if status.isActive {
            actions.append(.action(turnOffTitle, .turnOff, enabled: allows(.turnOff, isBusy: isBusy)))
        }
        if case .offWithStaleState = status {
            actions.append(.action(cleanUpTitle, .cleanUpStaleState, enabled: allows(.cleanUpStaleState, isBusy: isBusy)))
        }
        if case .externallyDisabled = status {
            actions.append(.action(copyCommandTitle, .copyRecoveryCommand, tooltip: OvernightPaths.recoveryCommand))
        }
        if !actions.isEmpty {
            items.append(.separator())
            items.append(contentsOf: actions)
        }

        items.append(.separator())
        items.append(.action(refreshTitle, .refresh))
        items.append(.action(quitTitle, .quit))

        return MenuPresentation(items: items)
    }

    private static func allows(_ action: Action, isBusy: Bool) -> Bool {
        !(isBusy && action.isPrivileged)
    }

    private static func wakeAtItems(status: OvernightStatus, presets: [Int], calendar: Calendar) -> [Item] {
        let current = status.isActive ? minutesOfDay(status.deadline, calendar: calendar) : nil
        var items = presets.map { minutes in
            Item.action(
                label(forMinutesOfDay: minutes),
                .enable(hour: minutes / 60, minute: minutes % 60),
                checked: current == minutes
            )
        }
        let matchesAPreset = current.map(presets.contains) ?? true
        items.append(.action(customTitle, .chooseCustomTime, checked: !matchesAPreset))
        return items
    }

    private static func minutesOfDay(_ date: Date?, calendar: Calendar) -> Int? {
        guard let date else { return nil }
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        guard let hour = parts.hour, let minute = parts.minute else { return nil }
        return hour * 60 + minute
    }

    private static func label(forMinutesOfDay minutes: Int) -> String {
        Deadline.label(hour: minutes / 60, minute: minutes % 60)
    }

    private static func warning(status: OvernightStatus, onBatteryWhileActive: Bool, lastError: String?) -> Item? {
        if let lastError, !lastError.isEmpty {
            return .label(errorWarningTitle, tooltip: lastError, symbol: .warning)
        }
        if case .activeTimerMissing = status {
            return .label(timerWarningTitle, tooltip: timerWarningDetail, symbol: .warning)
        }
        if onBatteryWhileActive {
            return .label(batteryWarningTitle, tooltip: batteryWarningDetail, symbol: .warning)
        }
        return nil
    }

    private static func stateLine(for status: OvernightStatus, calendar: Calendar) -> String {
        switch status {
        case .off:
            return "Off. This Mac sleeps normally."
        case .offWithStaleState:
            return "Off, with a leftover state file to clean up."
        case .active(let deadline):
            return "On until \(formatted(deadline, calendar: calendar))."
        case .activeTimerMissing(let deadline):
            return "On, but the \(formatted(deadline, calendar: calendar)) timer is missing."
        case .externallyDisabled:
            return "Sleep is disabled, but not by Overnight."
        }
    }

    private static func formatted(_ date: Date?, calendar: Calendar) -> String {
        guard let date else { return "an unknown time" }
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE HH:mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        return formatter.string(from: date)
    }

    // MARK: - Reading

    public var warnings: [Item] { items.filter { $0.symbol == .warning } }

    public func submenu(titled title: String) -> [Item]? {
        items.first { $0.title == title && $0.children != nil }?.children
    }

    public func item(withAction action: Action) -> Item? {
        Self.firstItem(in: items) { $0.action == action }
    }

    public func containsAction(_ matches: (Action) -> Bool) -> Bool {
        Self.firstItem(in: items) { item in item.action.map(matches) ?? false } != nil
    }

    private static func firstItem(in items: [Item], where matches: (Item) -> Bool) -> Item? {
        for item in items {
            if matches(item) { return item }
            if let children = item.children, let found = firstItem(in: children, where: matches) { return found }
        }
        return nil
    }
}
