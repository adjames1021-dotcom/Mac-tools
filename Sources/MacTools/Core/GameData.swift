import SwiftUI
import AppKit

// MARK: - LZString

/// LZString, the compression many HTML games use for saves (RPG Maker MV's `.rpgsave` and browser saves,
/// SugarCube/Twine, and lots of others). It works on UTF-16 code units exactly like the JavaScript library,
/// so what MacTools writes back is what the game expects.
enum LZString {
    private static let base64Keys = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=".utf16)
    private static let uriKeys = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+-$".utf16)
    private static let base64Index: [UInt16: Int] = Dictionary(uniqueKeysWithValues: base64Keys.enumerated().map { ($1, $0) })
    private static let uriIndex: [UInt16: Int] = Dictionary(uniqueKeysWithValues: uriKeys.enumerated().map { ($1, $0) })

    static func compressToBase64(_ input: String) -> String {
        var out = compress(Array(input.utf16), bitsPerChar: 6) { base64Keys[$0] }
        switch out.count % 4 {
        case 1: out += Array("===".utf16)
        case 2: out += Array("==".utf16)
        case 3: out += Array("=".utf16)
        default: break
        }
        return String(decoding: out, as: UTF16.self)
    }

    static func decompressFromBase64(_ input: String) -> String? {
        let units = Array(input.utf16)
        guard !units.isEmpty else { return nil }
        return decompress(length: units.count, resetValue: 32) { $0 < units.count ? base64Index[units[$0]] ?? 0 : 0 }
    }

    static func compressToUTF16(_ input: String) -> String {
        String(decoding: compress(Array(input.utf16), bitsPerChar: 15) { UInt16($0 + 32) } + [32], as: UTF16.self)
    }

    static func decompressFromUTF16(_ input: String) -> String? {
        let units = Array(input.utf16)
        guard !units.isEmpty else { return nil }
        return decompress(length: units.count, resetValue: 16384) { $0 < units.count ? Int(units[$0]) - 32 : 0 }
    }

    static func compressToEncodedURIComponent(_ input: String) -> String {
        String(decoding: compress(Array(input.utf16), bitsPerChar: 6) { uriKeys[$0] }, as: UTF16.self)
    }

    static func decompressFromEncodedURIComponent(_ input: String) -> String? {
        let units = Array(input.replacingOccurrences(of: " ", with: "+").utf16)
        guard !units.isEmpty else { return nil }
        return decompress(length: units.count, resetValue: 32) { $0 < units.count ? uriIndex[units[$0]] ?? 0 : 0 }
    }

    /// LZW-style compression into `bitsPerChar`-bit output symbols. The dictionary is a trie, so each input unit
    /// costs one lookup.
    private static func compress(_ input: [UInt16], bitsPerChar: Int, _ symbol: (Int) -> UInt16) -> [UInt16] {
        var codeOf: [Int] = []
        var children: [[UInt16: Int]] = []
        var singleNode: [UInt16: Int] = [:]
        var toCreate = Set<UInt16>()
        var wNode = -1, wLength = 0, wFirst: UInt16 = 0
        var enlargeIn = 2, dictSize = 3, numBits = 2
        var out: [UInt16] = []
        var value = 0, position = 0

        func newNode() -> Int {
            codeOf.append(dictSize)
            children.append([:])
            dictSize += 1
            return codeOf.count - 1
        }
        func writeBits(_ bits: Int, _ count: Int) {
            var v = bits
            for _ in 0..<count {
                value = (value << 1) | (v & 1)
                if position == bitsPerChar - 1 {
                    position = 0
                    out.append(symbol(value))
                    value = 0
                } else {
                    position += 1
                }
                v >>= 1
            }
        }
        func grow() {
            enlargeIn -= 1
            if enlargeIn == 0 {
                enlargeIn = 1 << numBits
                numBits += 1
            }
        }
        func emitW() {
            if wLength == 1 && toCreate.contains(wFirst) {
                if wFirst < 256 {
                    writeBits(0, numBits)
                    writeBits(Int(wFirst), 8)
                } else {
                    writeBits(1, numBits)
                    writeBits(Int(wFirst), 16)
                }
                grow()
                toCreate.remove(wFirst)
            } else {
                writeBits(codeOf[wNode], numBits)
            }
            grow()
        }

        for c in input {
            if singleNode[c] == nil {
                singleNode[c] = newNode()
                toCreate.insert(c)
            }
            if wNode == -1 {
                wNode = singleNode[c]!
                wLength = 1
                wFirst = c
                continue
            }
            if let child = children[wNode][c] {
                wNode = child
                wLength += 1
            } else {
                emitW()
                children[wNode][c] = newNode()
                wNode = singleNode[c]!
                wLength = 1
                wFirst = c
            }
        }
        if wNode != -1 { emitW() }
        writeBits(2, numBits)   // end of stream
        while true {
            value <<= 1
            if position == bitsPerChar - 1 {
                out.append(symbol(value))
                break
            }
            position += 1
        }
        return out
    }

    /// Returns nil when the input isn't LZString data.
    private static func decompress(length: Int, resetValue: Int, _ next: (Int) -> Int) -> String? {
        var dictionary: [[UInt16]] = [[0], [1], [2]]
        var enlargeIn = 4, numBits = 3
        var result: [UInt16] = []
        var dataValue = next(0), dataPosition = resetValue, dataIndex = 1

        func readBits(_ count: Int) -> Int {
            var bits = 0, power = 1
            let maxPower = 1 << count
            while power != maxPower {
                let bit = dataValue & dataPosition
                dataPosition >>= 1
                if dataPosition == 0 {
                    dataPosition = resetValue
                    dataValue = next(dataIndex)
                    dataIndex += 1
                }
                if bit > 0 { bits |= power }
                power <<= 1
            }
            return bits
        }

        var first: [UInt16]
        switch readBits(2) {
        case 0: first = [UInt16(readBits(8))]
        case 1: first = [UInt16(readBits(16))]
        case 2: return ""
        default: return nil
        }
        dictionary.append(first)
        var w = first
        result += first
        while true {
            if dataIndex > length { return nil }   // ran out of input without an end marker
            var code = readBits(numBits)
            switch code {
            case 0:
                dictionary.append([UInt16(readBits(8))])
                code = dictionary.count - 1
                enlargeIn -= 1
            case 1:
                dictionary.append([UInt16(readBits(16))])
                code = dictionary.count - 1
                enlargeIn -= 1
            case 2:
                return String(decoding: result, as: UTF16.self)
            default:
                break
            }
            if enlargeIn == 0 {
                enlargeIn = 1 << numBits
                numBits += 1
            }
            let entry: [UInt16]
            if code >= 3 && code < dictionary.count {
                entry = dictionary[code]
            } else if code == dictionary.count {
                entry = w + [w[0]]
            } else {
                return nil
            }
            result += entry
            dictionary.append(w + [entry[0]])
            enlargeIn -= 1
            w = entry
            if enlargeIn == 0 {
                enlargeIn = 1 << numBits
                numBits += 1
            }
            if result.count > 200_000_000 { return nil }   // runaway garbage input
        }
    }
}

// MARK: - Save formats

/// How a game packed its save: plain JSON, or JSON compressed/encoded in one of the usual ways.
enum GameDataFormat: String, CaseIterable, Identifiable {
    case json = "JSON"
    case lzBase64 = "LZString · Base64"
    case lzUTF16 = "LZString · UTF-16"
    case lzURI = "LZString · URI"
    case base64 = "Base64"
    case uri = "URL-encoded"

    var id: String { rawValue }
}

struct DecodedGameData {
    let format: GameDataFormat
    let json: Any
    /// The JSON text as it was unpacked (indented if the game wrote it indented).
    let text: String
    var pretty: Bool { text.contains("\n") }
}

enum GameDataCodec {
    private static let base64Chars = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")
    private static let uriChars = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+-$ ")

    /// JSON objects/arrays only – a bare number or word isn't a save worth unpacking.
    static func parse(_ text: String) -> Any? {
        guard let first = text.first(where: { !$0.isWhitespace }), first == "{" || first == "[" else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(text.utf8))
    }

    /// Works out how a save is packed and unpacks it, or nil if it isn't JSON in any of the known forms.
    static func decode(_ raw: String) -> DecodedGameData? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let json = parse(text) { return DecodedGameData(format: .json, json: json, text: text) }
        let scalars = text.unicodeScalars
        let looksBase64 = scalars.allSatisfy { base64Chars.contains($0) }
        // The Base64 flavour is always padded to a multiple of 4; anything else is the URI flavour.
        if looksBase64, text.count % 4 == 0, let unpacked = LZString.decompressFromBase64(text), let json = parse(unpacked) {
            return DecodedGameData(format: .lzBase64, json: json, text: unpacked)
        }
        if scalars.allSatisfy({ uriChars.contains($0) }),
           let unpacked = LZString.decompressFromEncodedURIComponent(text), let json = parse(unpacked) {
            return DecodedGameData(format: .lzURI, json: json, text: unpacked)
        }
        if scalars.contains(where: { $0.value > 0x7F }),
           let unpacked = LZString.decompressFromUTF16(raw), let json = parse(unpacked) {
            return DecodedGameData(format: .lzUTF16, json: json, text: unpacked)
        }
        if looksBase64 {
            let padded = text + String(repeating: "=", count: (4 - text.count % 4) % 4)
            if let data = Data(base64Encoded: padded), let unpacked = String(data: data, encoding: .utf8), let json = parse(unpacked) {
                return DecodedGameData(format: .base64, json: json, text: unpacked)
            }
        }
        if text.contains("%"), let unpacked = text.removingPercentEncoding, let json = parse(unpacked) {
            return DecodedGameData(format: .uri, json: json, text: unpacked)
        }
        return nil
    }

    static func jsonText(_ json: Any, pretty: Bool) -> String? {
        var options: JSONSerialization.WritingOptions = [.withoutEscapingSlashes]
        if pretty { options.insert(.prettyPrinted) }
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: options) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Packs edited JSON back the way the game packed it.
    static func encode(_ json: Any, as format: GameDataFormat, pretty: Bool = false) -> String? {
        guard let text = jsonText(json, pretty: pretty && format == .json) else { return nil }
        switch format {
        case .json: return text
        case .lzBase64: return LZString.compressToBase64(text)
        case .lzUTF16: return LZString.compressToUTF16(text)
        case .lzURI: return LZString.compressToEncodedURIComponent(text)
        case .base64: return Data(text.utf8).base64EncodedString()
        case .uri:
            var allowed = CharacterSet.alphanumerics
            allowed.insert(charactersIn: "-_.!~*'()")   // what JavaScript's encodeURIComponent leaves alone
            return text.addingPercentEncoding(withAllowedCharacters: allowed)
        }
    }
}

// MARK: - Text saves

/// A save that's text rather than JSON, packed as Base64 – optionally URL-escaped and ending in a marker such as
/// "!END!" (the style Cookie Clicker and other incremental games use, with fields split by "|" and ";").
struct PackedText {
    enum Packing: String {
        case base64 = "Base64 text"
        case escapedBase64 = "Escaped Base64 text"
    }
    let packing: Packing
    let text: String
    let suffix: String
}

/// A number found inside a text save.
struct TextNumber: Identifiable, Hashable {
    let range: Range<String.Index>
    let text: String
    let context: String
    /// Where it sits when the save is split by "|" and ";" (e.g. "section 4 · item 1"), if it is.
    let place: String
    var id: Int
}

enum TextSave {
    private static let base64Chars = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")
    /// What JavaScript's escape() leaves alone.
    private static let escapeSafe = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789@*_+-./")

    static func unpack(_ raw: String) -> PackedText? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var escaped = false
        if text.contains("%"), let plain = text.removingPercentEncoding, plain != text {
            text = plain
            escaped = true
        }
        var suffix = ""
        for marker in ["!END!", "!end!"] where text.hasSuffix(marker) {
            suffix = marker
            text.removeLast(marker.count)
        }
        guard text.count >= 8, text.unicodeScalars.allSatisfy({ base64Chars.contains($0) }) else { return nil }
        let padded = text + String(repeating: "=", count: (4 - text.count % 4) % 4)
        guard let data = Data(base64Encoded: padded), let decoded = String(data: data, encoding: .utf8) else { return nil }
        // Only real text: almost every character printable, no control characters other than line breaks/tabs.
        let scalars = decoded.unicodeScalars
        let printable = scalars.filter { $0.value >= 32 || $0 == "\n" || $0 == "\r" || $0 == "\t" }.count
        guard !scalars.isEmpty, Double(printable) / Double(scalars.count) > 0.97 else { return nil }
        return PackedText(packing: escaped ? .escapedBase64 : .base64, text: decoded, suffix: suffix)
    }

    static func pack(_ text: String, like original: PackedText) -> String {
        let packed = Data(text.utf8).base64EncodedString() + original.suffix
        guard original.packing == .escapedBase64 else { return packed }
        var out = ""
        for scalar in packed.unicodeScalars {
            if escapeSafe.contains(scalar) { out.unicodeScalars.append(scalar) }
            else { out += String(format: "%%%02X", scalar.value) }
        }
        return out
    }

    /// Numbers in the text equal to `query` – or, with `close`, within 1% of it (games often show rounded numbers).
    static func numbers(in text: String, matching query: String, close: Bool) -> [TextNumber] {
        let wanted = query.trimmingCharacters(in: .whitespaces)
        guard let target = Double(wanted),
              let regex = try? NSRegularExpression(pattern: #"-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?"#) else { return [] }
        let structured = text.contains("|")
        var out: [TextNumber] = []
        let whole = NSRange(text.startIndex..., in: text)
        for match in regex.matches(in: text, range: whole) {
            guard let range = Range(match.range, in: text) else { continue }
            let found = String(text[range])
            guard let value = Double(found) else { continue }
            let hit = found == wanted || value == target
                || (close && (value.rounded(.down) == target.rounded(.down) || abs(value - target) <= max(1, abs(target) * 0.01)))
            guard hit else { continue }
            let before = text[text.index(range.lowerBound, offsetBy: -min(24, text.distance(from: text.startIndex, to: range.lowerBound)))..<range.lowerBound]
            let after = text[range.upperBound..<text.index(range.upperBound, offsetBy: min(24, text.distance(from: range.upperBound, to: text.endIndex)))]
            var place = ""
            if structured {
                let prefix = text[..<range.lowerBound]
                let section = prefix.filter { $0 == "|" }.count
                let item = (prefix.split(separator: "|", omittingEmptySubsequences: false).last ?? "").filter { $0 == ";" }.count
                place = "section \(section) · item \(item)"
            }
            out.append(TextNumber(range: range, text: found, context: "…\(before)⟦\(found)⟧\(after)…", place: place,
                                  id: text.distance(from: text.startIndex, to: range.lowerBound)))
            if out.count >= 300 { break }
        }
        return out
    }
}

// MARK: - JSON values

enum JSONPathPart: Hashable {
    case key(String)
    case index(Int)
}

/// One editable value inside a save ("party.gold = 1000").
struct JSONLeaf: Identifiable, Hashable {
    enum Kind { case string, number, bool, null }
    let path: [JSONPathPart]
    let text: String
    let kind: Kind
    var id: String { JSONTree.describe(path) }
}

enum JSONTree {
    static func describe(_ path: [JSONPathPart]) -> String {
        var out = ""
        for part in path {
            switch part {
            case .key(let key):
                let plain = !key.isEmpty && key.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "$" || $0 == "@" }
                out += plain ? (out.isEmpty ? key : "." + key) : "[\"\(key)\"]"
            case .index(let index):
                out += "[\(index)]"
            }
        }
        return out.isEmpty ? "(top)" : out
    }

    static func isBool(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    /// Every string/number/true-false/null inside, in document order (sorted keys within objects).
    static func leaves(_ root: Any, limit: Int = 50_000) -> [JSONLeaf] {
        var out: [JSONLeaf] = []
        func walk(_ node: Any, _ path: [JSONPathPart]) {
            guard out.count < limit else { return }
            if let dict = node as? [String: Any] {
                for key in dict.keys.sorted() { walk(dict[key]!, path + [.key(key)]) }
            } else if let array = node as? [Any] {
                for (index, child) in array.enumerated() { walk(child, path + [.index(index)]) }
            } else if let string = node as? String {
                out.append(JSONLeaf(path: path, text: string, kind: .string))
            } else if let number = node as? NSNumber {
                if isBool(number) {
                    out.append(JSONLeaf(path: path, text: number.boolValue ? "true" : "false", kind: .bool))
                } else {
                    out.append(JSONLeaf(path: path, text: Format.number(number.doubleValue, maxFraction: 10), kind: .number))
                }
            } else if node is NSNull {
                out.append(JSONLeaf(path: path, text: "null", kind: .null))
            }
        }
        walk(root, [])
        return out
    }

    /// The value the user typed, as the same kind of JSON value it replaces (a number stays a number…).
    static func value(from text: String, like kind: JSONLeaf.Kind) -> Any? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        switch kind {
        case .string:
            return text
        case .number:
            if let int = Int64(trimmed) { return NSNumber(value: int) }
            if let double = Double(trimmed), double.isFinite { return NSNumber(value: double) }
            return nil
        case .bool:
            if trimmed.lowercased() == "true" { return NSNumber(value: true) }
            if trimmed.lowercased() == "false" { return NSNumber(value: false) }
            return nil
        case .null:
            if trimmed == "null" { return NSNull() }
            if let int = Int64(trimmed) { return NSNumber(value: int) }
            if let double = Double(trimmed) { return NSNumber(value: double) }
            return text
        }
    }

    /// A copy of `root` with the value at `path` replaced.
    static func setting(_ root: Any, _ path: ArraySlice<JSONPathPart>, to value: Any) -> Any {
        guard let part = path.first else { return value }
        switch part {
        case .key(let key):
            guard var dict = root as? [String: Any], let child = dict[key] else { return root }
            dict[key] = setting(child, path.dropFirst(), to: value)
            return dict
        case .index(let index):
            guard var array = root as? [Any], array.indices.contains(index) else { return root }
            array[index] = setting(array[index], path.dropFirst(), to: value)
            return array
        }
    }

    /// Leaves matching a search: an exact number ("1000"), or text found in the value or its path ("gold").
    static func matches(_ leaves: [JSONLeaf], _ query: String) -> [JSONLeaf] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return leaves }
        if let number = Double(q) {
            let exact = leaves.filter { $0.kind == .number && Double($0.text) == number || $0.kind == .string && $0.text == q }
            if !exact.isEmpty { return exact }
        }
        return leaves.filter { $0.text.localizedCaseInsensitiveContains(q) || $0.id.localizedCaseInsensitiveContains(q) }
    }
}

// MARK: - Editor

/// Unpacks a save, shows every value with a finder, lets you change values (or the raw JSON), and packs it back
/// in the same format. Used by the Save Editor, the Local Storage Editor and the HTML Game Editor.
struct GameDataEditorView: View {
    let title: String
    let original: String
    /// Called with the re-packed value when you save.
    let onSave: (String) -> Void
    /// Shown as a Cancel button when set (the view is in a sheet).
    var onCancel: (() -> Void)? = nil

    @State private var decoded: DecodedGameData?
    @State private var root: Any = NSNull()
    @State private var leaves: [JSONLeaf] = []
    @State private var search = ""
    @State private var selected: JSONLeaf?
    @State private var newValue = ""
    @State private var showRaw = false
    @State private var rawText = ""
    @State private var message = ""
    @State private var loaded = false
    @State private var changed = false
    /// For text saves (e.g. Cookie Clicker): the unpacked text and a number finder.
    @State private var packedText: PackedText?
    @State private var textBody = ""
    @State private var numberQuery = ""
    @State private var close = true
    @State private var selectedNumber: TextNumber?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.headline).lineLimit(1)
                if let format = decoded?.format.rawValue ?? packedText?.packing.rawValue {
                    Text(format)
                        .font(.caption)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                        .help("How the game packed this save. MacTools packs it back the same way.")
                }
                Spacer()
                if decoded != nil || packedText != nil {
                    Picker("", selection: $showRaw) {
                        Text("Values").tag(false)
                        Text(decoded != nil ? "Raw JSON" : "Raw Text").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 190)
                }
            }
            if packedText != nil {
                if showRaw {
                    CodeEditor(text: $textBody, minHeight: 300)
                } else {
                    textNumbersView
                }
            } else if decoded == nil {
                Text("This isn't JSON (or packed JSON) MacTools recognises, so it's shown as plain text.")
                    .font(.caption).foregroundStyle(.secondary)
                CodeEditor(text: $rawText, minHeight: 260)
            } else if showRaw {
                CodeEditor(text: $rawText, minHeight: 300)
                Button("Use This JSON") { useRaw() }
            } else {
                valuesView
            }
            if !message.isEmpty {
                Label(message, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Copy Save") {
                    if let packed = packedResult() {
                        ClipboardHelper.copy(packed)
                        message = "Copied. You can paste it into the game's own Import Save option."
                    }
                }
                .help("Copy the packed save, for a game's own Import Save box (Cookie Clicker: Options ▸ Import save)")
                if let onCancel = onCancel {
                    Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                }
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .onAppear(perform: load)
    }

    private var valuesView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find a value – type your gold, score or level (e.g. 1500) or a name like “gold”", text: $search)
                    .textFieldStyle(.plain)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
            let shown = JSONTree.matches(leaves, search)
            Text("\(shown.count) of \(leaves.count) values").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(shown.prefix(800)) { leaf in
                        Button {
                            selected = leaf
                            newValue = leaf.text
                        } label: {
                            HStack(alignment: .firstTextBaseline) {
                                Text(leaf.id)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                                Spacer(minLength: 8)
                                Text(leaf.text)
                                    .font(.system(.callout, design: .monospaced))
                                    .lineLimit(1)
                            }
                            .padding(.vertical, 3).padding(.horizontal, 6)
                            .background(RoundedRectangle(cornerRadius: 5).fill(selected?.id == leaf.id ? Color.accentColor.opacity(0.18) : .clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(minHeight: 220, maxHeight: 380)
            if let leaf = selected {
                HStack {
                    Text(leaf.id).font(.system(.caption, design: .monospaced)).lineLimit(1).truncationMode(.head)
                    TextField("New value", text: $newValue)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 160)
                        .onSubmit { setValue(leaf) }
                    Button("Set") { setValue(leaf) }
                        .disabled(JSONTree.value(from: newValue, like: leaf.kind) == nil)
                }
                if JSONTree.value(from: newValue, like: leaf.kind) == nil {
                    Text(leaf.kind == .bool ? "Type true or false." : "Type a number.").font(.caption).foregroundColor(.orange)
                }
            }
            Text("Tip: not sure which value is yours? Note your gold in the game, spend or earn some, save, reopen this and search the new number.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let found = GameDataCodec.decode(original) {
            decoded = found
            root = found.json
            leaves = JSONTree.leaves(found.json)
            rawText = GameDataCodec.jsonText(found.json, pretty: true) ?? found.text
        } else if let text = TextSave.unpack(original) {
            packedText = text
            textBody = text.text
        } else {
            rawText = original
        }
    }

    private var textNumbersView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find a number – type what the game shows, e.g. your cookies (1234567)", text: $numberQuery)
                    .textFieldStyle(.plain)
                Toggle("Close to", isOn: $close)
                    .help("Also match numbers within 1% – games often show rounded numbers like “1.23 million”")
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
            let found = TextSave.numbers(in: textBody, matching: numberQuery, close: close)
            if numberQuery.trimmed.isEmpty {
                Text("This save is packed text. Type a number you can see in the game to find where it's stored, or edit the whole text under Raw Text.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("\(found.count) match\(found.count == 1 ? "" : "es")").font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(found) { number in
                        Button {
                            selectedNumber = number
                            newValue = number.text
                        } label: {
                            HStack {
                                Text(number.context).font(.system(.caption, design: .monospaced)).lineLimit(1)
                                Spacer()
                                Text(number.place).font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 3).padding(.horizontal, 6)
                            .background(RoundedRectangle(cornerRadius: 5).fill(selectedNumber?.id == number.id ? Color.accentColor.opacity(0.18) : .clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(minHeight: 200, maxHeight: 360)
            if let number = selectedNumber {
                HStack {
                    Text(number.place.isEmpty ? "Set \(number.text) to" : "Set \(number.place) to").font(.caption)
                    TextField("New value", text: $newValue)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 160)
                        .onSubmit { setNumber(number) }
                    Button("Set") { setNumber(number) }
                        .disabled(Double(newValue.trimmed) == nil)
                }
            }
        }
    }

    private func setNumber(_ number: TextNumber) {
        let value = newValue.trimmed
        guard Double(value) != nil, number.range.upperBound <= textBody.endIndex,
              String(textBody[number.range]) == number.text else { return }
        textBody.replaceSubrange(number.range, with: value)
        selectedNumber = nil
        changed = true
        message = "Changed \(number.text) to \(value). Click Save (or Copy Save) to use it."
    }

    /// The edited save, packed the way the game packed it.
    private func packedResult() -> String? {
        if let text = packedText { return TextSave.pack(textBody, like: text) }
        guard let decoded = decoded else { return rawText }
        var json = root
        if showRaw {
            guard let parsed = GameDataCodec.parse(rawText) else {
                message = "That isn't valid JSON yet."
                return nil
            }
            json = parsed
        }
        guard let packed = GameDataCodec.encode(json, as: decoded.format, pretty: decoded.pretty) else {
            message = "Couldn't pack the save."
            return nil
        }
        return packed
    }

    private func setValue(_ leaf: JSONLeaf) {
        guard let value = JSONTree.value(from: newValue, like: leaf.kind) else { return }
        root = JSONTree.setting(root, leaf.path[...], to: value)
        leaves = JSONTree.leaves(root)
        selected = leaves.first { $0.id == leaf.id }
        rawText = GameDataCodec.jsonText(root, pretty: true) ?? rawText
        changed = true
        message = "Changed \(leaf.id). Click Save to write it."
    }

    private func useRaw() {
        guard let json = GameDataCodec.parse(rawText) else {
            message = "That isn't valid JSON yet."
            return
        }
        root = json
        leaves = JSONTree.leaves(json)
        changed = true
        message = "Using your JSON. Click Save to write it."
    }

    private func save() {
        guard let packed = packedResult() else { return }
        onSave(packed)
    }
}
