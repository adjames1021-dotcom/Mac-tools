import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Godot PCK parsing (pure, unit-testable)

/// One file packed inside a Godot .pck (or an embedded pack in a game executable).
struct GodotEntry: Identifiable, Hashable {
    let id = UUID()
    let path: String          // e.g. "res://scripts/player.gd"
    let offset: Int           // absolute byte offset in the pack file
    let size: Int
    let encrypted: Bool

    var name: String { (path as NSString).lastPathComponent }
    var ext: String { (path as NSString).pathExtension.lowercased() }
    var isScript: Bool { ext == "gd" }
    var isReadableText: Bool { ["gd", "json", "cfg", "tres", "tscn", "txt", "import", "godot", "xml", "svg", "csv"].contains(ext) }
}

struct GodotPack {
    let formatVersion: UInt32
    let engineMajor: UInt32
    let engineMinor: UInt32
    let enginePatch: UInt32
    let entries: [GodotEntry]
    let embedded: Bool

    var engineVersion: String { "\(engineMajor).\(engineMinor).\(enginePatch)" }
}

enum GodotPackError: LocalizedError {
    case notAPack
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .notAPack: return "This file isn't a Godot pack (no GDPC marker found)."
        case .unsupported(let message): return message
        }
    }
}

enum GodotPCK {
    static let magic: [UInt8] = [0x47, 0x44, 0x50, 0x43] // "GDPC"

    private static func u32(_ data: Data, _ offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        let b = data.startIndex + offset
        return UInt32(data[b]) | (UInt32(data[b + 1]) << 8) | (UInt32(data[b + 2]) << 16) | (UInt32(data[b + 3]) << 24)
    }

    private static func u64(_ data: Data, _ offset: Int) -> UInt64? {
        guard let lo = u32(data, offset), let hi = u32(data, offset + 4) else { return nil }
        return UInt64(lo) | (UInt64(hi) << 32)
    }

    private static func hasMagic(_ data: Data, at offset: Int) -> Bool {
        guard offset >= 0, offset + 4 <= data.count else { return false }
        let b = data.startIndex + offset
        return data[b] == magic[0] && data[b + 1] == magic[1] && data[b + 2] == magic[2] && data[b + 3] == magic[3]
    }

    /// Finds where the pack header begins: offset 0 for a standalone .pck, or deep inside an executable for an embedded pack.
    static func headerStart(in data: Data) -> (start: Int, embedded: Bool)? {
        if hasMagic(data, at: 0) { return (0, false) }
        // Embedded packs end with: [ds: uint64][magic "GDPC"]; the header sits ds+12 bytes from the end.
        let count = data.count
        guard count >= 12, hasMagic(data, at: count - 4), let ds = u64(data, count - 12) else { return nil }
        let start = count - 12 - Int(ds)
        guard start >= 0, hasMagic(data, at: start) else { return nil }
        return (start, true)
    }

    /// Parses the pack's directory. `data` should be the whole file (memory-mapped is fine).
    static func parse(_ data: Data) throws -> GodotPack {
        guard let header = headerStart(in: data) else { throw GodotPackError.notAPack }
        var cursor = header.start + 4 // past the magic
        guard let formatVersion = u32(data, cursor) else { throw GodotPackError.notAPack }
        cursor += 4
        guard let major = u32(data, cursor), let minor = u32(data, cursor + 4), let patch = u32(data, cursor + 8) else {
            throw GodotPackError.notAPack
        }
        cursor += 12

        var fileBase = 0
        if formatVersion >= 2 {
            // pack_flags (uint32) + files_base_offset (uint64)
            guard let _ = u32(data, cursor), let base = u64(data, cursor + 4) else { throw GodotPackError.notAPack }
            fileBase = Int(base)
            cursor += 12
            // 16 reserved uint32 words.
            cursor += 16 * 4
        }

        guard let fileCount = u32(data, cursor) else { throw GodotPackError.notAPack }
        cursor += 4

        // Offsets are relative to the pack start; embedded packs add the header's position.
        let packBase = header.embedded ? header.start : 0

        var entries: [GodotEntry] = []
        entries.reserveCapacity(Int(fileCount))
        for _ in 0..<fileCount {
            guard let pathLen = u32(data, cursor) else { break }
            cursor += 4
            let pathEnd = cursor + Int(pathLen)
            guard pathEnd <= data.count else { break }
            let rawPath = data.subdata(in: (data.startIndex + cursor)..<(data.startIndex + pathEnd))
            // Paths are null-padded to a 4-byte boundary in some versions; trim trailing NULs.
            let path = String(decoding: rawPath, as: UTF8.self).replacingOccurrences(of: "\0", with: "")
            cursor = pathEnd
            guard let offset = u64(data, cursor), let size = u64(data, cursor + 8) else { break }
            cursor += 16
            cursor += 16 // md5
            var encrypted = false
            if formatVersion >= 2 {
                let flags = u32(data, cursor) ?? 0
                encrypted = (flags & 1) != 0
                cursor += 4
            }
            let absolute = packBase + fileBase + Int(offset)
            entries.append(GodotEntry(path: path.trimmingCharacters(in: .whitespacesAndNewlines),
                                      offset: absolute, size: Int(size), encrypted: encrypted))
        }
        return GodotPack(formatVersion: formatVersion, engineMajor: major, engineMinor: minor,
                         enginePatch: patch, entries: entries, embedded: header.embedded)
    }

    /// Reads one packed file's bytes, if the offset and size fit inside the pack.
    static func readFile(_ entry: GodotEntry, from data: Data) -> Data? {
        guard !entry.encrypted, entry.offset >= 0, entry.offset + entry.size <= data.count else { return nil }
        return data.subdata(in: (data.startIndex + entry.offset)..<(data.startIndex + entry.offset + entry.size))
    }
}

/// Pulls function (and signal/class) declarations out of GDScript source.
enum GDScript {
    struct Function: Identifiable, Hashable {
        let id = UUID()
        let name: String
        let signature: String
        let isStatic: Bool
        let line: Int
    }

    static func functions(in source: String) -> [Function] {
        var out: [Function] = []
        let lines = source.components(separatedBy: "\n")
        let pattern = try? NSRegularExpression(pattern: #"^\s*(static\s+)?func\s+([A-Za-z_]\w*)\s*\(([^)]*)\)"#)
        for (index, line) in lines.enumerated() {
            guard let regex = pattern else { break }
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = regex.firstMatch(in: line, range: range) else { continue }
            let isStatic = match.range(at: 1).location != NSNotFound
            guard let nameRange = Range(match.range(at: 2), in: line) else { continue }
            let name = String(line[nameRange])
            var params = ""
            if let paramsRange = Range(match.range(at: 3), in: line) { params = String(line[paramsRange]) }
            let signature = "\(isStatic ? "static " : "")func \(name)(\(params.trimmingCharacters(in: .whitespaces)))"
            out.append(Function(name: name, signature: signature, isStatic: isStatic, line: index + 1))
        }
        return out
    }

    /// Heuristic: is this blob readable text (not compiled .gdc bytecode or binary resource)?
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

// MARK: - View

struct GodotInspectorView: View {
    @State private var packURL: URL?
    @State private var data: Data?
    @State private var pack: GodotPack?
    @State private var entries: [GodotEntry] = []
    @State private var filter = ""
    @State private var selected: GodotEntry?
    @State private var fileText = ""
    @State private var functions: [GDScript.Function] = []
    @State private var allFunctions: [(file: String, fn: GDScript.Function)] = []
    @State private var note = ""
    @State private var showingAllFunctions = false

    // AI
    @State private var aiProvider: AIProvider = .claude
    @State private var aiOutput = ""
    @State private var aiBusy = false

    var body: some View {
        ToolPage(tool: .godotInspector, scrolls: false) {
            Card(title: "Godot pack", icon: "shippingbox") {
                HStack {
                    Button("Open .pck or Game…") { openPack() }
                    if let pack = pack {
                        Text("Godot \(pack.engineVersion) · format v\(pack.formatVersion) · \(entries.count) files\(pack.embedded ? " · embedded" : "")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if pack != nil {
                        Button(showingAllFunctions ? "Browse Files" : "All GDScript Functions") {
                            showingAllFunctions.toggle()
                            if showingAllFunctions && allFunctions.isEmpty { extractAllFunctions() }
                        }
                    }
                }
                Text("Reads the files inside a Godot game: standalone .pck files and packs embedded in a game's executable. Lists every file and pulls the func definitions out of its GDScript. Encrypted packs can't be read.")
                    .font(.caption).foregroundStyle(.secondary)
                if !note.isEmpty { Text(note).font(.caption).foregroundColor(.orange) }
            }

            if pack == nil {
                Spacer()
                Text("Open a .pck file, or a game's .app / executable with an embedded pack.")
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
            List(entries, selection: Binding(get: { selected }, set: { if let e = $0 { choose(e) } })) { entry in
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
                .tag(entry)
                .contentShape(Rectangle())
                .onTapGesture { choose(entry) }
            }
        }
    }

    private var fileDetail: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let entry = selected {
                HStack {
                    Text(entry.path).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Export…") { exportSelected() }
                }
                if !functions.isEmpty {
                    Text("Functions (\(functions.count))").font(.caption.bold()).foregroundStyle(.secondary)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(functions) { fn in
                                Text("ƒ \(fn.signature)")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.accentColor)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .frame(maxHeight: 150)
                    Divider()
                }
                if entry.isReadableText || GDScript.looksLikeText(Data(fileText.utf8)) {
                    HStack {
                        Text("Contents").font(.caption.bold()).foregroundStyle(.secondary)
                        Spacer()
                        if entry.isScript {
                            Picker("", selection: $aiProvider) {
                                ForEach(AIProvider.allCases) { Text($0.title).tag($0) }
                            }.labelsHidden().frame(width: 150)
                            Button("Explain with AI") { explainWithAI() }
                                .disabled(aiBusy || !InspectorAI.hasKey(aiProvider))
                            if aiBusy { ProgressView().controlSize(.small) }
                        }
                    }
                    ScrollView {
                        Text(fileText.isEmpty ? "(empty or binary)" : fileText)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !aiOutput.isEmpty {
                        Divider()
                        ScrollView {
                            Text(aiOutput).font(.system(size: 12)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 160)
                    }
                } else {
                    Text("Binary file (\(byteSize(entry.size))). Use Export to save it.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Select a file to view it.").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(6)
    }

    private var allFunctionsList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(allFunctions.count) functions across \(Set(allFunctions.map { $0.file }).count) scripts")
                .font(.caption).foregroundStyle(.secondary)
            List {
                ForEach(Array(groupedFunctions.keys.sorted()), id: \.self) { file in
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

    private var groupedFunctions: [String: [GDScript.Function]] {
        Dictionary(grouping: allFunctions, by: { $0.file }).mapValues { $0.map { $0.fn } }
    }

    // MARK: Actions

    private func openPack() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true   // allow picking a .app bundle
        panel.allowsMultipleSelection = false
        panel.message = "Choose a Godot .pck file, or a game executable / .app with an embedded pack."
        guard panel.runModal() == .OK, var url = panel.url else { return }
        note = ""
        // If an .app bundle is chosen, look for the executable or a bundled .pck inside it.
        if url.pathExtension == "app" {
            if let inner = executableOrPack(in: url) { url = inner }
        }
        load(url)
    }

    private func executableOrPack(in appURL: URL) -> URL? {
        let fm = FileManager.default
        // A bundled .pck next to the app, or inside Resources, is the usual case.
        let resources = appURL.appendingPathComponent("Contents/Resources")
        if let items = try? fm.contentsOfDirectory(at: resources, includingPropertiesForKeys: nil) {
            if let pck = items.first(where: { $0.pathExtension == "pck" }) { return pck }
        }
        // Otherwise the embedded pack lives in the Mach-O executable.
        let macOS = appURL.appendingPathComponent("Contents/MacOS")
        if let items = try? fm.contentsOfDirectory(at: macOS, includingPropertiesForKeys: nil) {
            return items.first
        }
        return nil
    }

    private func load(_ url: URL) {
        guard let mapped = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            note = "Couldn't read that file."; return
        }
        do {
            let parsed = try GodotPCK.parse(mapped)
            packURL = url
            data = mapped
            pack = parsed
            entries = parsed.entries.sorted { $0.path < $1.path }
            selected = nil
            fileText = ""
            functions = []
            allFunctions = []
            showingAllFunctions = false
            applyFilter()
            if parsed.entries.contains(where: { $0.encrypted }) {
                note = "Some files in this pack are encrypted and can't be read."
            }
        } catch {
            note = error.localizedDescription
            pack = nil; entries = []
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
        functions = []
        fileText = ""
        aiOutput = ""
        guard let data = data, let bytes = GodotPCK.readFile(entry, from: data) else {
            fileText = entry.encrypted ? "(encrypted)" : "(couldn't read)"
            return
        }
        if GDScript.looksLikeText(bytes) {
            fileText = String(decoding: bytes, as: UTF8.self)
            if entry.isScript { functions = GDScript.functions(in: fileText) }
        } else {
            fileText = ""
        }
    }

    private func extractAllFunctions() {
        guard let data = data, let pack = pack else { return }
        var out: [(String, GDScript.Function)] = []
        for entry in pack.entries where entry.isScript && !entry.encrypted {
            guard let bytes = GodotPCK.readFile(entry, from: data), GDScript.looksLikeText(bytes) else { continue }
            let source = String(decoding: bytes, as: UTF8.self)
            for fn in GDScript.functions(in: source) { out.append((entry.path, fn)) }
        }
        allFunctions = out
    }

    private func exportSelected() {
        guard let entry = selected, let data = data, let bytes = GodotPCK.readFile(entry, from: data) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = entry.name
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? bytes.write(to: url)
        note = "Exported \(entry.name)."
    }

    private func explainWithAI() {
        guard let entry = selected, !fileText.isEmpty else { return }
        aiBusy = true
        aiOutput = ""
        let system = "You explain GDScript (Godot game script) to a developer reading a game's files. Summarise what the script does, the role of each function, and anything notable about the game logic. Be concise."
        let user = "File: \(entry.path)\n\n" + String(fileText.prefix(12000))
        InspectorAI.ask(provider: aiProvider, model: aiProvider == .claude ? SchoolModels.claudeDefault : SchoolModels.openAIDefault,
                        system: system, user: user) { result in
            aiBusy = false
            switch result {
            case .success(let text): aiOutput = text
            case .failure(let error): aiOutput = "⚠️ " + error.localizedDescription
            }
        }
    }

    private func iconFor(_ entry: GodotEntry) -> String {
        switch entry.ext {
        case "gd": return "curlybraces"
        case "png", "jpg", "jpeg", "webp", "svg": return "photo"
        case "ogg", "wav", "mp3": return "waveform"
        case "tscn", "scn": return "square.stack.3d.up"
        case "tres", "res": return "cube"
        case "json", "cfg", "import", "godot": return "doc.text"
        default: return "doc"
        }
    }

    private func byteSize(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }
}
