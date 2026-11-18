import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Godot PCK parsing (pure, unit-testable)
//
// Follows Godot's own loader (core/io/file_access_pack.cpp):
//   v1 (Godot 3)      header, 16 reserved words, directory; file offsets are absolute.
//   v2 (Godot 4.0–4.3) flags + file_base, 16 reserved words, directory; file_base is relative
//                     to the pack start only when the PACK_REL_FILEBASE flag is set.
//   v3/v4 (Godot 4.4+) flags + file_base + dir_offset; both are relative to the pack start and
//                     the directory sits wherever dir_offset points.
// Packs are found at the start of a .pck, from the "GDPC" trailer of a self-contained
// executable, or (as a last resort) by scanning for a plausible header.

/// One file packed inside a Godot .pck (or an embedded pack in a game executable).
struct GodotEntry: Identifiable, Hashable {
    let id = UUID()
    let path: String          // e.g. "res://scripts/player.gd"
    let offset: Int           // absolute byte offset in the file that holds the pack
    let size: Int
    let encrypted: Bool
    let delta: Bool           // a patch against an earlier pack, not the whole file

    var name: String { (path as NSString).lastPathComponent }
    var ext: String { (path as NSString).pathExtension.lowercased() }
    var isTextScript: Bool { ext == "gd" }
    var isCompiledScript: Bool { ext == "gdc" }
    var isScript: Bool { isTextScript || isCompiledScript }
    var isReadableText: Bool {
        ["gd", "json", "cfg", "tres", "tscn", "txt", "import", "godot", "xml", "svg", "csv", "remap", "gdshader", "md", "ini"].contains(ext)
    }
}

struct GodotPack {
    let formatVersion: UInt32
    let engineMajor: UInt32
    let engineMinor: UInt32
    let enginePatch: UInt32
    let entries: [GodotEntry]
    let embedded: Bool
    /// The file data lives in separate files next to the pack, so it can't be read from here.
    let sparseBundle: Bool
    let removedCount: Int

    var engineVersion: String { "\(engineMajor).\(engineMinor).\(enginePatch)" }
}

enum GodotPackError: LocalizedError {
    case notAPack
    case encryptedDirectory
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .notAPack: return "This file isn't a Godot pack (no GDPC header was found)."
        case .encryptedDirectory: return "This pack's file list is encrypted with the game's private key, so its contents can't be listed."
        case .unsupported(let message): return message
        }
    }
}

enum GodotPCK {
    static let magic: [UInt8] = [0x47, 0x44, 0x50, 0x43] // "GDPC"

    private static let dirEncrypted: UInt32 = 1 << 0
    private static let relFileBase: UInt32 = 1 << 1
    private static let sparseBundleFlag: UInt32 = 1 << 2
    private static let fileEncrypted: UInt32 = 1 << 0
    private static let fileRemoval: UInt32 = 1 << 1
    private static let fileDelta: UInt32 = 1 << 2

    static func u32(_ data: Data, _ offset: Int) -> UInt32? {
        guard offset >= 0, offset <= data.count - 4 else { return nil }
        let b = data.startIndex + offset
        return UInt32(data[b]) | (UInt32(data[b + 1]) << 8) | (UInt32(data[b + 2]) << 16) | (UInt32(data[b + 3]) << 24)
    }

    static func u64(_ data: Data, _ offset: Int) -> UInt64? {
        guard let lo = u32(data, offset), let hi = u32(data, offset + 4) else { return nil }
        return UInt64(lo) | (UInt64(hi) << 32)
    }

    /// Converts a 64-bit offset from the file into an Int, or nil if it can't be a real position.
    private static func position(_ value: UInt64) -> Int? {
        value <= UInt64(Int.max / 2) ? Int(value) : nil
    }

    private static func hasMagic(_ data: Data, at offset: Int) -> Bool {
        guard offset >= 0, offset <= data.count - 4 else { return false }
        let b = data.startIndex + offset
        return data[b] == magic[0] && data[b + 1] == magic[1] && data[b + 2] == magic[2] && data[b + 3] == magic[3]
    }

    /// A header candidate is plausible when its format and engine versions are in range.
    private static func plausibleHeader(_ data: Data, at offset: Int) -> Bool {
        guard hasMagic(data, at: offset),
              let version = u32(data, offset + 4), let major = u32(data, offset + 8), let minor = u32(data, offset + 12) else { return false }
        return (1...4).contains(version) && (1...9).contains(major) && minor < 100
    }

    /// Finds where the pack header begins.
    static func headerStart(in data: Data) -> (start: Int, embedded: Bool)? {
        if hasMagic(data, at: 0) { return (0, false) }
        // Self-contained executables end with [pack size: uint64][magic "GDPC"].
        let count = data.count
        if count >= 16, hasMagic(data, at: count - 4), let ds = u64(data, count - 12), ds < UInt64(count) {
            let start = count - 12 - Int(ds)
            if start >= 0, hasMagic(data, at: start) { return (start, true) }
        }
        // Last resort: an executable's "pck" section without the trailer.
        var searchFrom = data.startIndex
        var checked = 0
        while checked < 64, let range = data.range(of: Data(magic), in: searchFrom..<data.endIndex) {
            let offset = range.lowerBound - data.startIndex
            if plausibleHeader(data, at: offset) { return (offset, true) }
            searchFrom = range.upperBound
            checked += 1
        }
        return nil
    }

    /// Parses the pack's directory. `data` should be the whole file (memory-mapped is fine).
    static func parse(_ data: Data) throws -> GodotPack {
        guard let header = headerStart(in: data) else { throw GodotPackError.notAPack }
        let start = header.start
        var cursor = start + 4
        guard let version = u32(data, cursor), let major = u32(data, cursor + 4),
              let minor = u32(data, cursor + 8), let patch = u32(data, cursor + 12) else { throw GodotPackError.notAPack }
        cursor += 16
        guard (1...4).contains(version) else {
            throw GodotPackError.unsupported("This pack uses format version \(version), which MacTools doesn't know yet.")
        }

        var fileBase = 0
        var packFlags: UInt32 = 0
        if version == 1 {
            cursor += 16 * 4 // reserved
        } else {
            guard let flags = u32(data, cursor), let rawBase = u64(data, cursor + 4), let base = position(rawBase) else {
                throw GodotPackError.notAPack
            }
            packFlags = flags
            cursor += 12
            if flags & dirEncrypted != 0 { throw GodotPackError.encryptedDirectory }
            fileBase = base
            if version >= 3 || flags & relFileBase != 0 { fileBase += start }
            if version >= 3 {
                guard let rawDir = u64(data, cursor), let dir = position(rawDir) else { throw GodotPackError.notAPack }
                cursor = start + dir
            } else {
                cursor += 16 * 4 // reserved
            }
        }

        guard let fileCount = u32(data, cursor) else { throw GodotPackError.notAPack }
        cursor += 4
        // Every entry needs at least 36 bytes, so a count larger than the file allows means a bad header.
        guard Int(fileCount) <= (data.count - cursor) / 36 else {
            throw GodotPackError.unsupported("The pack's file list is damaged or in an unknown layout.")
        }

        var entries: [GodotEntry] = []
        entries.reserveCapacity(Int(fileCount))
        var removed = 0
        for _ in 0..<fileCount {
            guard let pathLen = u32(data, cursor), Int(pathLen) <= data.count - cursor - 4 else { break }
            cursor += 4
            let pathEnd = cursor + Int(pathLen)
            let rawPath = data.subdata(in: (data.startIndex + cursor)..<(data.startIndex + pathEnd))
            // Paths are NUL-padded to a 4-byte boundary.
            let path = String(decoding: rawPath, as: UTF8.self).replacingOccurrences(of: "\0", with: "")
            cursor = pathEnd
            guard let rawOffset = u64(data, cursor), let rawSize = u64(data, cursor + 8) else { break }
            cursor += 16 + 16 // offset, size, md5
            var fileFlags: UInt32 = 0
            if version >= 2 {
                guard let flags = u32(data, cursor) else { break }
                fileFlags = flags
                cursor += 4
            }
            if fileFlags & fileRemoval != 0 { removed += 1; continue }
            let offset = (position(rawOffset) ?? -1)
            let absolute = offset < 0 ? -1 : (version == 1 ? offset : fileBase + offset)
            entries.append(GodotEntry(path: path.trimmingCharacters(in: .whitespacesAndNewlines),
                                      offset: absolute, size: position(rawSize) ?? -1,
                                      encrypted: fileFlags & fileEncrypted != 0,
                                      delta: fileFlags & fileDelta != 0))
        }
        return GodotPack(formatVersion: version, engineMajor: major, engineMinor: minor, enginePatch: patch,
                         entries: entries, embedded: header.embedded,
                         sparseBundle: version >= 4 && packFlags & sparseBundleFlag != 0, removedCount: removed)
    }

    /// Reads one packed file's bytes, if it isn't encrypted and its offset and size fit inside the file.
    static func readFile(_ entry: GodotEntry, from data: Data) -> Data? {
        guard !entry.encrypted, entry.offset >= 0, entry.size >= 0, entry.offset <= data.count - entry.size else { return nil }
        return data.subdata(in: (data.startIndex + entry.offset)..<(data.startIndex + entry.offset + entry.size))
    }
}

// MARK: - GDScript (text and compiled)

/// What a script declares: its class, functions and signals.
struct GDScriptSummary {
    struct Function: Identifiable, Hashable {
        let id = UUID()
        let name: String
        let signature: String
        let isStatic: Bool
        let line: Int
    }

    var className: String?
    var extends: String?
    var functions: [Function] = []
    var signals: [String] = []
    /// Every name a compiled script uses, when its functions can't be told apart from the rest.
    var identifiers: [String] = []
    /// Explains anything that couldn't be read.
    var note: String?

    var isEmpty: Bool { functions.isEmpty && signals.isEmpty && identifiers.isEmpty && className == nil && extends == nil }
}

enum GDScript {
    private static let funcPattern = try? NSRegularExpression(pattern:
        #"^(\s*(?:@[\w.]+(?:\([^)]*\))?\s+)*(?:(?:static|remote|remotesync|master|mastersync|puppet|puppetsync|sync)\s+)*)func\s+([A-Za-z_]\w*)\s*\(([^)]*)(\))?(?:\s*->\s*([\w.\[\]]+))?"#)
    private static let signalPattern = try? NSRegularExpression(pattern: #"^\s*signal\s+([A-Za-z_]\w*)\s*(\(([^)]*)\))?"#)
    private static let classNamePattern = try? NSRegularExpression(pattern: #"^\s*class_name\s+([A-Za-z_]\w*)"#)
    private static let extendsPattern = try? NSRegularExpression(pattern: #"^\s*extends\s+(\S+)"#)

    private static func group(_ match: NSTextCheckingResult, _ index: Int, in line: String) -> String? {
        guard index < match.numberOfRanges, let range = Range(match.range(at: index), in: line) else { return nil }
        return String(line[range])
    }

    /// Reads declarations out of GDScript source text.
    static func summarize(source: String) -> GDScriptSummary {
        var summary = GDScriptSummary()
        for (index, line) in source.components(separatedBy: "\n").enumerated() {
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            if let regex = funcPattern, let match = regex.firstMatch(in: line, range: range),
               let name = group(match, 2, in: line) {
                let prefix = group(match, 1, in: line) ?? ""
                let isStatic = prefix.range(of: #"\bstatic\b"#, options: .regularExpression) != nil
                let params = (group(match, 3, in: line) ?? "").trimmingCharacters(in: .whitespaces)
                let closed = group(match, 4, in: line) != nil
                var signature = "\(isStatic ? "static " : "")func \(name)(\(params)\(closed ? ")" : "…)")"
                if let returns = group(match, 5, in: line) { signature += " -> \(returns)" }
                summary.functions.append(.init(name: name, signature: signature, isStatic: isStatic, line: index + 1))
                continue
            }
            if let regex = signalPattern, let match = regex.firstMatch(in: line, range: range), let name = group(match, 1, in: line) {
                summary.signals.append(name + (group(match, 2, in: line) ?? ""))
                continue
            }
            if summary.className == nil, let regex = classNamePattern, let match = regex.firstMatch(in: line, range: range) {
                summary.className = group(match, 1, in: line)
            }
            if summary.extends == nil, let regex = extendsPattern, let match = regex.firstMatch(in: line, range: range) {
                summary.extends = group(match, 1, in: line)
            }
        }
        return summary
    }

    /// Heuristic: is this blob readable text (not compiled bytecode or a binary resource)?
    static func looksLikeText(_ data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        let sample = data.prefix(2000)
        var printable = 0
        for byte in sample {
            if byte == 0 { return false }
            if byte == 9 || byte == 10 || byte == 13 || (byte >= 32 && byte < 127) || byte >= 0xC2 { printable += 1 }
        }
        return Double(printable) / Double(sample.count) > 0.85
    }
}

/// Reads Godot's compiled GDScript (.gdc "binary tokens", modules/gdscript/gdscript_tokenizer_buffer.cpp).
enum GDScriptBinary {
    // Token numbers shared by tokenizer versions 100 (Godot 4.3–4.4) and 101 (Godot 4.5+).
    private static let annotation: UInt32 = 1
    private static let identifier: UInt32 = 2
    private static let classNameToken: UInt32 = 56
    private static let extendsToken: UInt32 = 59
    private static let funcToken: UInt32 = 60
    private static let signalToken: UInt32 = 66
    private static let staticToken: UInt32 = 67
    private static let parenOpen: UInt32 = 77
    private static let parenClose: UInt32 = 78
    private static let comma: UInt32 = 79

    private struct Token { let type: UInt32; let index: Int; let line: Int }

    static func isCompiled(_ data: Data) -> Bool {
        data.count >= 12 && Array(data.prefix(4)) == Array("GDSC".utf8)
    }

    /// Decodes a .gdc file. `decompress` unpacks zstd data to the given size (nil if it can't).
    static func summarize(_ data: Data, decompress: (Data, Int) -> Data?) -> GDScriptSummary {
        var summary = GDScriptSummary()
        guard isCompiled(data), let version = GodotPCK.u32(data, 4) else {
            summary.note = "Not a compiled GDScript file."
            return summary
        }
        if version < 100 {
            return godot3(data, version: version)
        }
        guard let decompressedSize = GodotPCK.u32(data, 8) else { return summary }
        let body: Data
        if decompressedSize == 0 {
            body = data.subdata(in: (data.startIndex + 12)..<data.endIndex)
        } else if let unpacked = decompress(data.subdata(in: (data.startIndex + 12)..<data.endIndex), Int(decompressedSize)),
                  unpacked.count == Int(decompressedSize) {
            body = unpacked
        } else {
            summary.note = "This script is compiled and compressed with zstd. Install zstd (brew install zstd) and reopen the file to read its functions."
            return summary
        }

        // Tokenizer 100 has an extra (unused) header word before the token count.
        guard let identifierCount = GodotPCK.u32(body, 0), let tokenLineCount = GodotPCK.u32(body, 8),
              let tokenCount = GodotPCK.u32(body, version == 100 ? 16 : 12) else {
            summary.note = "The compiled script is damaged."
            return summary
        }
        _ = tokenLineCount
        var cursor = version == 100 ? 20 : 16
        var identifiers: [String] = []
        for _ in 0..<identifierCount {
            guard let length = GodotPCK.u32(body, cursor), Int(length) <= (body.count - cursor - 4) / 4 else { break }
            cursor += 4
            var scalars = String.UnicodeScalarView()
            for j in 0..<Int(length) {
                let b = body.startIndex + cursor + j * 4
                let value = UInt32(body[b] ^ 0xb6) | (UInt32(body[b + 1] ^ 0xb6) << 8)
                    | (UInt32(body[b + 2] ^ 0xb6) << 16) | (UInt32(body[b + 3] ^ 0xb6) << 24)
                if let scalar = Unicode.Scalar(value) { scalars.append(scalar) }
            }
            identifiers.append(String(scalars))
            cursor += Int(length) * 4
        }
        summary.identifiers = identifiers

        // Every token Godot writes is 8 bytes (flag bit 0x80 set), and tokens end the buffer.
        // Reading them from the end avoids having to decode the constants in between.
        let tokenBytes = Int(tokenCount) * 8
        guard version <= 101, tokenCount > 0, tokenBytes <= body.count - cursor else {
            summary.note = version > 101
                ? "This script was compiled by a newer Godot (format \(version)); only the names it uses are listed."
                : "Only the names this compiled script uses could be read."
            return summary
        }
        var tokens: [Token] = []
        tokens.reserveCapacity(Int(tokenCount))
        var offset = body.count - tokenBytes
        for _ in 0..<tokenCount {
            guard let raw = GodotPCK.u32(body, offset), raw & 0x80 != 0, let line = GodotPCK.u32(body, offset + 4) else {
                summary.note = "Only the names this compiled script uses could be read."
                return summary
            }
            tokens.append(Token(type: raw & 0x7F, index: Int(raw >> 8), line: Int(line)))
            offset += 8
        }

        func name(_ token: Token) -> String? {
            token.type == identifier && token.index < identifiers.count ? identifiers[token.index] : nil
        }

        var i = 0
        while i < tokens.count {
            let token = tokens[i]
            let next = i + 1 < tokens.count ? tokens[i + 1] : nil
            switch token.type {
            case funcToken:
                guard let next = next, let fnName = name(next) else { break } // a lambda has no name
                let isStatic = i > 0 && tokens[i - 1].type == staticToken
                var params: [String] = []
                var j = i + 2
                if j < tokens.count, tokens[j].type == parenOpen {
                    var depth = 1
                    var expectName = true
                    j += 1
                    while j < tokens.count, depth > 0 {
                        let t = tokens[j]
                        if t.type == parenOpen { depth += 1 }
                        else if t.type == parenClose { depth -= 1 }
                        else if depth == 1 {
                            if t.type == comma { expectName = true }
                            else if expectName, let param = name(t) { params.append(param); expectName = false }
                        }
                        j += 1
                    }
                }
                let signature = "\(isStatic ? "static " : "")func \(fnName)(\(params.joined(separator: ", ")))"
                summary.functions.append(.init(name: fnName, signature: signature, isStatic: isStatic, line: token.line))
            case signalToken:
                if let next = next, let signalName = name(next) { summary.signals.append(signalName) }
            case classNameToken:
                if summary.className == nil, let next = next { summary.className = name(next) }
            case extendsToken:
                if summary.extends == nil, let next = next { summary.extends = name(next) }
            default:
                break
            }
            i += 1
        }
        if summary.functions.isEmpty && summary.signals.isEmpty {
            summary.note = "No functions were found in this compiled script."
        }
        return summary
    }

    /// Godot 3 compiled scripts: only the identifier table is version-independent, so list that.
    private static func godot3(_ data: Data, version: UInt32) -> GDScriptSummary {
        var summary = GDScriptSummary()
        guard let identifierCount = GodotPCK.u32(data, 8) else { return summary }
        var cursor = 24
        var names: [String] = []
        for _ in 0..<identifierCount {
            guard let length = GodotPCK.u32(data, cursor), Int(length) <= data.count - cursor - 4 else { break }
            cursor += 4
            var bytes = [UInt8]()
            bytes.reserveCapacity(Int(length))
            for j in 0..<Int(length) {
                let byte = data[data.startIndex + cursor + j] ^ 0xb6
                if byte == 0 { break }
                bytes.append(byte)
            }
            names.append(String(decoding: bytes, as: UTF8.self))
            cursor += Int(length)
        }
        summary.identifiers = names
        summary.note = "Godot 3 compiled script (bytecode \(version)). Its function names can't be separated from the other names it uses, so all \(names.count) are listed."
        return summary
    }

    /// Unpacks zstd data with the zstd command-line tool, if it's installed (Homebrew).
    static func zstdDecompress(_ data: Data, expectedSize: Int) -> Data? {
        let candidates = ["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd", "/usr/bin/zstd"]
        guard let tool = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        let input = FileManager.default.temporaryDirectory.appendingPathComponent("mactools-\(UUID().uuidString).zst")
        defer { try? FileManager.default.removeItem(at: input) }
        guard (try? data.write(to: input)) != nil else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = ["-d", "-c", "-q", input.path]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let result = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, result.count == expectedSize else { return nil }
        return result
    }
}

// MARK: - View

struct GodotInspectorView: View {
    @State private var data: Data?
    @State private var pack: GodotPack?
    @State private var entries: [GodotEntry] = []
    @State private var filter = ""
    @State private var selected: GodotEntry?
    @State private var fileText = ""
    @State private var fileIsText = false
    @State private var textCut = false
    @State private var summary = GDScriptSummary()
    @State private var allFunctions: [(file: String, fn: GDScriptSummary.Function)] = []
    @State private var scanningAll = false
    @State private var note = ""
    @State private var showingAllFunctions = false

    // AI
    @ObservedObject private var planner = SchoolPlanner.shared
    @State private var aiProvider: AIProvider = InspectorAI.defaultProvider
    @State private var aiOutput = ""
    @State private var aiBusy = false

    private static let displayLimit = 400_000

    var body: some View {
        ToolPage(tool: .godotInspector, scrolls: false) {
            Card(title: "Godot pack", icon: "shippingbox") {
                HStack {
                    Button("Open .pck or Game…") { openPack() }
                    if let pack = pack {
                        Text("Godot \(pack.engineVersion) · pack format v\(pack.formatVersion) · \(pack.entries.count) files\(pack.embedded ? " · embedded" : "")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if pack != nil {
                        Button(showingAllFunctions ? "Browse Files" : "All Script Functions") {
                            showingAllFunctions.toggle()
                            if showingAllFunctions && allFunctions.isEmpty { extractAllFunctions() }
                        }
                    }
                }
                Text("Reads the files inside a Godot 3 or 4 game: standalone .pck files and packs embedded in a game's executable. Lists every file and pulls the functions out of its scripts, including compiled .gdc scripts. Encrypted files can't be read.")
                    .font(.caption).foregroundStyle(.secondary)
                if !note.isEmpty { Text(note).font(.caption).foregroundColor(.orange) }
            }

            if pack == nil {
                Text("Open a .pck file, or a game's .app / executable with an embedded pack. For a web game, Element Inspector ▸ Godot shows the address of its .pck to download.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if showingAllFunctions {
                allFunctionsList
            } else {
                HSplitView {
                    fileList.frame(minWidth: 260)
                    fileDetail.frame(minWidth: 340)
                }
            }
        }
        .onChange(of: filter) { _ in applyFilter() }
    }

    private var fileList: some View {
        VStack(spacing: 4) {
            TextField("Filter files…", text: $filter).textFieldStyle(.roundedBorder)
            List(entries, selection: Binding<UUID?>(
                get: { selected?.id },
                set: { id in if let id = id, let entry = entries.first(where: { $0.id == id }) { choose(entry) } }
            )) { entry in
                HStack {
                    Image(systemName: entry.encrypted ? "lock" : iconFor(entry))
                        .foregroundStyle(entry.encrypted ? .orange : .secondary)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(entry.name).font(.system(size: 11)).lineLimit(1)
                        Text(entry.path).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Text(byteSize(entry.size)).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var fileDetail: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let entry = selected {
                HStack {
                    Text(entry.path).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Export…") { exportSelected() }.disabled(entry.encrypted)
                }
                if entry.delta {
                    Text("This entry is a patch against an earlier pack, so its bytes are a diff rather than the whole file.")
                        .font(.caption).foregroundColor(.orange)
                }
                if entry.isScript {
                    scriptSummaryView
                    aiControls
                }
                if fileIsText {
                    Text(textCut ? "Contents (first \(Self.displayLimit / 1000)k characters – export to see it all)" : "Contents")
                        .font(.caption.bold()).foregroundStyle(.secondary)
                    ScrollView {
                        Text(fileText)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else if !entry.isScript {
                    Text(entry.encrypted ? "This file is encrypted." : "Binary file (\(byteSize(entry.size))). Use Export to save it.")
                        .foregroundStyle(.secondary)
                }
                if !aiOutput.isEmpty {
                    Divider()
                    ScrollView {
                        Text(aiOutput).font(.system(size: 12)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 180)
                }
                Spacer(minLength: 0)
            } else {
                Text("Select a file to view it.").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(6)
    }

    private var scriptSummaryView: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let className = summary.className { Text("class_name \(className)").font(.caption.monospaced()) }
            if let extends = summary.extends { Text("extends \(extends)").font(.caption.monospaced()).foregroundStyle(.secondary) }
            if let message = summary.note { Text(message).font(.caption).foregroundColor(.orange) }
            if !summary.functions.isEmpty || !summary.signals.isEmpty {
                Text("Functions (\(summary.functions.count))" + (summary.signals.isEmpty ? "" : " · Signals (\(summary.signals.count))"))
                    .font(.caption.bold()).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(summary.functions) { fn in
                            Text("ƒ \(fn.signature)" + (fn.line > 0 ? "   ·  line \(fn.line)" : ""))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.accentColor)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        ForEach(summary.signals, id: \.self) { signal in
                            Text("⚡︎ signal \(signal)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxHeight: 170)
            } else if !summary.identifiers.isEmpty {
                Text("Names used (\(summary.identifiers.count))").font(.caption.bold()).foregroundStyle(.secondary)
                ScrollView {
                    Text(summary.identifiers.joined(separator: ", "))
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
            }
            Divider()
        }
    }

    private var aiControls: some View {
        HStack {
            AIProviderBar(provider: $aiProvider)
            Spacer()
            Button("Explain with AI") { explainWithAI() }
                .disabled(aiBusy || !planner.hasKey(aiProvider) || (fileText.isEmpty && summary.isEmpty))
            if aiBusy { ProgressView().controlSize(.small) }
        }
    }

    private var allFunctionsList: some View {
        VStack(alignment: .leading, spacing: 4) {
            if scanningAll {
                HStack { ProgressView().controlSize(.small); Text("Reading every script…").font(.caption) }
            } else {
                Text("\(allFunctions.count) functions across \(Set(allFunctions.map { $0.file }).count) scripts")
                    .font(.caption).foregroundStyle(.secondary)
            }
            List {
                ForEach(groupedFunctions.keys.sorted(), id: \.self) { file in
                    Section(header: Text(file).font(.system(size: 11, design: .monospaced))) {
                        ForEach(groupedFunctions[file] ?? []) { fn in
                            Text("ƒ \(fn.signature)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.accentColor)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
    }

    private var groupedFunctions: [String: [GDScriptSummary.Function]] {
        Dictionary(grouping: allFunctions, by: { $0.file }).mapValues { $0.map { $0.fn } }
    }

    // MARK: Actions

    private func openPack() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false // .app bundles are still selectable as packages
        panel.allowsMultipleSelection = false
        panel.message = "Choose a Godot .pck file, or a game executable / .app with an embedded pack."
        guard panel.runModal() == .OK, var url = panel.url else { return }
        note = ""
        if url.pathExtension.lowercased() == "app" {
            guard let inner = executableOrPack(in: url) else {
                note = "No Godot pack was found inside that app."
                return
            }
            url = inner
        }
        load(url)
    }

    private func executableOrPack(in appURL: URL) -> URL? {
        let fm = FileManager.default
        // macOS exports usually ship the .pck in Contents/Resources.
        let resources = appURL.appendingPathComponent("Contents/Resources")
        if let items = try? fm.contentsOfDirectory(at: resources, includingPropertiesForKeys: nil),
           let pck = items.first(where: { $0.pathExtension.lowercased() == "pck" }) {
            return pck
        }
        // Otherwise the pack is embedded in the main executable.
        if let bundle = Bundle(url: appURL), let exe = bundle.executableURL { return exe }
        let macOS = appURL.appendingPathComponent("Contents/MacOS")
        return (try? fm.contentsOfDirectory(at: macOS, includingPropertiesForKeys: nil))?.first
    }

    private func load(_ url: URL) {
        guard let mapped = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            note = "Couldn't read that file."; return
        }
        do {
            let parsed = try GodotPCK.parse(mapped)
            data = mapped
            pack = parsed
            selected = nil
            fileText = ""
            fileIsText = false
            summary = GDScriptSummary()
            allFunctions = []
            aiOutput = ""
            showingAllFunctions = false
            applyFilter()
            var notes: [String] = []
            let locked = parsed.entries.filter { $0.encrypted }.count
            if locked > 0 { notes.append("\(locked) file\(locked == 1 ? " is" : "s are") encrypted and can't be read.") }
            if parsed.sparseBundle { notes.append("This pack keeps its file data in separate files, so only the file list can be shown.") }
            if parsed.removedCount > 0 { notes.append("This patch pack removes \(parsed.removedCount) file\(parsed.removedCount == 1 ? "" : "s").") }
            note = notes.joined(separator: " ")
        } catch {
            note = error.localizedDescription
            pack = nil
            data = nil
            entries = []
        }
    }

    private func applyFilter() {
        guard let pack = pack else { return }
        let f = filter.trimmed.lowercased()
        let base = pack.entries.sorted { $0.path < $1.path }
        entries = f.isEmpty ? base : base.filter { $0.path.lowercased().contains(f) }
    }

    private func choose(_ entry: GodotEntry) {
        selected = entry
        summary = GDScriptSummary()
        fileText = ""
        fileIsText = false
        textCut = false
        aiOutput = ""
        guard let data = data, let pack = pack, !pack.sparseBundle, let bytes = GodotPCK.readFile(entry, from: data) else {
            if entry.isScript {
                summary.note = entry.encrypted ? "This script is encrypted." : "This script couldn't be read from the pack."
            }
            return
        }
        if GDScriptBinary.isCompiled(bytes) {
            summary = GDScriptBinary.summarize(bytes, decompress: GDScriptBinary.zstdDecompress)
        } else if GDScript.looksLikeText(bytes) {
            let text = String(decoding: bytes, as: UTF8.self)
            if entry.isScript { summary = GDScript.summarize(source: text) }
            textCut = text.count > Self.displayLimit
            fileText = textCut ? String(text.prefix(Self.displayLimit)) : text
            fileIsText = true
        } else if entry.isScript {
            summary.note = "This script is in a format MacTools can't read (it may be encrypted)."
        }
    }

    private func extractAllFunctions() {
        guard let data = data, let pack = pack, !pack.sparseBundle else { return }
        scanningAll = true
        let scripts = pack.entries.filter { $0.isScript && !$0.encrypted }
        DispatchQueue.global(qos: .userInitiated).async {
            var out: [(file: String, fn: GDScriptSummary.Function)] = []
            for entry in scripts {
                guard let bytes = GodotPCK.readFile(entry, from: data) else { continue }
                let found: GDScriptSummary
                if GDScriptBinary.isCompiled(bytes) {
                    found = GDScriptBinary.summarize(bytes, decompress: GDScriptBinary.zstdDecompress)
                } else if GDScript.looksLikeText(bytes) {
                    found = GDScript.summarize(source: String(decoding: bytes, as: UTF8.self))
                } else {
                    continue
                }
                for fn in found.functions { out.append((file: entry.path, fn: fn)) }
            }
            DispatchQueue.main.async {
                allFunctions = out
                scanningAll = false
            }
        }
    }

    private func exportSelected() {
        guard let entry = selected, let data = data, let bytes = GodotPCK.readFile(entry, from: data) else {
            note = "That file can't be exported."; return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = entry.name
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try bytes.write(to: url)
            note = "Exported \(entry.name)."
        } catch {
            note = "Couldn't save: \(error.localizedDescription)"
        }
    }

    private func explainWithAI() {
        guard let entry = selected else { return }
        var material: String
        if !fileText.isEmpty {
            material = fileText
        } else {
            // A compiled script: describe what could be read from it.
            var lines: [String] = []
            if let className = summary.className { lines.append("class_name \(className)") }
            if let extends = summary.extends { lines.append("extends \(extends)") }
            lines += summary.functions.map { $0.signature }
            lines += summary.signals.map { "signal \($0)" }
            if summary.functions.isEmpty && !summary.identifiers.isEmpty {
                lines.append("Names used: " + summary.identifiers.joined(separator: ", "))
            }
            material = "(Compiled script – only its declarations could be read.)\n" + lines.joined(separator: "\n")
        }
        let limit = 300_000
        if material.count > limit {
            material = String(material.prefix(limit)) + "\n\n[The file continues; only the first \(limit / 1000)k characters were sent.]"
        }
        aiBusy = true
        aiOutput = ""
        let system = "You explain GDScript (Godot game scripts) to someone reading a game's files. Summarise what the script does, the role of each function, and anything notable about the game logic, such as where values like health, money or score are changed. Be concise."
        InspectorAI.ask(provider: aiProvider, system: system, user: "File: \(entry.path)\n\n\(material)") { result in
            aiBusy = false
            switch result {
            case .success(let text): aiOutput = text
            case .failure(let error): aiOutput = "⚠️ " + error.localizedDescription
            }
        }
    }

    private func iconFor(_ entry: GodotEntry) -> String {
        switch entry.ext {
        case "gd", "gdc": return "curlybraces"
        case "png", "jpg", "jpeg", "webp", "svg", "ctex", "stex": return "photo"
        case "ogg", "wav", "mp3", "oggvorbisstr", "sample": return "waveform"
        case "tscn", "scn": return "square.stack.3d.up"
        case "tres", "res": return "cube"
        case "json", "cfg", "import", "godot", "remap": return "doc.text"
        default: return "doc"
        }
    }

    private func byteSize(_ bytes: Int) -> String {
        if bytes < 0 { return "?" }
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }
}
