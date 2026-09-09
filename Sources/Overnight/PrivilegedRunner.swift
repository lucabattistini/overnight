import Foundation
import OvernightCore

/// Runs one privileged payload script behind one administrator prompt.
///
/// The prompt is raised by AppleScript's `do shell script ... with administrator privileges`,
/// driven through `osascript` as a subprocess. Driving it as a subprocess rather than through
/// `NSAppleScript` keeps the blocking authorization dialog off the main thread without having
/// to reason about `NSAppleScript`'s thread safety.
///
/// Two independent escaping layers protect the command. `SafeArgument.appleScriptLiteral`
/// escapes each value for the AppleScript source string, and AppleScript's own `quoted form of`
/// escapes it again for the shell that finally runs it. The app bundle path goes through both,
/// because a user can rename the bundle to anything the Finder allows.
enum PrivilegedRunner {
    enum Action {
        case enable(Deadline)
        case restore
    }

    enum PrivilegeError: Error, LocalizedError {
        case userCancelled
        case scriptMissing(String)
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .userCancelled:
                return "Authorization was cancelled."
            case .scriptMissing(let name):
                return "Overnight is missing its \(name) script. Reinstall the app."
            case .failed(let message):
                return message
            }
        }
    }

    /// AppleScript's error number for "User canceled." A cancelled prompt is a decision, not a
    /// failure, so it is mapped to its own case rather than surfaced as an error.
    private static let userCancelledCode = -128

    static func run(_ action: Action) throws {
        let scriptName: String
        var arguments: [String] = []

        switch action {
        case .enable(let deadline):
            scriptName = "overnight-enable"
            let interval = try deadline.calendarInterval()
            arguments = [
                try SafeArgument.number(interval.month, maxDigits: 2),
                try SafeArgument.number(interval.day, maxDigits: 2),
                try SafeArgument.number(interval.hour, maxDigits: 2),
                try SafeArgument.number(interval.minute, maxDigits: 2),
                try SafeArgument.number(deadline.epochSeconds, maxDigits: 11),
            ]
        case .restore:
            scriptName = "overnight-restore"
        }

        guard let url = Bundle.main.url(forResource: scriptName, withExtension: "sh") else {
            throw PrivilegeError.scriptMissing(scriptName)
        }
        let scriptPath = try SafeArgument.path(url.path)

        let source = appleScriptSource(scriptPath: scriptPath, arguments: arguments)
        let result = try CommandRunner.run("/usr/bin/osascript", ["-e", source])

        guard result.succeeded else {
            if result.standardError.contains("\(userCancelledCode)") {
                throw PrivilegeError.userCancelled
            }
            let detail = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            throw PrivilegeError.failed(detail.isEmpty ? "The privileged step failed." : detail)
        }
    }

    /// Builds `do shell script "/bin/sh " & quoted form of "…" & " " & quoted form of "…" …
    /// with administrator privileges`.
    static func appleScriptSource(scriptPath: String, arguments: [String]) -> String {
        var terms = ["\"/bin/sh \"", "quoted form of \(SafeArgument.appleScriptLiteral(scriptPath))"]
        for argument in arguments {
            terms.append("\" \"")
            terms.append("quoted form of \(SafeArgument.appleScriptLiteral(argument))")
        }
        return "do shell script \(terms.joined(separator: " & ")) with administrator privileges"
    }
}
