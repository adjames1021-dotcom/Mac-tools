import Foundation

// MARK: - CSV ⇄ JSON

enum CSVTools {
    /// RFC 4180-style parser (quoted fields, escaped quotes, newlines inside quotes).
    static func parse(_ text: String, delimiter: Character = ",") -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" {
                        field.append("\"")
                        i += 1
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(c)
                }
            } else if c == "\"" && field.isEmpty {
                inQuotes = true
            } else if c == delimiter {
                row.append(field)
                field = ""
            } else if c == "\n" || c == "\r\n" || c == "\r" {
                row.append(field)
                rows.append(row)
                row = []
                field = ""
            } else {
                field.append(c)
            }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }

    static func typed(_ value: String) -> Any {
        let t = value.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return NSNull() }
        if t == "true" || t == "false" { return t == "true" }
        if let i = Int(t), !(t.hasPrefix("0") && t.count > 1) { return i }
        if let d = Double(t), t.contains(".") { return d }
        return value
    }

    static func csvToJSON(_ text: String, delimiter: Character = ",", header: Bool = true, inferTypes: Bool = true) throws -> String {
        let rows = parse(text, delimiter: delimiter).filter { !($0.count == 1 && $0[0].isEmpty) }
        guard !rows.isEmpty else { return "[]" }
        var objects: [Any] = []
        if header {
            let keys = rows[0].enumerated().map { $0.element.isEmpty ? "column\($0.offset + 1)" : $0.element }
            for row in rows.dropFirst() {
                var object: [String: Any] = [:]
                for (index, key) in keys.enumerated() {
                    let value = index < row.count ? row[index] : ""
                    object[key] = inferTypes ? typed(value) : value
                }
                objects.append(object)
            }
        } else {
            for row in rows {
                objects.append(row.map { inferTypes ? typed($0) : $0 })
            }
        }
        let data = try JSONSerialization.data(withJSONObject: objects, options: [.prettyPrinted, .sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    static func escape(_ field: String, delimiter: Character) -> String {
        if field.contains(delimiter) || field.contains("\"") || field.contains("\n") || field.contains("\r") {
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return field
    }

    static func stringValue(_ value: Any) -> String {
        if value is NSNull { return "" }
        if let s = value as? String { return s }
        if let n = value as? NSNumber {
            #if canImport(Darwin)
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            #endif
            return n.stringValue
        }
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
            return String(decoding: data, as: UTF8.self)
        }
        return "\(value)"
    }

    enum ConversionError: Error, LocalizedError {
        case notArray
        var errorDescription: String? { "JSON must be an array of objects (or an array of arrays)." }
    }

    static func jsonToCSV(_ text: String, delimiter: Character = ",") throws -> String {
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
        guard let array = object as? [Any] else { throw ConversionError.notArray }
        let sep = String(delimiter)
        if let dicts = array as? [[String: Any]] {
            var keys: [String] = []
            var seen = Set<String>()
            for dict in dicts {
                for key in dict.keys.sorted() where !seen.contains(key) {
                    seen.insert(key)
                    keys.append(key)
                }
            }
            var lines = [keys.map { escape($0, delimiter: delimiter) }.joined(separator: sep)]
            for dict in dicts {
                lines.append(keys.map { escape(stringValue(dict[$0] ?? NSNull()), delimiter: delimiter) }.joined(separator: sep))
            }
            return lines.joined(separator: "\n")
        }
        if let rows = array as? [[Any]] {
            return rows.map { $0.map { escape(stringValue($0), delimiter: delimiter) }.joined(separator: sep) }.joined(separator: "\n")
        }
        throw ConversionError.notArray
    }
}

// MARK: - JWT

struct DecodedJWT {
    let header: String
    let payload: String
    let signature: String
    let claims: [String: Any]
    let signingInput: String

    let headerAlgorithm: String

    static func base64URLDecode(_ text: String) -> Data? {
        var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        return Data(base64Encoded: s)
    }

    static func pretty(_ data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data),
           let out = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
            return String(decoding: out, as: UTF8.self)
        }
        return String(decoding: data, as: UTF8.self)
    }

    enum JWTError: Error, LocalizedError {
        case format, base64
        var errorDescription: String? {
            switch self {
            case .format: return "A JWT has three parts separated by dots (header.payload.signature)."
            case .base64: return "The token isn't valid Base64URL."
            }
        }
    }

    init(_ token: String) throws {
        let parts = token.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "Bearer ", with: "")
            .split(separator: ".", omittingEmptySubsequences: false)
            .map(String.init)
        guard parts.count == 3 else { throw JWTError.format }
        guard let headerData = DecodedJWT.base64URLDecode(parts[0]),
              let payloadData = DecodedJWT.base64URLDecode(parts[1]) else { throw JWTError.base64 }
        header = DecodedJWT.pretty(headerData)
        payload = DecodedJWT.pretty(payloadData)
        signature = parts[2]
        signingInput = parts[0] + "." + parts[1]
        claims = (try? JSONSerialization.jsonObject(with: payloadData)) as? [String: Any] ?? [:]
        let headerObject = (try? JSONSerialization.jsonObject(with: headerData)) as? [String: Any] ?? [:]
        headerAlgorithm = headerObject["alg"] as? String ?? "?"
    }

    func date(_ claim: String) -> Date? {
        if let n = claims[claim] as? NSNumber { return Date(timeIntervalSince1970: n.doubleValue) }
        return nil
    }

    var isExpired: Bool? {
        guard let exp = date("exp") else { return nil }
        return exp < Date()
    }
}

// MARK: - Cron

struct CronExpression {
    let minutes: Set<Int>
    let hours: Set<Int>
    let days: Set<Int>
    let months: Set<Int>
    let weekdays: Set<Int>
    let dayRestricted: Bool
    let weekdayRestricted: Bool
    let fields: [String]

    enum CronError: Error, LocalizedError {
        case fieldCount, invalid(String)
        var errorDescription: String? {
            switch self {
            case .fieldCount: return "Cron needs 5 fields: minute hour day-of-month month day-of-week"
            case .invalid(let f): return "Can't understand “\(f)”"
            }
        }
    }

    static let monthNames = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"]
    static let dayNames = ["SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"]

    init(_ text: String) throws {
        var expr = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let macros = ["@yearly": "0 0 1 1 *", "@annually": "0 0 1 1 *", "@monthly": "0 0 1 * *",
                      "@weekly": "0 0 * * 0", "@daily": "0 0 * * *", "@midnight": "0 0 * * *", "@hourly": "0 * * * *"]
        if let m = macros[expr.lowercased()] { expr = m }
        let parts = expr.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard parts.count == 5 else { throw CronError.fieldCount }
        fields = parts
        minutes = try CronExpression.field(parts[0], 0, 59, names: [])
        hours = try CronExpression.field(parts[1], 0, 23, names: [])
        days = try CronExpression.field(parts[2], 1, 31, names: [])
        months = try CronExpression.field(parts[3], 1, 12, names: CronExpression.monthNames, nameOffset: 1)
        var wd = try CronExpression.field(parts[4], 0, 7, names: CronExpression.dayNames, nameOffset: 0)
        if wd.contains(7) {
            wd.remove(7)
            wd.insert(0)
        }
        weekdays = wd
        dayRestricted = parts[2] != "*" && parts[2] != "?"
        weekdayRestricted = parts[4] != "*" && parts[4] != "?"
    }

    private static func value(_ s: String, names: [String], nameOffset: Int) -> Int? {
        if let n = Int(s) { return n }
        if let i = names.firstIndex(of: s.uppercased()) { return i + nameOffset }
        return nil
    }

    static func field(_ text: String, _ lo: Int, _ hi: Int, names: [String], nameOffset: Int = 0) throws -> Set<Int> {
        var result = Set<Int>()
        for part in text.split(separator: ",").map(String.init) {
            var rangePart = part
            var step = 1
            if let slash = part.firstIndex(of: "/") {
                rangePart = String(part[..<slash])
                guard let s = Int(part[part.index(after: slash)...]), s > 0 else { throw CronError.invalid(part) }
                step = s
            }
            var start = lo
            var end = hi
            if rangePart == "*" || rangePart == "?" {
                // full range
            } else if let dash = rangePart.firstIndex(of: "-") {
                guard let a = value(String(rangePart[..<dash]), names: names, nameOffset: nameOffset),
                      let b = value(String(rangePart[rangePart.index(after: dash)...]), names: names, nameOffset: nameOffset) else {
                    throw CronError.invalid(part)
                }
                start = a
                end = b
            } else {
                guard let v = value(rangePart, names: names, nameOffset: nameOffset) else { throw CronError.invalid(part) }
                start = v
                end = part.contains("/") ? hi : v
            }
            guard start >= lo, end <= hi, start <= end else { throw CronError.invalid(part) }
            var v = start
            while v <= end {
                result.insert(v)
                v += step
            }
        }
        return result
    }

    func matches(_ date: Date, calendar: Calendar = .current) -> Bool {
        let c = calendar.dateComponents([.minute, .hour, .day, .month, .weekday], from: date)
        guard let minute = c.minute, let hour = c.hour, let day = c.day, let month = c.month, let weekday = c.weekday else { return false }
        guard minutes.contains(minute), hours.contains(hour), months.contains(month) else { return false }
        let dayOK = days.contains(day)
        let weekdayOK = weekdays.contains(weekday - 1)
        if dayRestricted && weekdayRestricted { return dayOK || weekdayOK }
        return dayOK && weekdayOK
    }

    func nextRuns(after start: Date, count: Int, calendar: Calendar = .current) -> [Date] {
        var results: [Date] = []
        guard var date = calendar.date(bySetting: .second, value: 0, of: start.addingTimeInterval(60)) else { return [] }
        if date <= start { date = date.addingTimeInterval(60) }
        var iterations = 0
        while results.count < count && iterations < 600_000 {
            iterations += 1
            let c = calendar.dateComponents([.minute, .hour, .month], from: date)
            if let month = c.month, !months.contains(month) {
                let startOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
                date = calendar.date(byAdding: .month, value: 1, to: startOfMonth) ?? date.addingTimeInterval(86_400)
                continue
            }
            if let hour = c.hour, !hours.contains(hour) {
                let startOfHour = calendar.date(from: calendar.dateComponents([.year, .month, .day, .hour], from: date)) ?? date
                date = startOfHour.addingTimeInterval(3600)
                continue
            }
            if matches(date, calendar: calendar) {
                results.append(date)
            }
            date = date.addingTimeInterval(60)
        }
        return results
    }

    var description: String {
        func list(_ set: Set<Int>, _ format: (Int) -> String) -> String {
            set.sorted().map(format).joined(separator: ", ")
        }
        var parts: [String] = []
        let f = fields
        if f[0] == "*" && f[1] == "*" {
            parts.append("Every minute")
        } else if f[0].hasPrefix("*/") && f[1] == "*" {
            parts.append("Every \(f[0].dropFirst(2)) minutes")
        } else if minutes.count == 1 && hours.count == 1, let m = minutes.first, let h = hours.first {
            parts.append(String(format: "At %02d:%02d", h, m))
        } else if f[1] == "*" {
            parts.append("At minute \(list(minutes) { "\($0)" }) of every hour")
        } else if minutes.count == 1, let m = minutes.first {
            parts.append("At " + hours.sorted().map { String(format: "%02d:%02d", $0, m) }.joined(separator: ", "))
        } else {
            parts.append("At minute \(list(minutes) { "\($0)" }) past hour \(list(hours) { "\($0)" })")
        }
        if dayRestricted {
            parts.append("on day \(list(days) { "\($0)" }) of the month")
        }
        if weekdayRestricted {
            let names = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
            parts.append((dayRestricted ? "or on " : "on ") + list(weekdays) { names[$0] })
        }
        if f[3] != "*" {
            let names = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
            parts.append("in " + list(months) { names[$0 - 1] })
        }
        return parts.joined(separator: " ")
    }
}

// MARK: - Markdown → HTML

enum MarkdownRenderer {
    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func inline(_ text: String) -> String {
        var s = escape(text)
        let rules: [(String, String)] = [
            ("!\\[([^\\]]*)\\]\\(([^)\\s]+)\\)", "<img alt=\"$1\" src=\"$2\">"),
            ("\\[([^\\]]+)\\]\\(([^)\\s]+)\\)", "<a href=\"$2\">$1</a>"),
            ("`([^`]+)`", "<code>$1</code>"),
            ("\\*\\*([^*]+)\\*\\*", "<strong>$1</strong>"),
            ("__([^_]+)__", "<strong>$1</strong>"),
            ("\\*([^*]+)\\*", "<em>$1</em>"),
            ("(?<![\\w])_([^_]+)_(?![\\w])", "<em>$1</em>"),
            ("~~([^~]+)~~", "<del>$1</del>")
        ]
        for (pattern, template) in rules {
            if let re = try? NSRegularExpression(pattern: pattern) {
                s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..<s.endIndex, in: s), withTemplate: template)
            }
        }
        return s
    }

    static func html(_ markdown: String) -> String {
        var out: [String] = []
        var paragraph: [String] = []
        var listType: String?
        var inCode = false
        var codeLines: [String] = []
        var codeLanguage = ""

        func flushParagraph() {
            if !paragraph.isEmpty {
                out.append("<p>" + paragraph.map(inline).joined(separator: "<br>\n") + "</p>")
                paragraph = []
            }
        }
        func closeList() {
            if let type = listType {
                out.append("</\(type)>")
                listType = nil
            }
        }

        for rawLine in markdown.components(separatedBy: "\n") {
            let line = rawLine.replacingOccurrences(of: "\r", with: "")
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if inCode {
                    let cls = codeLanguage.isEmpty ? "" : " class=\"language-\(escape(codeLanguage))\""
                    out.append("<pre><code\(cls)>" + codeLines.map(escape).joined(separator: "\n") + "</code></pre>")
                    codeLines = []
                    inCode = false
                } else {
                    flushParagraph()
                    closeList()
                    codeLanguage = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    inCode = true
                }
                continue
            }
            if inCode {
                codeLines.append(line)
                continue
            }
            if trimmed.isEmpty {
                flushParagraph()
                closeList()
                continue
            }
            if trimmed.hasPrefix("#") {
                let level = trimmed.prefix(while: { $0 == "#" }).count
                if level <= 6, trimmed.dropFirst(level).hasPrefix(" ") {
                    flushParagraph()
                    closeList()
                    out.append("<h\(level)>" + inline(String(trimmed.dropFirst(level + 1))) + "</h\(level)>")
                    continue
                }
            }
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushParagraph()
                closeList()
                out.append("<hr>")
                continue
            }
            if trimmed.hasPrefix(">") {
                flushParagraph()
                closeList()
                out.append("<blockquote>" + inline(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)) + "</blockquote>")
                continue
            }
            let unordered = trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ")
            var orderedText: String?
            if let dot = trimmed.firstIndex(of: "."), Int(trimmed[..<dot]) != nil, trimmed[trimmed.index(after: dot)...].hasPrefix(" ") {
                orderedText = String(trimmed[trimmed.index(dot, offsetBy: 2)...])
            }
            if unordered || orderedText != nil {
                flushParagraph()
                let type = unordered ? "ul" : "ol"
                if listType != type {
                    closeList()
                    out.append("<\(type)>")
                    listType = type
                }
                var item = unordered ? String(trimmed.dropFirst(2)) : (orderedText ?? "")
                if item.hasPrefix("[ ] ") {
                    item = "<input type=\"checkbox\" disabled> " + inline(String(item.dropFirst(4)))
                } else if item.lowercased().hasPrefix("[x] ") {
                    item = "<input type=\"checkbox\" checked disabled> " + inline(String(item.dropFirst(4)))
                } else {
                    item = inline(item)
                }
                out.append("<li>\(item)</li>")
                continue
            }
            closeList()
            paragraph.append(trimmed)
        }
        if inCode {
            out.append("<pre><code>" + codeLines.map(escape).joined(separator: "\n") + "</code></pre>")
        }
        flushParagraph()
        closeList()
        return out.joined(separator: "\n")
    }

    static func document(_ markdown: String, title: String = "Document") -> String {
        """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"><title>\(escape(title))</title>
        <style>
        :root { color-scheme: light dark; }
        body { font: 15px/1.6 -apple-system, BlinkMacSystemFont, sans-serif; max-width: 760px; margin: 24px auto; padding: 0 20px; }
        code { font: 13px ui-monospace, Menlo, monospace; background: rgba(127,127,127,.15); padding: 2px 4px; border-radius: 4px; }
        pre { background: rgba(127,127,127,.12); padding: 12px; border-radius: 8px; overflow-x: auto; }
        pre code { background: none; padding: 0; }
        blockquote { border-left: 4px solid rgba(127,127,127,.4); margin: 0; padding-left: 12px; color: gray; }
        img { max-width: 100%; }
        h1, h2 { border-bottom: 1px solid rgba(127,127,127,.25); padding-bottom: 4px; }
        </style></head><body>
        \(html(markdown))
        </body></html>
        """
    }
}

// MARK: - Hex dump

enum HexDump {
    static func format(_ data: Data, offset: Int = 0, bytesPerLine: Int = 16) -> String {
        var lines: [String] = []
        let bytes = [UInt8](data)
        var index = 0
        while index < bytes.count {
            let chunk = bytes[index..<min(index + bytesPerLine, bytes.count)]
            var hex = ""
            for (i, b) in chunk.enumerated() {
                hex += String(format: "%02x ", b)
                if i == 7 { hex += " " }
            }
            let padding = String(repeating: " ", count: max(0, bytesPerLine * 3 + 1 - hex.count))
            let ascii = String(chunk.map { (32...126).contains($0) ? Character(UnicodeScalar($0)) : "." })
            lines.append(String(format: "%08x  ", offset + index) + hex + padding + " |" + ascii + "|")
            index += bytesPerLine
        }
        return lines.joined(separator: "\n")
    }

    static func fileType(_ data: Data) -> String {
        let b = [UInt8](data.prefix(16))
        func starts(_ sig: [UInt8]) -> Bool { b.count >= sig.count && Array(b[0..<sig.count]) == sig }
        if starts([0x89, 0x50, 0x4E, 0x47]) { return "PNG image" }
        if starts([0xFF, 0xD8, 0xFF]) { return "JPEG image" }
        if starts([0x47, 0x49, 0x46, 0x38]) { return "GIF image" }
        if starts([0x25, 0x50, 0x44, 0x46]) { return "PDF document" }
        if starts([0x50, 0x4B, 0x03, 0x04]) { return "ZIP archive (also .docx, .xlsx, .jar, .ipa…)" }
        if starts([0x1F, 0x8B]) { return "gzip archive" }
        if starts([0x42, 0x5A, 0x68]) { return "bzip2 archive" }
        if starts([0xFD, 0x37, 0x7A, 0x58, 0x5A]) { return "xz archive" }
        if starts([0x37, 0x7A, 0xBC, 0xAF]) { return "7-Zip archive" }
        if starts([0x52, 0x61, 0x72, 0x21]) { return "RAR archive" }
        if starts([0xCF, 0xFA, 0xED, 0xFE]) { return "Mach-O 64-bit executable" }
        if starts([0xCA, 0xFE, 0xBA, 0xBE]) { return "Mach-O universal binary (or Java class)" }
        if starts([0x7F, 0x45, 0x4C, 0x46]) { return "ELF executable" }
        if starts([0x4D, 0x5A]) { return "Windows executable" }
        if starts([0x62, 0x70, 0x6C, 0x69, 0x73, 0x74]) { return "Binary property list" }
        if starts([0x53, 0x51, 0x4C, 0x69, 0x74, 0x65]) { return "SQLite database" }
        if b.count >= 12 && Array(b[4..<8]) == [0x66, 0x74, 0x79, 0x70] { return "MP4 / MOV / HEIC media" }
        if starts([0x49, 0x44, 0x33]) { return "MP3 audio" }
        if starts([0x52, 0x49, 0x46, 0x46]) { return "RIFF (WAV / AVI / WebP)" }
        if starts([0x7B]) || starts([0x5B]) { return "Probably JSON or text" }
        if starts([0x3C]) { return "Probably XML / HTML / plist" }
        if !b.isEmpty && b.allSatisfy({ $0 == 9 || $0 == 10 || $0 == 13 || (32...126).contains($0) }) { return "Plain text" }
        return "Unknown binary"
    }
}

// MARK: - .gitignore templates

enum GitignoreTemplates {
    static let all: [(String, String)] = [
        ("macOS", ".DS_Store\n.AppleDouble\n.LSOverride\n._*\n.Spotlight-V100\n.Trashes\n"),
        ("Windows", "Thumbs.db\nehthumbs.db\nDesktop.ini\n$RECYCLE.BIN/\n*.lnk\n"),
        ("Linux", "*~\n.fuse_hidden*\n.directory\n.Trash-*\n.nfs*\n"),
        ("Swift / Xcode", "build/\nDerivedData/\n*.xcuserstate\nxcuserdata/\n*.xcscmblueprint\n.swiftpm/\n.build/\nPackages/\nPods/\nCarthage/Build/\nfastlane/report.xml\nfastlane/screenshots\n*.ipa\n*.dSYM.zip\n*.dSYM\n"),
        ("Node", "node_modules/\nnpm-debug.log*\nyarn-debug.log*\nyarn-error.log*\npnpm-debug.log*\n.npm\n.eslintcache\ndist/\nbuild/\n.next/\n.nuxt/\ncoverage/\n.env\n.env.local\n.env.*.local\n"),
        ("Python", "__pycache__/\n*.py[cod]\n*.so\n.Python\nbuild/\ndist/\n*.egg-info/\n.eggs/\n.venv/\nvenv/\nenv/\n.pytest_cache/\n.mypy_cache/\n.ipynb_checkpoints\n.env\n"),
        ("Java / Kotlin", "*.class\n*.jar\n*.war\n*.ear\ntarget/\nbuild/\n.gradle/\nout/\n*.log\nhs_err_pid*\n"),
        ("Android", "*.apk\n*.aab\n.gradle/\nbuild/\nlocal.properties\ncaptures/\n.externalNativeBuild\n.cxx/\n*.keystore\n"),
        ("Go", "*.exe\n*.exe~\n*.dll\n*.so\n*.dylib\n*.test\n*.out\nvendor/\ngo.work\n"),
        ("Rust", "target/\nCargo.lock\n**/*.rs.bk\n*.pdb\n"),
        ("C / C++", "*.o\n*.obj\n*.a\n*.lib\n*.so\n*.dylib\n*.dll\n*.exe\n*.out\nbuild/\ncmake-build-*/\nCMakeCache.txt\nCMakeFiles/\n"),
        ("Ruby", "*.gem\n.bundle/\nvendor/bundle\nlog/\ntmp/\ncoverage/\n.byebug_history\n"),
        ("Flutter / Dart", ".dart_tool/\n.packages\nbuild/\n.flutter-plugins\n.flutter-plugins-dependencies\n.pub-cache/\n"),
        ("Unity", "/[Ll]ibrary/\n/[Tt]emp/\n/[Oo]bj/\n/[Bb]uild/\n/[Bb]uilds/\n/[Ll]ogs/\n/[Uu]ser[Ss]ettings/\n*.csproj\n*.sln\n*.pidb\n*.userprefs\n"),
        ("VS Code", ".vscode/*\n!.vscode/settings.json\n!.vscode/tasks.json\n!.vscode/launch.json\n!.vscode/extensions.json\n*.code-workspace\n"),
        ("JetBrains", ".idea/\n*.iml\n*.iws\nout/\n"),
        ("Secrets", ".env\n.env.*\n*.pem\n*.key\n*.p12\nsecrets.json\ncredentials.json\n")
    ]

    static func combined(_ names: [String]) -> String {
        all.filter { names.contains($0.0) }
            .map { "# ---- \($0.0) ----\n" + $0.1 }
            .joined(separator: "\n")
    }
}
