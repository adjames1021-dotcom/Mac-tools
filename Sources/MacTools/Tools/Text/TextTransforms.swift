import Foundation

/// Pure text transformations used by the Text Tools screen.
enum TextTransform: String, CaseIterable, Identifiable {
    // Case
    case upper, lower, title, sentence, camel, pascal, snake, kebab, constant, alternating, invert
    // Lines
    case sortAZ, sortZA, sortNumeric, reverseLines, shuffleLines, dedupeLines, removeEmptyLines, trimLines, numberLines, joinLines, splitWords
    // Clean up
    case trimWhitespace, collapseSpaces, removeLineBreaks, stripPunctuation, removeDiacritics, smartQuotesToStraight, tabsToSpaces
    // Encode / decode
    case base64Encode, base64Decode, urlEncode, urlDecode, htmlEscape, htmlUnescape, rot13, reverseText, unicodeEscape, slugify

    var id: String { rawValue }

    var title: String {
        switch self {
        case .upper: return "UPPERCASE"
        case .lower: return "lowercase"
        case .title: return "Title Case"
        case .sentence: return "Sentence case"
        case .camel: return "camelCase"
        case .pascal: return "PascalCase"
        case .snake: return "snake_case"
        case .kebab: return "kebab-case"
        case .constant: return "CONSTANT_CASE"
        case .alternating: return "aLtErNaTiNg"
        case .invert: return "iNVERT cASE"
        case .sortAZ: return "Sort A→Z"
        case .sortZA: return "Sort Z→A"
        case .sortNumeric: return "Sort numbers"
        case .reverseLines: return "Reverse lines"
        case .shuffleLines: return "Shuffle lines"
        case .dedupeLines: return "Remove duplicates"
        case .removeEmptyLines: return "Remove empty lines"
        case .trimLines: return "Trim each line"
        case .numberLines: return "Number lines"
        case .joinLines: return "Join lines with ,"
        case .splitWords: return "One word per line"
        case .trimWhitespace: return "Trim"
        case .collapseSpaces: return "Collapse spaces"
        case .removeLineBreaks: return "Remove line breaks"
        case .stripPunctuation: return "Strip punctuation"
        case .removeDiacritics: return "Remove accents"
        case .smartQuotesToStraight: return "Straighten quotes"
        case .tabsToSpaces: return "Tabs → spaces"
        case .base64Encode: return "Base64 encode"
        case .base64Decode: return "Base64 decode"
        case .urlEncode: return "URL encode"
        case .urlDecode: return "URL decode"
        case .htmlEscape: return "HTML escape"
        case .htmlUnescape: return "HTML unescape"
        case .rot13: return "ROT13"
        case .reverseText: return "Reverse text"
        case .unicodeEscape: return "Unicode escape"
        case .slugify: return "Slugify"
        }
    }

    static let groups: [(String, [TextTransform])] = [
        ("Case", [.upper, .lower, .title, .sentence, .camel, .pascal, .snake, .kebab, .constant, .alternating, .invert]),
        ("Lines", [.sortAZ, .sortZA, .sortNumeric, .reverseLines, .shuffleLines, .dedupeLines, .removeEmptyLines, .trimLines, .numberLines, .joinLines, .splitWords]),
        ("Clean up", [.trimWhitespace, .collapseSpaces, .removeLineBreaks, .stripPunctuation, .removeDiacritics, .smartQuotesToStraight, .tabsToSpaces]),
        ("Encode / Decode", [.base64Encode, .base64Decode, .urlEncode, .urlDecode, .htmlEscape, .htmlUnescape, .rot13, .reverseText, .unicodeEscape, .slugify])
    ]

    func apply(_ text: String) -> String {
        switch self {
        case .upper: return text.uppercased()
        case .lower: return text.lowercased()
        case .title: return mapLines(text) { TextTransform.titleCase($0) }
        case .sentence: return TextTransform.sentenceCase(text)
        case .camel: return mapLines(text) { TextTransform.joinWords(TextTransform.words($0), style: .camel) }
        case .pascal: return mapLines(text) { TextTransform.joinWords(TextTransform.words($0), style: .pascal) }
        case .snake: return mapLines(text) { TextTransform.words($0).map { $0.lowercased() }.joined(separator: "_") }
        case .kebab: return mapLines(text) { TextTransform.words($0).map { $0.lowercased() }.joined(separator: "-") }
        case .constant: return mapLines(text) { TextTransform.words($0).map { $0.uppercased() }.joined(separator: "_") }
        case .alternating:
            var upper = false
            return String(text.map { ch -> Character in
                guard ch.isLetter else { return ch }
                upper.toggle()
                return Character(upper ? String(ch).lowercased() : String(ch).uppercased())
            })
        case .invert:
            return String(text.map { ch -> Character in
                let s = String(ch)
                return Character(ch.isUppercase ? s.lowercased() : s.uppercased())
            })
        case .sortAZ: return lines(text).sorted { $0.localizedStandardCompare($1) == .orderedAscending }.joined(separator: "\n")
        case .sortZA: return lines(text).sorted { $0.localizedStandardCompare($1) == .orderedDescending }.joined(separator: "\n")
        case .sortNumeric:
            return lines(text).sorted { (Double($0.trimmed) ?? .infinity) < (Double($1.trimmed) ?? .infinity) }.joined(separator: "\n")
        case .reverseLines: return lines(text).reversed().joined(separator: "\n")
        case .shuffleLines: return lines(text).shuffled().joined(separator: "\n")
        case .dedupeLines:
            var seen = Set<String>()
            return lines(text).filter { seen.insert($0).inserted }.joined(separator: "\n")
        case .removeEmptyLines: return lines(text).filter { !$0.trimmed.isEmpty }.joined(separator: "\n")
        case .trimLines: return lines(text).map { $0.trimmed }.joined(separator: "\n")
        case .numberLines:
            let all = lines(text)
            let width = String(all.count).count
            return all.enumerated().map { index, line in
                let n = String(index + 1)
                return String(repeating: " ", count: max(0, width - n.count)) + n + ". " + line
            }.joined(separator: "\n")
        case .joinLines: return lines(text).map { $0.trimmed }.filter { !$0.isEmpty }.joined(separator: ", ")
        case .splitWords: return text.split(whereSeparator: { $0.isWhitespace }).joined(separator: "\n")
        case .trimWhitespace: return text.trimmed
        case .collapseSpaces:
            return mapLines(text) { line in
                line.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
            }
        case .removeLineBreaks:
            return text.components(separatedBy: .newlines).map { $0.trimmed }.filter { !$0.isEmpty }.joined(separator: " ")
        case .stripPunctuation:
            return String(text.unicodeScalars.filter { !CharacterSet.punctuationCharacters.contains($0) }.map(Character.init))
        case .removeDiacritics: return text.folding(options: .diacriticInsensitive, locale: .current)
        case .smartQuotesToStraight:
            return text.replacingOccurrences(of: "\u{201C}", with: "\"")
                .replacingOccurrences(of: "\u{201D}", with: "\"")
                .replacingOccurrences(of: "\u{2018}", with: "'")
                .replacingOccurrences(of: "\u{2019}", with: "'")
                .replacingOccurrences(of: "\u{2013}", with: "-")
                .replacingOccurrences(of: "\u{2014}", with: "--")
                .replacingOccurrences(of: "\u{2026}", with: "...")
        case .tabsToSpaces: return text.replacingOccurrences(of: "\t", with: "    ")
        case .base64Encode: return Data(text.utf8).base64EncodedString()
        case .base64Decode:
            var cleaned = text.trimmed.replacingOccurrences(of: "\n", with: "")
                .replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
            while cleaned.count % 4 != 0 { cleaned += "=" }
            guard let data = Data(base64Encoded: cleaned) else { return "⚠️ Not valid Base64" }
            return String(data: data, encoding: .utf8) ?? "⚠️ Decoded data is not UTF-8 text (\(data.count) bytes)"
        case .urlEncode:
            var allowed = CharacterSet.alphanumerics
            allowed.insert(charactersIn: "-._~")
            return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
        case .urlDecode: return text.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? text
        case .htmlEscape:
            return text.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "'", with: "&#39;")
        case .htmlUnescape:
            return text.replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&#39;", with: "'")
                .replacingOccurrences(of: "&apos;", with: "'")
                .replacingOccurrences(of: "&nbsp;", with: " ")
                .replacingOccurrences(of: "&amp;", with: "&")
        case .rot13:
            return String(text.unicodeScalars.map { scalar -> Character in
                let v = scalar.value
                if (65...90).contains(v) { return Character(UnicodeScalar((v - 65 + 13) % 26 + 65)!) }
                if (97...122).contains(v) { return Character(UnicodeScalar((v - 97 + 13) % 26 + 97)!) }
                return Character(scalar)
            })
        case .reverseText: return String(text.reversed())
        case .unicodeEscape:
            return text.unicodeScalars.map { scalar -> String in
                if scalar.isASCII { return String(scalar) }
                return scalar.value > 0xFFFF ? String(format: "\\U%08X", scalar.value) : String(format: "\\u%04X", scalar.value)
            }.joined()
        case .slugify:
            let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).lowercased()
            return TextTransform.words(folded).joined(separator: "-")
        }
    }

    private func lines(_ text: String) -> [String] {
        text.components(separatedBy: "\n")
    }

    private func mapLines(_ text: String, _ transform: (String) -> String) -> String {
        lines(text).map(transform).joined(separator: "\n")
    }

    /// Splits text into words on spaces, punctuation and camelCase boundaries.
    static func words(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var previous: Character?
        for ch in text {
            if ch.isLetter || ch.isNumber {
                if let p = previous, ch.isUppercase, p.isLowercase || p.isNumber, !current.isEmpty {
                    result.append(current)
                    current = ""
                }
                current.append(ch)
            } else if !current.isEmpty {
                result.append(current)
                current = ""
            }
            previous = ch
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    enum JoinStyle { case camel, pascal }

    static func joinWords(_ words: [String], style: JoinStyle) -> String {
        words.enumerated().map { index, word in
            let lower = word.lowercased()
            if index == 0 && style == .camel { return lower }
            return lower.prefix(1).uppercased() + lower.dropFirst()
        }.joined()
    }

    static func titleCase(_ text: String) -> String {
        let small: Set<String> = ["a", "an", "and", "as", "at", "but", "by", "for", "in", "nor", "of", "on", "or", "the", "to", "up", "via"]
        let parts = text.components(separatedBy: " ")
        return parts.enumerated().map { index, word in
            let lower = word.lowercased()
            if index > 0 && index < parts.count - 1 && small.contains(lower) { return lower }
            return lower.prefix(1).uppercased() + lower.dropFirst()
        }.joined(separator: " ")
    }

    static func sentenceCase(_ text: String) -> String {
        var result = ""
        var capitalizeNext = true
        for ch in text.lowercased() {
            if capitalizeNext && ch.isLetter {
                result += String(ch).uppercased()
                capitalizeNext = false
            } else {
                result.append(ch)
            }
            if ch == "." || ch == "!" || ch == "?" || ch == "\n" { capitalizeNext = true }
        }
        return result
    }
}

struct TextStats {
    let characters: Int
    let charactersNoSpaces: Int
    let words: Int
    let lines: Int
    let sentences: Int
    let paragraphs: Int
    let readingMinutes: Double

    init(_ text: String) {
        characters = text.count
        charactersNoSpaces = text.filter { !$0.isWhitespace }.count
        words = text.split(whereSeparator: { $0.isWhitespace }).count
        lines = text.isEmpty ? 0 : text.components(separatedBy: "\n").count
        sentences = text.split(whereSeparator: { $0 == "." || $0 == "!" || $0 == "?" })
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
        paragraphs = text.components(separatedBy: "\n\n").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
        readingMinutes = Double(words) / 230
    }
}

enum LoremIpsum {
    static let words = """
    lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod tempor incididunt ut labore et dolore magna \
    aliqua enim ad minim veniam quis nostrud exercitation ullamco laboris nisi aliquip ex ea commodo consequat duis aute \
    irure in reprehenderit voluptate velit esse cillum fugiat nulla pariatur excepteur sint occaecat cupidatat non proident \
    sunt culpa qui officia deserunt mollit anim id est laborum
    """.split(separator: " ").map(String.init)

    static func paragraphs(_ count: Int) -> String {
        (0..<max(1, count)).map { index -> String in
            let sentences = (0..<Int.random(in: 4...7)).map { _ -> String in
                let length = Int.random(in: 6...14)
                let sentence = (0..<length).map { _ in words.randomElement() ?? "lorem" }.joined(separator: " ")
                return sentence.prefix(1).uppercased() + sentence.dropFirst() + "."
            }
            let paragraph = sentences.joined(separator: " ")
            return index == 0 ? "Lorem ipsum dolor sit amet, " + paragraph.prefix(1).lowercased() + paragraph.dropFirst() : paragraph
        }.joined(separator: "\n\n")
    }
}
