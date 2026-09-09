import Foundation

/// The only power-management settings Overnight is allowed to read or write.
///
/// This list is the single source of truth on the Swift side. `payload/overnight-enable.sh`
/// and `payload/overnight-restore.sh` carry the same list, and CI greps all three to make
/// sure they cannot drift apart.
public enum ManagedSetting: String, CaseIterable, Sendable, Comparable {
    case sleep
    case disksleep
    case displaysleep
    case powernap
    case tcpkeepalive

    public static func < (lhs: ManagedSetting, rhs: ManagedSetting) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Which `pmset` profile a value belongs to.
public enum PowerProfile: String, Sendable {
    case ac
    case battery

    /// The `pmset` flag that scopes a write to this profile.
    public var pmsetFlag: String {
        switch self {
        case .ac: return "-c"
        case .battery: return "-b"
        }
    }
}

/// The overnight profile Overnight applies to the AC profile.
///
/// Two settings from the original one-line script are deliberately absent.
///
/// `disablesleep` is absent because it is a system-wide switch with no per-power-source form.
/// The 2026-09-09 hardware spike confirmed that `pmset -c disablesleep 1` exits 0, prints no
/// warning, and writes global `SleepDisabled=1` anyway. It is applied separately with `-a` and
/// its global reach is the reason the AC watcher exists.
///
/// `tcpkeepalive` is absent because its `-c` scoping could not be verified: the spike machine
/// already had it set to 1 on both profiles, so a scoped write was indistinguishable from a
/// global one. Writing a setting whose blast radius is unknown would risk changing the battery
/// profile, so Overnight does not write it at all. Nothing is lost: `disablesleep 1` and
/// `sleep 0` mean the machine never sleeps, and `tcpkeepalive` only governs behaviour during
/// sleep. It is still captured, for diagnostics and so the saved state describes the machine
/// fully.
public let overnightACProfile: [ManagedSetting: Int] = [
    .sleep: 0,
    .disksleep: 0,
    .powernap: 0,
    .displaysleep: 2,
]

public enum CaptureError: Error, Equatable, CustomStringConvertible {
    case nonNumericValue(key: String, raw: String)
    case valueOutOfRange(key: String, raw: String)
    case unknownStateKey(String)
    case malformedStateLine(String)
    case unsupportedStateVersion(String)

    public var description: String {
        switch self {
        case .nonNumericValue(let key, let raw):
            return "non-numeric value for managed setting '\(key)': '\(raw)'"
        case .valueOutOfRange(let key, let raw):
            return "value out of range for '\(key)': '\(raw)'"
        case .unknownStateKey(let key):
            return "unknown key in saved state: '\(key)'"
        case .malformedStateLine(let line):
            return "malformed line in saved state: '\(line)'"
        case .unsupportedStateVersion(let raw):
            return "unsupported saved-state version: '\(raw)'"
        }
    }
}

/// Everything Overnight recorded before it changed anything.
///
/// A setting missing from `ac` or `battery` means the installed macOS or this hardware did
/// not report it. Absent stays absent: restore never invents a value for it.
public struct PowerCapture: Equatable, Sendable {
    public static let stateVersion = 1

    public var ac: [ManagedSetting: Int]
    public var battery: [ManagedSetting: Int]
    /// The prior value of the system-wide `SleepDisabled` flag, or nil if `pmset -g` did not report it.
    public var priorSleepDisabled: Bool?
    /// The wake time this run restores at, as whole seconds since the epoch.
    public var deadlineEpoch: Int?

    public init(
        ac: [ManagedSetting: Int] = [:],
        battery: [ManagedSetting: Int] = [:],
        priorSleepDisabled: Bool? = nil,
        deadlineEpoch: Int? = nil
    ) {
        self.ac = ac
        self.battery = battery
        self.priorSleepDisabled = priorSleepDisabled
        self.deadlineEpoch = deadlineEpoch
    }

    public var deadline: Date? {
        deadlineEpoch.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }
}
