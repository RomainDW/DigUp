import Foundation

/// A sum typed in the panel ("10 + 2", "15% * 80", "(3,5 + 1) / 2", "2^10", "sqrt(2)") and its result, ready to copy.
nonisolated struct Calculation: Sendable, Equatable {
    static let rowID = "\u{0}calc"

    let expression: String
    let value: Double
    /// The decimal mark the sum was typed with: the result is copied with the same one.
    let decimalMark: Character

    /// The result as it's copied: no thousands separators, at most 10 decimals, no trailing zeros.
    var text: String {
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = abs(value) >= 1e15 || abs(value) < 1e-10 ? .scientific : .decimal
        formatter.usesGroupingSeparator = false
        formatter.maximumFractionDigits = 10
        formatter.maximumSignificantDigits = 15
        let plain = formatter.string(from: value as NSNumber) ?? "\(value)"
        return decimalMark == "," ? plain.replacingOccurrences(of: ".", with: ",") : plain
    }

    /// The result as it's shown: thousands grouped ("1 234 567,5" is copied as "1234567,5").
    var display: String {
        guard abs(value) >= 10_000, abs(value) < 1e15 else { return text }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 10
        formatter.groupingSeparator = decimalMark == "," ? "\u{202F}" : ","
        formatter.decimalSeparator = String(decimalMark)
        return formatter.string(from: value as NSNumber) ?? text
    }

    /// nil unless the text is a sum: numbers with at least one operator (or %, ^, a function), nothing else.
    init?(_ text: String) {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard typed.count >= 2, typed.contains(where: \.isNumber) else { return nil }
        var parser = Parser(typed)
        guard let value = parser.parse(), value.isFinite, parser.operators > 0 else { return nil }
        expression = typed
        self.value = value
        decimalMark = typed.contains(",") && !typed.contains(".") ? "," : "."
    }

    /// Recursive descent over the usual precedence: + − below × ÷ below unary minus below ^ below %.
    private struct Parser {
        let characters: [Character]
        var index = 0
        /// How many operators or functions it read: "42" alone isn't a sum.
        var operators = 0
        /// The last term read was a bare percentage ("10%"): after + or − it's a share of what's on the left.
        private var termIsPercent = false

        init(_ text: String) {
            characters = Array(text.replacingOccurrences(of: "×", with: "*").replacingOccurrences(of: "÷", with: "/")
                .replacingOccurrences(of: "−", with: "-").replacingOccurrences(of: "**", with: "^")
                .filter { !$0.isWhitespace })
        }

        mutating func parse() -> Double? {
            guard let value = expression() else { return nil }
            // Parentheses left open at the end close themselves ("(2 + 3" while typing).
            return index == characters.count ? value : nil
        }

        private var current: Character? { index < characters.count ? characters[index] : nil }

        private mutating func take(_ character: Character) -> Bool {
            guard current == character else { return false }
            index += 1
            return true
        }

        private mutating func expression() -> Double? {
            guard var value = term() else { return nil }
            while let op = current, op == "+" || op == "-" {
                index += 1
                operators += 1
                guard let right = term() else { return nil }
                let amount = termIsPercent ? value * right : right   // 200 + 10% = 220
                value = op == "+" ? value + amount : value - amount
            }
            return value
        }

        private mutating func term() -> Double? {
            termIsPercent = false
            let start = index
            guard var value = unary() else { return nil }
            termIsPercent = index > start && characters[index - 1] == "%" && !characters[start..<index].contains("(")
            while let op = current, op == "*" || op == "/" || op == "x" {
                termIsPercent = false
                index += 1
                operators += 1
                guard let right = unary() else { return nil }
                value = op == "/" ? value / right : value * right
            }
            return value
        }

        private mutating func unary() -> Double? {
            if take("-") { return unary().map { -$0 } }
            if take("+") { return unary() }
            return power()
        }

        private mutating func power() -> Double? {
            guard let base = postfix() else { return nil }
            guard take("^") else { return base }
            operators += 1
            return unary().map { pow(base, $0) }   // right-associative: 2^3^2 = 2^9
        }

        private mutating func postfix() -> Double? {
            guard var value = primary() else { return nil }
            while take("%") {
                operators += 1
                value /= 100
            }
            return value
        }

        private mutating func primary() -> Double? {
            if take("(") {
                let value = expression()
                _ = take(")") || index == characters.count   // a missing ")" at the very end is fine
                return value
            }
            if let current, current.isLetter, current != "x" || index + 1 < characters.count && characters[index + 1].isLetter {
                return function()
            }
            return number()
        }

        private mutating func function() -> Double? {
            var name = ""
            while let current, current.isLetter {
                name.append(current)
                index += 1
            }
            switch name.lowercased() {
            case "pi", "π": return .pi
            case "e": return M_E
            default: break
            }
            let functions: [String: (Double) -> Double] = [
                "sqrt": { $0.squareRoot() }, "racine": { $0.squareRoot() }, "abs": { abs($0) },
                "round": { $0.rounded() }, "floor": { $0.rounded(.down) }, "ceil": { $0.rounded(.up) },
                "ln": { log($0) }, "log": { log10($0) }, "sin": { sin($0) }, "cos": { cos($0) }, "tan": { tan($0) },
            ]
            guard let apply = functions[name.lowercased()], take("(") else { return nil }
            operators += 1
            guard let value = expression() else { return nil }
            _ = take(")") || index == characters.count
            return apply(value)
        }

        private mutating func number() -> Double? {
            var digits = ""
            while let current, current.isNumber || current == "." || current == "," {
                digits.append(current == "," ? "." : current)
                index += 1
            }
            return Double(digits)
        }
    }
}
