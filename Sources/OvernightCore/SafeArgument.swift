import Foundation

/// The single choke point for values that cross out of Swift into a shell command,
/// an AppleScript source string, or a property list.
///
/// Nothing reaches those layers without passing through here first. The shell payload
/// re-validates everything it receives, so an escape would have to defeat both layers.
public enum SafeArgument {
    public enum ValidationError: Error, Equatable, CustomStringConvertible {
        case notNumeric(String)
        case tooManyDigits(String)
        case notAbsolutePath(String)
        case pathContainsControlCharacter(String)

        public var description: String {
            switch self {
            case .notNumeric(let v): return "value is not a plain number: '\(v)'"
            case .tooManyDigits(let v): return "value has too many digits: '\(v)'"
            case .notAbsolutePath(let v): return "path is not absolute: '\(v)'"
            case .pathContainsControlCharacter(let v): return "path contains a control character: '\(v)'"
            }
        }
    }

    /// Accepts only a run of ASCII digits, at most `maxDigits` of them.
    ///
    /// This rejects `1; touch /tmp/x`, `$(id)`, `-1`, `1 2`, and anything with a newline,
    /// because none of those are a bare run of digits.
    public static func number(_ value: Int, maxDigits: Int = 5) throws -> String {
        let rendered = String(value)
        return try number(rendered, maxDigits: maxDigits)
    }

    public static func number(_ value: String, maxDigits: Int = 5) throws -> String {
        guard !value.isEmpty, value.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            throw ValidationError.notNumeric(value)
        }
        guard value.count <= maxDigits else { throw ValidationError.tooManyDigits(value) }
        return value
    }

    /// Accepts an absolute path with no control characters.
    ///
    /// The path is not otherwise restricted: the app bundle can be renamed to anything the
    /// Finder allows, including quotes and spaces. Those survive because the path is escaped
    /// twice on the way out — `appleScriptLiteral` for the AppleScript layer and AppleScript's
    /// own `quoted form of` for the shell layer.
    public static func path(_ value: String) throws -> String {
        guard value.hasPrefix("/") else { throw ValidationError.notAbsolutePath(value) }
        guard !value.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
            throw ValidationError.pathContainsControlCharacter(value)
        }
        return value
    }

    /// Renders a string as an AppleScript double-quoted literal.
    ///
    /// AppleScript string literals only need backslash and double-quote escaped. This handles
    /// the AppleScript layer; the shell layer is handled by `quoted form of` inside the script.
    public static func appleScriptLiteral(_ value: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(value.count + 2)
        for character in value {
            switch character {
            case "\\": escaped.append("\\\\")
            case "\"": escaped.append("\\\"")
            default: escaped.append(character)
            }
        }
        return "\"\(escaped)\""
    }
}
