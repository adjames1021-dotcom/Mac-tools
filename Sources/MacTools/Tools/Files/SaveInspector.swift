import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Number encodings

/// The ways a number can be laid out in a file. A value-finder tries all of these so it can spot, say, your coin
/// count whether the game stored it as a 32-bit integer, a float, or plain text.
enum NumEnc: String, CaseIterable, Identifiable {
    case i8, u8
    case i16le, i16be, u16le, u16be
    case i32le, i32be, u32le, u32be
    case i64le, i64be, u64le, u64be
    case f32le, f32be, f64le, f64be

    var id: String { rawValue }

    var width: Int {
        switch self {
        case .i8, .u8: return 1
        case .i16le, .i16be, .u16le, .u16be: return 2
        case .i32le, .i32be, .u32le, .u32be, .f32le, .f32be: return 4
        default: return 8
        }
    }

    var isFloat: Bool { self == .f32le || self == .f32be || self == .f64le || self == .f64be }
    var bigEndian: Bool { rawValue.hasSuffix("be") }
    var signed: Bool { rawValue.hasPrefix("i") || isFloat }

    var title: String {
        let base: String
        switch self {
        case .i8: base = "Int8"
        case .u8: base = "UInt8"
        case .i16le, .i16be: base = "Int16"
        case .u16le, .u16be: base = "UInt16"
        case .i32le, .i32be: base = "Int32"
        case .u32le, .u32be: base = "UInt32"
        case .i64le, .i64be: base = "Int64"
        case .u64le, .u64be: base = "UInt64"
        case .f32le, .f32be: base = "Float (32-bit)"
        case .f64le, .f64be: base = "Double (64-bit)"
        }
        if width == 1 { return base }
        return base + (bigEndian ? " · big-endian" : " · little-endian")
    }

    /// The encodings most games actually use, for a first, quick search.
    static let common: [NumEnc] = [.i32le, .u32le, .f32le, .i64le, .u64le, .f64le, .i16le, .u16le]
}

/// Reads and writes numbers inside a blob of bytes, plus the value-finder itself. All pure functions, so they are
/// easy to test and don't touch the disk.
enum SaveScan {
    static func rawUInt(_ data: Data, _ offset: Int, width: Int, bigEndian: Bool) -> UInt64? {
        guard offset >= 0, offset + width <= data.count else { return nil }
        var value: UInt64 = 0
        for i in 0..<width {
            let byte = data[data.startIndex + offset + i]
            if bigEndian { value = (value << 8) | UInt64(byte) }
            else { value |= UInt64(byte) << (8 * i) }
        }
        return value
    }

    /// The number at `offset` read with encoding `enc`, as a Double (good enough to show; may lose precision for
    /// 64-bit integers past 2^53 — use `integerText` for those).
    static func double(_ data: Data, _ offset: Int, _ enc: NumEnc) -> Double? {
        guard let raw = rawUInt(data, offset, width: enc.width, bigEndian: enc.bigEndian) else { return nil }
        switch enc {
        case .f32le, .f32be: return Double(Float(bitPattern: UInt32(truncatingIfNeeded: raw)))
        case .f64le, .f64be: return Double(bitPattern: raw)
        default:
            if enc.signed {
                let bits = enc.width * 8
                let signBit = UInt64(1) << (bits - 1)
                if raw & signBit != 0 {
                    let extended = raw | (~UInt64(0) << bits)
                    return Double(Int64(bitPattern: extended))
                }
            }
            return Double(raw)
        }
    }

    /// An exact text form of an integer value (no float rounding), or nil for float encodings.
    static func integerText(_ data: Data, _ offset: Int, _ enc: NumEnc) -> String? {
        guard !enc.isFloat, let raw = rawUInt(data, offset, width: enc.width, bigEndian: enc.bigEndian) else { return nil }
        if enc.signed {
            let bits = enc.width * 8
            let signBit = UInt64(1) << (bits - 1)
            if bits < 64 && raw & signBit != 0 {
                return String(Int64(bitPattern: raw | (~UInt64(0) << bits)))
            }
            if bits == 64 { return String(Int64(bitPattern: raw)) }
        }
        return String(raw)
    }

    /// How the value at `offset` reads as every encoding (the "data inspector").
    static func inspect(_ data: Data, at offset: Int) -> [(enc: NumEnc, text: String)] {
        NumEnc.allCases.compactMap { enc in
            guard offset + enc.width <= data.count else { return nil }
            if enc.isFloat {
                guard let value = double(data, offset, enc) else { return nil }
                return (enc, Format.number(value))
            }
            guard let text = integerText(data, offset, enc) else { return nil }
            return (enc, text)
        }
    }

    /// Turns a user's number/encoding into the bytes to write.
    static func encodeNumber(_ text: String, _ enc: NumEnc) -> [UInt8]? {
        func bytes(_ value: UInt64) -> [UInt8] {
            var out = (0..<enc.width).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }
            if enc.bigEndian { out.reverse() }
            return out
        }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if enc.isFloat {
            guard let value = Double(trimmed) else { return nil }
            if enc.width == 4 { return bytes(UInt64(Float(value).bitPattern)) }
            return bytes(value.bitPattern)
        }
        let bits = enc.width * 8
        if enc.signed {
            guard let value = Int64(trimmed) else { return nil }
            if bits < 64 {
                let limit = Int64(1) << (bits - 1)
                guard value >= -limit && value < limit else { return nil }
            }
            return bytes(UInt64(bitPattern: value))
        }
        guard let value = UInt64(trimmed) else { return nil }
        if bits < 64 && value >= (UInt64(1) << bits) { return nil }
        return bytes(value)
    }

    /// Writes `bytes` into a copy of `data` at `offset`.
    static func writing(_ data: Data, _ bytes: [UInt8], at offset: Int) -> Data {
        var copy = data
        let start = copy.index(copy.startIndex, offsetBy: offset)
        copy.replaceSubrange(start..<copy.index(start, offsetBy: bytes.count), with: bytes)
        return copy
    }

    struct Match: Identifiable, Hashable {
        let id = UUID()
        let offset: Int
        let label: String
        /// The encoding to edit this match with (nil for text matches).
        let enc: NumEnc?
        let width: Int

        static func == (a: Match, b: Match) -> Bool { a.id == b.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    /// Every byte pattern a search for `query` should look for, with how to edit each kind back.
    static func patterns(for query: String, encodings: [NumEnc], text: Bool) -> [(label: String, enc: NumEnc?, bytes: [UInt8])] {
        var out: [(String, NumEnc?, [UInt8])] = []
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let looksNumeric = Double(trimmed) != nil
        if looksNumeric {
            for enc in encodings {
                if let bytes = encodeNumber(trimmed, enc) { out.append((enc.title, enc, bytes)) }
            }
        }
        if text && !trimmed.isEmpty {
            let ascii = Array(trimmed.utf8)
            out.append(("Text (UTF-8)", nil, ascii))
            var utf16: [UInt8] = []
            for scalar in trimmed.unicodeScalars where scalar.value <= 0xFFFF {
                utf16.append(UInt8(scalar.value & 0xFF))
                utf16.append(UInt8(scalar.value >> 8))
            }
            out.append(("Text (UTF-16)", nil, utf16))
        }
        // The same bytes found twice (e.g. 1000 as Int16 and UInt16) are one match: keep the first way of reading it.
        var seen = Set<[UInt8]>()
        return out.filter { !$0.2.isEmpty && seen.insert($0.2).inserted }
    }

    /// Finds every offset of `pattern` in `data`, up to `limit`.
    static func offsets(of pattern: [UInt8], in data: Data, limit: Int) -> [Int] {
        guard !pattern.isEmpty, pattern.count <= data.count else { return [] }
        var found: [Int] = []
        let needle = Data(pattern)
        var searchStart = data.startIndex
        while let range = data.range(of: needle, in: searchStart..<data.endIndex) {
            found.append(data.distance(from: data.startIndex, to: range.lowerBound))
            if found.count >= limit { break }
            searchStart = data.index(after: range.lowerBound)
        }
        return found
    }

    /// Runs a value search and returns matches, newest encodings first, capped at `limit` total.
    static func search(_ query: String, in data: Data, encodings: [NumEnc], text: Bool, limit: Int = 500) -> [Match] {
        var matches: [Match] = []
        for (label, enc, bytes) in patterns(for: query, encodings: encodings, text: text) {
            for offset in offsets(of: bytes, in: data, limit: limit - matches.count) {
                matches.append(Match(offset: offset, label: label, enc: enc, width: bytes.count))
                if matches.count >= limit { return matches.sorted { $0.offset < $1.offset } }
            }
        }
        return matches.sorted { $0.offset < $1.offset }
    }
}

// MARK: - File model

/// Loads a file for editing, keeps a backup before the first save, and tells the view what kind of file it is.
final class SaveFile: ObservableObject {
    @Published private(set) var url: URL?
    @Published private(set) var data = Data()
    @Published private(set) var typeName = ""
    @Published private(set) var isText = false
    @Published private(set) var isJSON = false
    /// Set when the file is a packed game save (e.g. RPG Maker MV's LZString `.rpgsave`, or Base64/plain JSON).
    @Published private(set) var gameFormat: GameDataFormat?
    @Published private(set) var status = ""
    @Published private(set) var dirty = false

    var size: Int { data.count }

    func open(_ url: URL) {
        guard let loaded = try? Data(contentsOf: url) else {
            status = "Couldn't read that file."
            return
        }
        self.url = url
        data = loaded
        typeName = HexDump.fileType(loaded)
        // Treat it as text if (almost) every byte is printable/whitespace – then it can be edited as text.
        let sample = loaded.prefix(65_536)
        let weird = sample.filter { $0 != 9 && $0 != 10 && $0 != 13 && !(32...126).contains($0) && $0 < 0x80 }.count
        // Text mode saves as UTF-8, so only files that already are valid UTF-8 are safe to edit as text.
        isText = !sample.isEmpty && Double(weird) / Double(sample.count) < 0.02 && String(data: loaded, encoding: .utf8) != nil
        let trimmed = loaded.prefix(1).first
        isJSON = isText && (trimmed == 0x7B || trimmed == 0x5B)
        gameFormat = isText ? GameDataCodec.decode(String(decoding: loaded, as: UTF8.self))?.format : nil
        dirty = false
        status = ""
    }

    var text: String {
        get { String(decoding: data, as: UTF8.self) }
    }

    func setData(_ newData: Data) {
        data = newData
        dirty = true
    }

    func setText(_ newText: String) {
        data = Data(newText.utf8)
        dirty = true
    }

    /// Writes the file back, making a one-time `.bak` copy first.
    func save() {
        guard let url = url else { return }
        let backup = url.appendingPathExtension("bak")
        if !FileManager.default.fileExists(atPath: backup.path) {
            try? FileManager.default.copyItem(at: url, to: backup)
        }
        do {
            try data.write(to: url, options: .atomic)
            dirty = false
            status = "Saved. A backup is at \(backup.lastPathComponent)."
        } catch {
            status = "Couldn't save: \(error.localizedDescription)"
        }
    }

    func restoreBackup() {
        guard let url = url else { return }
        let backup = url.appendingPathExtension("bak")
        guard let original = try? Data(contentsOf: backup) else {
            status = "No backup found."
            return
        }
        data = original
        try? original.write(to: url, options: .atomic)
        dirty = false
        status = "Restored from backup."
    }
}

// MARK: - View

struct SaveInspectorView: View {
    @StateObject private var file = SaveFile()
    @State private var mode = Mode.find
    @State private var editorText = ""
    /// Bumped when a file is opened or restored, so the game-data editor starts over from the file.
    @State private var version = 0

    enum Mode: String, CaseIterable, Identifiable {
        case game = "Game Data"
        case find = "Value Finder"
        case text = "Text / Structured"
        var id: String { rawValue }
    }

    private var modes: [Mode] { Mode.allCases.filter { $0 != .game || file.gameFormat != nil } }

    var body: some View {
        ToolPage(tool: .saveInspector) {
            fileCard
            if file.url != nil {
                Picker("", selection: $mode) {
                    ForEach(modes) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 480)
                switch mode {
                case .game: gameEditor
                case .find: SaveFinderView(file: file)
                case .text: textEditor
                }
                if !file.status.isEmpty {
                    Label(file.status, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var gameEditor: some View {
        Card(title: "Game Data", icon: "gamecontroller") {
            Text("This save is packed JSON. MacTools unpacked it – find a value like your gold, change it, and Save packs it back the same way.")
                .font(.caption)
                .foregroundStyle(.secondary)
            GameDataEditorView(title: file.url?.lastPathComponent ?? "Save", original: file.text) { packed in
                file.setText(packed)
                file.save()
                editorText = file.text
                version += 1
            }
            .id(version)
        }
    }

    private var fileCard: some View {
        Card(title: "File", icon: "doc.badge.gearshape") {
            HStack {
                Button("Choose File…") {
                    if let url = Panels.chooseFiles(multiple: false).first { load(url) }
                }
                if let url = file.url {
                    Text(url.lastPathComponent).bold().lineLimit(1)
                    Text("· \(Format.bytes(Int64(file.size))) · \(file.typeName)").foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text("…or drop a save file here. Works on .sav, .dat, .json, .xml, .plist and more.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if file.url != nil {
                    Button("Restore Backup") {
                        file.restoreBackup()
                        editorText = file.text
                        version += 1
                    }
                        .help("Put back the .bak copy MacTools made before your first save.")
                }
            }
            Text("MacTools copies the file to a “.bak” backup before the first save, and never changes the game – only this file. Close the game first.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .acceptsFileDrops { urls in if let url = urls.first { load(url) } }
    }

    private func load(_ url: URL) {
        file.open(url)
        editorText = file.text
        version += 1
        mode = file.gameFormat != nil ? .game : (file.isText ? .text : .find)
    }

    @ViewBuilder
    private var textEditor: some View {
        if !file.isText {
            Card(title: "Text", icon: "curlybraces") {
                Text("This file isn't plain UTF-8 text, so editing it as text could damage it. Use the Value Finder instead.")
                    .foregroundStyle(.secondary)
            }
        } else {
            textCard
        }
    }

    private var textCard: some View {
        Card(title: file.isJSON ? "JSON" : "Text", icon: "curlybraces") {
            Text("Find a value like your money (search with ⌘F in the box), change it, then Save. For JSON the file is checked before saving.")
                .font(.caption)
                .foregroundStyle(.secondary)
            CodeEditor(text: $editorText, minHeight: 320)
            HStack {
                Button("Save") { saveText() }
                    .buttonStyle(.borderedProminent)
                    .disabled(editorText == file.text)
                if file.isJSON {
                    Button("Format") { formatJSON() }
                }
                Spacer()
                Text("\(editorText.count) characters").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func saveText() {
        if file.isJSON {
            guard let data = editorText.data(using: .utf8),
                  (try? JSONSerialization.jsonObject(with: data)) != nil else {
                file.statusMessage("That isn't valid JSON yet – fix it before saving (or switch to Value Finder).")
                return
            }
        }
        file.setText(editorText)
        file.save()
    }

    private func formatJSON() {
        guard let data = editorText.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else {
            file.statusMessage("That isn't valid JSON yet.")
            return
        }
        editorText = String(decoding: pretty, as: UTF8.self)
    }
}

extension SaveFile {
    func statusMessage(_ message: String) { status = message }
}

/// The value search + data inspector + in-place number editor.
private struct SaveFinderView: View {
    @ObservedObject var file: SaveFile
    @State private var query = ""
    @State private var encodings = Set(NumEnc.common)
    @State private var searchText = true
    @State private var matches: [SaveScan.Match] = []
    @State private var selected: SaveScan.Match?
    @State private var newValue = ""
    @State private var searched = false
    @State private var searching = false
    @State private var searchToken = 0

    var body: some View {
        Card(title: "Find a Value", icon: "magnifyingglass") {
            Text("Know a number from the game – your coins, lives, score? Type it in, search, then pick the match that changes when you earn more, and edit it.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                TextField("A number (e.g. 1000) or some text", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(run)
                Toggle("Text too", isOn: $searchText)
                    .help("Also look for the value written as plain text")
                if searching { ProgressView().controlSize(.small) }
                Button("Search", action: run)
                    .buttonStyle(.borderedProminent)
                    .disabled(query.trimmed.isEmpty || searching)
            }
            DisclosureGroup("Number formats to try (\(encodings.count))") {
                let columns = [GridItem(.adaptive(minimum: 150), spacing: 6)]
                LazyVGrid(columns: columns, alignment: .leading, spacing: 4) {
                    ForEach(NumEnc.allCases) { enc in
                        Toggle(enc.title, isOn: Binding(
                            get: { encodings.contains(enc) },
                            set: { on in if on { encodings.insert(enc) } else { encodings.remove(enc) } }
                        ))
                        .font(.caption)
                    }
                }
                HStack {
                    Button("Common only") { encodings = Set(NumEnc.common) }
                    Button("All") { encodings = Set(NumEnc.allCases) }
                }
                .font(.caption)
            }
            .font(.callout)
        }

        if searched {
            Card(title: "Matches (\(matches.count)\(matches.count >= 500 ? "+, narrow your search" : ""))", icon: "list.number") {
                if matches.isEmpty {
                    Text("Nothing found. Try a different number, turn on more number formats, or search the text form.")
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(matches) { match in
                                matchRow(match)
                            }
                        }
                    }
                    .frame(maxHeight: 260)
                    Text("Not sure which is right? Change the value in the game, reload the file and search the new number – the real one is the match whose offset stays the same.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }

        if let match = selected {
            inspector(match)
        }
    }

    private func matchRow(_ match: SaveScan.Match) -> some View {
        Button {
            selected = match
            newValue = currentValue(match)
        } label: {
            HStack {
                Text(String(format: "0x%08X", match.offset))
                    .font(.system(.callout, design: .monospaced))
                Text("(\(match.offset))").foregroundStyle(.secondary).font(.caption)
                Spacer()
                Text(match.label).font(.caption).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected == match ? Color.accentColor.opacity(0.18) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func currentValue(_ match: SaveScan.Match) -> String {
        guard let enc = match.enc else {
            let bytes = Array(file.data[file.data.index(file.data.startIndex, offsetBy: match.offset)...].prefix(match.width))
            return String(decoding: bytes, as: UTF8.self)
        }
        return SaveScan.integerText(file.data, match.offset, enc)
            ?? SaveScan.double(file.data, match.offset, enc).map { Format.number($0) }
            ?? ""
    }

    private func inspector(_ match: SaveScan.Match) -> some View {
        Card(title: "At 0x\(String(format: "%08X", match.offset))", icon: "scope") {
            let rows = SaveScan.inspect(file.data, at: match.offset)
            let columns = [GridItem(.flexible()), GridItem(.flexible())]
            LazyVGrid(columns: columns, alignment: .leading, spacing: 2) {
                ForEach(rows, id: \.enc) { row in
                    HStack {
                        Text(row.enc.title).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(row.text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }
                }
            }
            Divider()
            HStack {
                if let enc = match.enc {
                    Text("Set \(enc.title) to")
                    TextField("New value", text: $newValue)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)
                    Button("Apply") { apply(match, enc: enc) }
                        .buttonStyle(.borderedProminent)
                        .disabled(SaveScan.encodeNumber(newValue, enc) == nil)
                    Button("Save File") { file.save() }
                        .disabled(!file.dirty)
                } else {
                    Text("This is a text match – edit text in the Text tab.").foregroundStyle(.secondary)
                }
                Spacer()
            }
            if let enc = match.enc, SaveScan.encodeNumber(newValue, enc) == nil, !newValue.isEmpty {
                Text("That value doesn't fit \(enc.title).").font(.caption).foregroundColor(.orange)
            }
        }
    }

    private func apply(_ match: SaveScan.Match, enc: NumEnc) {
        guard let bytes = SaveScan.encodeNumber(newValue, enc) else { return }
        file.setData(SaveScan.writing(file.data, bytes, at: match.offset))
        file.statusMessage("Changed the value at 0x\(String(format: "%08X", match.offset)). Click Save File to write it, or edit more first.")
    }

    private func run() {
        // Big files take a while to scan, so search off the main thread and ignore results from an older search.
        searchToken += 1
        let token = searchToken
        let data = file.data
        let text = query
        let chosen = NumEnc.allCases.filter { encodings.contains($0) }
        let alsoText = searchText
        searching = true
        selected = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let found = SaveScan.search(text, in: data, encodings: chosen, text: alsoText)
            DispatchQueue.main.async {
                guard token == searchToken else { return }
                matches = found
                searching = false
                searched = true
            }
        }
    }
}
