import Foundation

/// A wake time expressed as a time of day, resolved to its next occurrence.
///
/// Overnight has no indefinite mode: every enable carries one of these.
public struct Deadline: Equatable, Sendable {
    public let hour: Int
    public let minute: Int
    /// The resolved absolute instant the restore is armed for.
    public let date: Date

    public enum DeadlineError: Error, Equatable, CustomStringConvertible {
        case hourOutOfRange(Int)
        case minuteOutOfRange(Int)
        case unresolvable

        public var description: String {
            switch self {
            case .hourOutOfRange(let h): return "hour out of range: \(h)"
            case .minuteOutOfRange(let m): return "minute out of range: \(m)"
            case .unresolvable: return "could not resolve the deadline in the current calendar"
            }
        }
    }

    /// Resolves `hour:minute` to its next occurrence relative to `now`.
    ///
    /// A time that has already passed today resolves to tomorrow. A time exactly equal to now
    /// also resolves to tomorrow, because arming a restore for the current instant would fire
    /// before the profile finished being applied.
    public init(hour: Int, minute: Int, now: Date = Date(), calendar: Calendar = .current) throws {
        guard (0...23).contains(hour) else { throw DeadlineError.hourOutOfRange(hour) }
        guard (0...59).contains(minute) else { throw DeadlineError.minuteOutOfRange(minute) }

        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = hour
        components.minute = minute
        components.second = 0

        guard var candidate = calendar.date(from: components) else { throw DeadlineError.unresolvable }
        if candidate <= now {
            guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: candidate) else {
                throw DeadlineError.unresolvable
            }
            candidate = tomorrow
        }

        self.hour = hour
        self.minute = minute
        self.date = candidate
    }

    /// The calendar fields `launchd` needs for a one-shot `StartCalendarInterval`.
    ///
    /// Month and day are included so the job is effectively one-shot even if the restore
    /// script never gets to remove it.
    public func calendarInterval(calendar: Calendar = .current) throws -> (month: Int, day: Int, hour: Int, minute: Int) {
        let parts = calendar.dateComponents([.month, .day, .hour, .minute], from: date)
        guard let month = parts.month, let day = parts.day,
              let resolvedHour = parts.hour, let resolvedMinute = parts.minute else {
            throw DeadlineError.unresolvable
        }
        return (month, day, resolvedHour, resolvedMinute)
    }

    public var epochSeconds: Int { Int(date.timeIntervalSince1970) }

    /// `07:30`, for display.
    public var shortLabel: String { String(format: "%02d:%02d", hour, minute) }
}
