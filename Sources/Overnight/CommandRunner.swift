import Foundation

/// Runs a command with an explicit executable path and an argument array.
///
/// There is no shell anywhere in this type. Arguments are passed as argv entries, so a value
/// containing a space, a quote, or a semicolon is one argument rather than a parsed fragment.
enum CommandRunner {
    struct Result {
        let exitCode: Int32
        let standardOutput: String
        let standardError: String
        var succeeded: Bool { exitCode == 0 }
    }

    enum RunError: Error, LocalizedError {
        case launchFailed(String)

        var errorDescription: String? {
            switch self {
            case .launchFailed(let message): return message
            }
        }
    }

    static func run(_ executable: String, _ arguments: [String]) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        do {
            try process.run()
        } catch {
            throw RunError.launchFailed("could not run \(executable): \(error.localizedDescription)")
        }

        // Read before waiting so a large output cannot fill the pipe buffer and deadlock.
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return Result(
            exitCode: process.terminationStatus,
            standardOutput: String(decoding: outData, as: UTF8.self),
            standardError: String(decoding: errData, as: UTF8.self)
        )
    }
}
