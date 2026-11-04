import Foundation

/// A small recursive-descent parser for calculator expressions.
/// Supports + - * / % ^, parentheses, factorial (!), implicit constants and common functions.
struct ExpressionParser {
    enum ParseError: Error, LocalizedError {
        case unexpected(String)
        case unknownIdentifier(String)
        case divisionByZero
        case badArguments(String)
        case missingParenthesis

        var errorDescription: String? {
            switch self {
            case .unexpected(let s): return "Unexpected \(s)"
            case .unknownIdentifier(let s): return "Unknown name “\(s)”"
            case .divisionByZero: return "Division by zero"
            case .badArguments(let s): return "Wrong number of arguments for \(s)"
            case .missingParenthesis: return "Missing closing “)”"
            }
        }
    }

    private let chars: [Character]
    private var pos = 0
    var useDegrees: Bool
    var variables: [String: Double]

    init(_ text: String, useDegrees: Bool = false, variables: [String: Double] = [:]) {
        chars = Array(text.replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: "−", with: "-")
            .replacingOccurrences(of: "π", with: "pi"))
        self.useDegrees = useDegrees
        self.variables = variables
    }

    static func evaluate(_ text: String, useDegrees: Bool = false, variables: [String: Double] = [:]) throws -> Double {
        var parser = ExpressionParser(text, useDegrees: useDegrees, variables: variables)
        return try parser.parse()
    }

    mutating func parse() throws -> Double {
        let value = try parseExpression()
        skipSpaces()
        if pos < chars.count { throw ParseError.unexpected("“\(chars[pos])”") }
        return value
    }

    private mutating func skipSpaces() {
        while pos < chars.count && chars[pos].isWhitespace { pos += 1 }
    }

    private mutating func peek() -> Character? {
        skipSpaces()
        return pos < chars.count ? chars[pos] : nil
    }

    private mutating func parseExpression() throws -> Double {
        var value = try parseTerm()
        while let c = peek(), c == "+" || c == "-" {
            pos += 1
            let rhs = try parseTerm()
            value = c == "+" ? value + rhs : value - rhs
        }
        return value
    }

    private mutating func parseTerm() throws -> Double {
        var value = try parseFactor()
        while let c = peek(), c == "*" || c == "/" || c == "%" {
            pos += 1
            let rhs = try parseFactor()
            switch c {
            case "*": value *= rhs
            case "/":
                if rhs == 0 { throw ParseError.divisionByZero }
                value /= rhs
            default:
                if rhs == 0 { throw ParseError.divisionByZero }
                value = value.truncatingRemainder(dividingBy: rhs)
            }
        }
        return value
    }

    /// unary := ("-" | "+") unary | power   (so -2^2 = -4)
    private mutating func parseFactor() throws -> Double {
        if let c = peek(), c == "-" || c == "+" {
            pos += 1
            let value = try parseFactor()
            return c == "-" ? -value : value
        }
        return try parsePower()
    }

    /// power := postfix ("^" unary)?   (right associative, allows 2^-1)
    private mutating func parsePower() throws -> Double {
        let base = try parsePostfix()
        if let c = peek(), c == "^" {
            pos += 1
            let exponent = try parseFactor()
            return pow(base, exponent)
        }
        return base
    }

    private mutating func parsePostfix() throws -> Double {
        var value = try parsePrimary()
        while let c = peek(), c == "!" {
            pos += 1
            guard value >= 0, value <= 170, value == value.rounded() else {
                throw ParseError.badArguments("factorial")
            }
            var result = 1.0
            var k = 2.0
            while k <= value {
                result *= k
                k += 1
            }
            value = result
        }
        return value
    }

    private mutating func parsePrimary() throws -> Double {
        guard let c = peek() else { throw ParseError.unexpected("end of input") }
        if c == "(" {
            pos += 1
            let value = try parseExpression()
            guard let close = peek(), close == ")" else { throw ParseError.missingParenthesis }
            pos += 1
            return value
        }
        if c.isNumber || c == "." {
            return try parseNumber()
        }
        if c.isLetter || c == "_" {
            var name = ""
            while pos < chars.count && (chars[pos].isLetter || chars[pos].isNumber || chars[pos] == "_") {
                name.append(chars[pos])
                pos += 1
            }
            let lower = name.lowercased()
            if let next = peek(), next == "(" {
                pos += 1
                var args: [Double] = []
                if let close = peek(), close == ")" {
                    pos += 1
                } else {
                    while true {
                        args.append(try parseExpression())
                        guard let sep = peek() else { throw ParseError.missingParenthesis }
                        pos += 1
                        if sep == ")" { break }
                        if sep != "," { throw ParseError.unexpected("“\(sep)”") }
                    }
                }
                return try callFunction(lower, args)
            }
            switch lower {
            case "pi": return Double.pi
            case "e": return M_E
            case "tau": return 2 * Double.pi
            case "phi": return (1 + 5.0.squareRoot()) / 2
            case "inf", "infinity": return Double.infinity
            default:
                if let v = variables[lower] { return v }
                throw ParseError.unknownIdentifier(name)
            }
        }
        throw ParseError.unexpected("“\(c)”")
    }

    private mutating func parseNumber() throws -> Double {
        let start = pos
        // Hex / binary / octal literals
        if chars[pos] == "0" && pos + 1 < chars.count {
            let prefix = chars[pos + 1].lowercased()
            let radix: Int? = prefix == "x" ? 16 : (prefix == "b" ? 2 : (prefix == "o" ? 8 : nil))
            if let radix = radix {
                pos += 2
                var digits = ""
                while pos < chars.count && (chars[pos].isHexDigit) {
                    digits.append(chars[pos])
                    pos += 1
                }
                guard let v = Int64(digits, radix: radix) else { throw ParseError.unexpected("number") }
                return Double(v)
            }
        }
        while pos < chars.count && (chars[pos].isNumber || chars[pos] == "." || chars[pos] == "_") { pos += 1 }
        if pos < chars.count && (chars[pos] == "e" || chars[pos] == "E") {
            var look = pos + 1
            if look < chars.count && (chars[look] == "+" || chars[look] == "-") { look += 1 }
            if look < chars.count && chars[look].isNumber {
                pos = look
                while pos < chars.count && chars[pos].isNumber { pos += 1 }
            }
        }
        let text = String(chars[start..<pos]).replacingOccurrences(of: "_", with: "")
        guard let value = Double(text) else { throw ParseError.unexpected("number “\(text)”") }
        return value
    }

    private func callFunction(_ name: String, _ args: [Double]) throws -> Double {
        func one() throws -> Double {
            guard args.count == 1 else { throw ParseError.badArguments(name) }
            return args[0]
        }
        let toRad: (Double) -> Double = { useDegrees ? $0 * Double.pi / 180 : $0 }
        let fromRad: (Double) -> Double = { useDegrees ? $0 * 180 / Double.pi : $0 }
        switch name {
        case "sqrt": return try one().squareRoot()
        case "cbrt": return cbrt(try one())
        case "abs": return abs(try one())
        case "sin": return sin(toRad(try one()))
        case "cos": return cos(toRad(try one()))
        case "tan": return tan(toRad(try one()))
        case "asin": return fromRad(asin(try one()))
        case "acos": return fromRad(acos(try one()))
        case "atan": return fromRad(atan(try one()))
        case "sinh": return sinh(try one())
        case "cosh": return cosh(try one())
        case "tanh": return tanh(try one())
        case "ln": return log(try one())
        case "log", "log10": return log10(try one())
        case "log2": return log2(try one())
        case "exp": return exp(try one())
        case "floor": return floor(try one())
        case "ceil": return ceil(try one())
        case "round": return (try one()).rounded()
        case "sign": return (try one()).sign == .minus ? -1 : 1
        case "deg": return try one() * 180 / Double.pi
        case "rad": return try one() * Double.pi / 180
        case "pow":
            guard args.count == 2 else { throw ParseError.badArguments(name) }
            return pow(args[0], args[1])
        case "min":
            guard let v = args.min() else { throw ParseError.badArguments(name) }
            return v
        case "max":
            guard let v = args.max() else { throw ParseError.badArguments(name) }
            return v
        case "avg", "mean":
            guard !args.isEmpty else { throw ParseError.badArguments(name) }
            return args.reduce(0, +) / Double(args.count)
        case "sum": return args.reduce(0, +)
        case "hypot":
            guard args.count == 2 else { throw ParseError.badArguments(name) }
            return hypot(args[0], args[1])
        case "random", "rand":
            if args.count == 2 { return Double.random(in: min(args[0], args[1])...max(args[0], args[1])) }
            return Double.random(in: 0..<1)
        default:
            throw ParseError.unknownIdentifier(name)
        }
    }
}
