//
//  AmountParser.swift
//  Relay
//
//  Ports parse_number/get_thousands_separator from the original "YNAB
//  Toolkit" Shortcut's Pythonista script (~/Downloads/YNAB Toolkit.txt), so
//  statement amounts in either "15,000,000.00" (comma-thousands) or
//  "15.000.000,00" (dot-thousands) style parse to the same Double.
//

import Foundation

nonisolated enum AmountParser {
    enum AmountParserError: Error {
        case invalidFormat(String)
    }

    // -?\d+(?:,\d{3})*\.?\d*  — comma-thousands, dot-decimal (e.g. "15,000,000.00")
    private static let commaThousandsStyle = try! NSRegularExpression(pattern: #"^-?\d+(?:,\d{3})*\.?\d*$"#)
    // -?\d+(?:\.\d{3})*,?\d*  — dot-thousands, comma-decimal (e.g. "15.000.000,00")
    private static let dotThousandsStyle = try! NSRegularExpression(pattern: #"^-?\d+(?:\.\d{3})*,?\d*$"#)

    static func parse(_ rawValue: String) throws -> Double {
        let stripped = try sanitize(rawValue)
        var normalized = stripped
        if let separator = try thousandsSeparator(in: stripped) {
            normalized = normalized.replacingOccurrences(of: separator, with: "")
        }
        normalized = normalized.replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalized) else {
            throw AmountParserError.invalidFormat(rawValue)
        }
        return value
    }

    /// Reduces "-269,83 €", "1.234,56 EUR", "269,83-" or "(269,83)" to digits,
    /// separators and at most a leading "-", which is all the styles below match.
    private static func sanitize(_ rawValue: String) throws -> String {
        var text = rawValue.filter { !$0.isWhitespace }
        let isParenthesized = text.hasPrefix("(") && text.hasSuffix(")")
        if isParenthesized {
            text = String(text.dropFirst().dropLast())
        }

        var isNegative = isParenthesized
        var digits = ""
        for character in text {
            switch character {
            case "0"..."9", ",", ".":
                digits.append(character)
            case "-", "\u{2212}":
                isNegative = true
            default:
                continue
            }
        }

        guard digits.contains(where: \.isNumber) else {
            throw AmountParserError.invalidFormat(rawValue)
        }
        return isNegative ? "-" + digits : digits
    }

    /// Returns the character to strip as a thousands separator before
    /// normalizing the decimal separator to `.`. Checks the comma-thousands
    /// shape first, matching the Python original's precedence for
    /// ambiguous values like plain "100".
    private static func thousandsSeparator(in value: String) throws -> String? {
        let range = NSRange(value.startIndex..., in: value)
        if commaThousandsStyle.firstMatch(in: value, range: range) != nil {
            return ","
        }
        if dotThousandsStyle.firstMatch(in: value, range: range) != nil {
            return "."
        }
        throw AmountParserError.invalidFormat(value)
    }
}
