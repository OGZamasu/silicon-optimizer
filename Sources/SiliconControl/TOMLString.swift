import Foundation

/// The inside of a TOML basic string, for every file this app writes TOML into — Codex's
/// own config under the app's private home, and the MCP section it adds to the user's
/// `~/.codex/config.toml`. One escaper, so no writer is left with a partial one.
public enum TOMLString {

    /// Everything the spec says must be escaped, is. Quotes and backslashes alone are not
    /// enough: a raw newline ends the line, and whatever follows it is read as the next
    /// line of the file — a table header, a `command`. Control characters other than the
    /// named ones go out as `\uXXXX`, the only form TOML accepts for them.
    public static func escaped(_ value: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(value.utf8.count)
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\u{08}": escaped += "\\b"
            case "\t": escaped += "\\t"
            case "\n": escaped += "\\n"
            case "\u{0C}": escaped += "\\f"
            case "\r": escaped += "\\r"
            case _ where scalar.value < 0x20 || scalar.value == 0x7F:
                escaped += String(format: "\\u%04X", scalar.value)
            default:
                escaped.unicodeScalars.append(scalar)
            }
        }
        return escaped
    }

    /// The reverse, for the contents of a basic string up to (not including) its closing
    /// quote. Nil for an escape TOML does not have.
    public static func unescaped<S: StringProtocol>(_ contents: S) -> String? {
        var value = ""
        var scalars = contents.unicodeScalars.makeIterator()
        while let scalar = scalars.next() {
            guard scalar == "\\" else { value.unicodeScalars.append(scalar); continue }
            guard let next = scalars.next() else { return nil }
            switch next {
            case "\\": value += "\\"
            case "\"": value += "\""
            case "b": value += "\u{08}"
            case "t": value += "\t"
            case "n": value += "\n"
            case "f": value += "\u{0C}"
            case "r": value += "\r"
            case "u", "U":
                var hex = ""
                for _ in 0..<(next == "u" ? 4 : 8) {
                    guard let digit = scalars.next() else { return nil }
                    hex.unicodeScalars.append(digit)
                }
                guard let code = UInt32(hex, radix: 16), let decoded = Unicode.Scalar(code)
                else { return nil }
                value.unicodeScalars.append(decoded)
            default:
                return nil
            }
        }
        return value
    }
}
