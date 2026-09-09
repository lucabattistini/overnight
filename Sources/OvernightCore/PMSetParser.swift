import Foundation

/// Reads `pmset` output and Overnight's saved-state file, and builds the argument
/// vectors that write settings back.
///
/// Every value that comes out of this type has passed a strict numeric allowlist. Nothing
/// here ever builds a shell string: callers get argument arrays.
public enum PMSetParser {
    /// The widest value Overnight will accept for a managed setting. `pmset` timer values are
    /// minutes and flags are 0/1, so five digits is generous.
    static let maxSettingDigits = 5
    static let maxEpochDigits = 11

    // MARK: - pmset -g custom

    private static let batteryHeader = "Battery Power:"
    private static let acHeader = "AC Power:"

    /// Parses the output of `pmset -g custom` into the AC and battery halves of a capture.
    ///
    /// Section membership is decided by the `Battery Power:` / `AC Power:` headers, never by
    /// the order the sections appear in. A machine with no battery reports only `AC Power:`.
    /// Keys outside `ManagedSetting` are ignored, including non-numeric ones such as
    /// `hibernatefile`. A managed key with a non-numeric value is an error, not a silent skip.
    public static func parseCustom(_ output: String) throws -> (ac: [ManagedSetting: Int], battery: [ManagedSetting: Int]) {
        var ac: [ManagedSetting: Int] = [:]
        var battery: [ManagedSetting: Int] = [:]
        var current: PowerProfile?

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if line == batteryHeader {
                current = .battery
                continue
            }
            if line == acHeader {
                current = .ac
                continue
            }
            // Any other header-shaped line ends the current section rather than leaking
            // settings from an unrelated block into it.
            if line.hasSuffix(":") && !line.contains(" ") {
                current = nil
                continue
            }

            guard let profile = current else { continue }
            guard let (key, value) = splitKeyValue(line) else { continue }
            guard let setting = ManagedSetting(rawValue: key) else { continue }

            let parsed = try numericValue(key: key, raw: value)
            switch profile {
            case .ac: ac[setting] = parsed
            case .battery: battery[setting] = parsed
            }
        }

        return (ac, battery)
    }

    // MARK: - pmset -g

    /// Extracts the system-wide `SleepDisabled` flag from `pmset -g` output.
    ///
    /// `disablesleep` is undocumented and never appears in `pmset -g custom`; it is written to
    /// the system-wide settings and reads back here. Returns nil when the running macOS does
    /// not report the flag at all.
    public static func parseSleepDisabled(_ output: String) throws -> Bool? {
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let (key, value) = splitKeyValue(line), key == "SleepDisabled" else { continue }
            let parsed = try numericValue(key: key, raw: value)
            return parsed != 0
        }
        return nil
    }

    // MARK: - Saved state

    /// Serializes a capture to the line-oriented format the shell payload reads.
    ///
    /// The format is `key value` per line with digits-only values. It is deliberately not JSON:
    /// `payload/overnight-restore.sh` has to read it in POSIX shell, and a format whose values
    /// cannot contain a quote, a space, or a shell metacharacter removes the entire quoting
    /// problem from the privileged side.
    public static func renderState(_ capture: PowerCapture) -> String {
        var lines = ["version \(PowerCapture.stateVersion)"]
        if let deadline = capture.deadlineEpoch {
            lines.append("deadline_epoch \(deadline)")
        }
        if let prior = capture.priorSleepDisabled {
            lines.append("prior_sleep_disabled \(prior ? 1 : 0)")
        }
        for setting in ManagedSetting.allCases.sorted() {
            if let value = capture.ac[setting] { lines.append("ac_\(setting.rawValue) \(value)") }
        }
        for setting in ManagedSetting.allCases.sorted() {
            if let value = capture.battery[setting] { lines.append("battery_\(setting.rawValue) \(value)") }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Parses the saved-state file back into a capture.
    ///
    /// The file lives in a root-owned directory, but it is still parsed as untrusted input:
    /// an unknown key, a malformed line, or a value outside the allowlist aborts rather than
    /// being tolerated, so a tampered file can never reach `pmset`.
    public static func parseState(_ contents: String) throws -> PowerCapture {
        var capture = PowerCapture()
        var sawVersion = false

        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            guard let (key, value) = splitKeyValue(line) else {
                throw CaptureError.malformedStateLine(line)
            }

            switch key {
            case "version":
                guard value == String(PowerCapture.stateVersion) else {
                    throw CaptureError.unsupportedStateVersion(value)
                }
                sawVersion = true
            case "deadline_epoch":
                capture.deadlineEpoch = try numericValue(key: key, raw: value, maxDigits: maxEpochDigits)
            case "prior_sleep_disabled":
                capture.priorSleepDisabled = try numericValue(key: key, raw: value) != 0
            default:
                if let setting = managedSetting(key, prefix: "ac_") {
                    capture.ac[setting] = try numericValue(key: key, raw: value)
                } else if let setting = managedSetting(key, prefix: "battery_") {
                    capture.battery[setting] = try numericValue(key: key, raw: value)
                } else {
                    throw CaptureError.unknownStateKey(key)
                }
            }
        }

        guard sawVersion else { throw CaptureError.unsupportedStateVersion("missing") }
        return capture
    }

    // MARK: - Write vectors

    /// The `pmset` argument vector that applies the overnight profile.
    ///
    /// The AC timers are scoped with `-c` so the battery profile is never written, and
    /// `disablesleep` is applied with `-a` because it has no per-power-source form.
    public static func applyArguments() -> [String] {
        var args = ["-c"]
        for setting in ManagedSetting.allCases.sorted() {
            guard let value = overnightACProfile[setting] else { continue }
            args.append(setting.rawValue)
            args.append(String(value))
        }
        args.append(contentsOf: ["-a", "disablesleep", "1"])
        return args
    }

    /// The `pmset` argument vector that replays a capture.
    ///
    /// Emits the intersection of three sets: the keys Overnight actually writes, the keys this
    /// machine reported, and nothing else. A setting Overnight never changed is never written
    /// back, even when the capture recorded it — replaying an unchanged value is still a write,
    /// and the whole point of the capture is that Overnight touches only what it took.
    /// Battery values are recorded for diagnostics but are never emitted, which is what keeps
    /// the battery profile untouched in both directions.
    /// Returns nil when there is nothing to replay.
    public static func restoreArguments(_ capture: PowerCapture) -> [String]? {
        var args: [String] = []
        let acKeys = ManagedSetting.allCases.sorted()
            .filter { overnightACProfile[$0] != nil && capture.ac[$0] != nil }
        if !acKeys.isEmpty {
            args.append("-c")
            for setting in acKeys {
                args.append(setting.rawValue)
                args.append(String(capture.ac[setting]!))
            }
        }
        if let prior = capture.priorSleepDisabled {
            args.append(contentsOf: ["-a", "disablesleep", prior ? "1" : "0"])
        }
        return args.isEmpty ? nil : args
    }

    // MARK: - Helpers

    private static func splitKeyValue(_ line: String) -> (String, String)? {
        let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard parts.count == 2 else { return nil }
        return (String(parts[0]), String(parts[1]))
    }

    private static func managedSetting(_ key: String, prefix: String) -> ManagedSetting? {
        guard key.hasPrefix(prefix) else { return nil }
        return ManagedSetting(rawValue: String(key.dropFirst(prefix.count)))
    }

    static func numericValue(key: String, raw: String, maxDigits: Int = maxSettingDigits) throws -> Int {
        guard !raw.isEmpty, raw.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            throw CaptureError.nonNumericValue(key: key, raw: raw)
        }
        guard raw.count <= maxDigits, let value = Int(raw) else {
            throw CaptureError.valueOutOfRange(key: key, raw: raw)
        }
        return value
    }
}
