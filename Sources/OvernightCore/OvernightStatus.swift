import Foundation

/// What is actually true right now, derived from live `pmset` output plus saved state.
///
/// This is a pure function of three signals so it can be tested without a Mac, and so the
/// menu bar can never show a state that came only from what the UI remembers doing.
public enum OvernightStatus: Equatable, Sendable {
    /// Sleep is not disabled and Overnight holds no capture.
    case off
    /// Sleep is not disabled but a capture is still on disk. Something restored the settings
    /// without cleaning up; the leftover file should be removed.
    case offWithStaleState
    /// Overnight is holding the machine awake and the deadline job is armed.
    case active(deadline: Date?)
    /// Overnight is holding the machine awake but the deadline job is gone, so nothing will
    /// restore automatically.
    case activeTimerMissing(deadline: Date?)
    /// Sleep is disabled but Overnight has no capture, so it did not do this and has no
    /// baseline to replay.
    case externallyDisabled

    /// Whether Overnight is currently holding the machine awake.
    public var isActive: Bool {
        switch self {
        case .active, .activeTimerMissing: return true
        case .off, .offWithStaleState, .externallyDisabled: return false
        }
    }

    /// Whether the app may offer to restore. False for `externallyDisabled`: with no capture
    /// there is nothing to replay, and guessing would overwrite settings Overnight never set.
    public var canRestore: Bool {
        switch self {
        case .active, .activeTimerMissing, .offWithStaleState: return true
        case .off, .externallyDisabled: return false
        }
    }

    public var deadline: Date? {
        switch self {
        case .active(let d), .activeTimerMissing(let d): return d
        case .off, .offWithStaleState, .externallyDisabled: return nil
        }
    }

    /// Derives the status from the three signals.
    ///
    /// - Parameters:
    ///   - sleepDisabled: the system-wide flag from `pmset -g`, or nil when this macOS did not
    ///     report it. When it is nil, an existing capture is taken as the better evidence, so
    ///     the app still offers a restore rather than pretending it is off.
    ///   - capture: the saved state, or nil when there is no Overnight capture on disk.
    ///   - jobInstalled: whether the one-shot restore job is present.
    public static func derive(
        sleepDisabled: Bool?,
        capture: PowerCapture?,
        jobInstalled: Bool
    ) -> OvernightStatus {
        let disabled = sleepDisabled ?? (capture != nil)

        guard disabled else {
            return capture == nil ? .off : .offWithStaleState
        }
        guard let capture else {
            return .externallyDisabled
        }
        return jobInstalled
            ? .active(deadline: capture.deadline)
            : .activeTimerMissing(deadline: capture.deadline)
    }
}
