import SwiftUI
import AppKit

// MARK: - Reading Chromium local storage

/// Reads the localStorage that Chrome-family browsers keep on disk (a LevelDB database). Pure parsing, no disk writes.
/// Good enough to view and copy what's stored; recent changes live in the `.log` journal, which this decodes exactly.
enum ChromiumLocalStorage {
    struct Entry: Identifiable, Hashable {
        let id = UUID()
        var key: String
        var value: String
    }

    private static func varint(_ bytes: [UInt8], _ i: inout Int) -> Int? {
        var result = 0, shift = 0
        while i < bytes.count {
            let b = bytes[i]; i += 1
            result |= Int(b & 0x7F) << shift
            if b & 0x80 == 0 { return result }
            shift += 7
            if shift > 35 { return nil }
        }
        return nil
    }

    /// Splits a LevelDB write-ahead log into its logical records (each one a write batch).
    static func logRecords(_ data: Data) -> [[UInt8]] {
        let bytes = [UInt8](data)
        let block = 32768
        var records: [[UInt8]] = []
        var current: [UInt8] = []
        var pos = 0
        while pos + 7 <= bytes.count {
            let inBlock = pos % block
            if block - inBlock < 7 { pos += block - inBlock; continue }   // zero padding at a block's tail
            let length = Int(bytes[pos + 4]) | (Int(bytes[pos + 5]) << 8)
            let type = bytes[pos + 6]
            let start = pos + 7
            guard start + length <= bytes.count else { break }
            let chunk = Array(bytes[start..<start + length])
            pos = start + length
            switch type {
            case 1: records.append(chunk)                                  // full record
            case 2: current = chunk                                         // first fragment
            case 3: current += chunk                                        // middle fragment
            case 4: current += chunk; records.append(current); current = [] // last fragment
            default: break
            }
        }
        return records
    }

    /// The put/delete operations inside one write batch (value nil = delete).
    static func batchEntries(_ batch: [UInt8]) -> [(key: [UInt8], value: [UInt8]?)] {
        guard batch.count >= 12 else { return [] }
        var i = 12   // 8-byte sequence number + 4-byte count
        var out: [(key: [UInt8], value: [UInt8]?)] = []
        while i < batch.count {
            let tag = batch[i]; i += 1
            if tag == 1 {
                guard let kl = varint(batch, &i), i + kl <= batch.count else { break }
                let key = Array(batch[i..<i + kl]); i += kl
                guard let vl = varint(batch, &i), i + vl <= batch.count else { break }
                let value = Array(batch[i..<i + vl]); i += vl
                out.append((key, value))
            } else if tag == 0 {
                guard let kl = varint(batch, &i), i + kl <= batch.count else { break }
                let key = Array(batch[i..<i + kl]); i += kl
                out.append((key, nil))
            } else {
                break
            }
        }
        return out
    }

    /// Chromium stores a string with a one-byte prefix: 0 = UTF-16LE, 1 = Latin-1/UTF-8. Keys often have no prefix.
    static func decodeString(_ bytes: ArraySlice<UInt8>) -> String {
        guard let first = bytes.first else { return "" }
        let rest = Array(bytes.dropFirst())
        if first == 0x00 {
            var scalars = ""
            var i = 0
            while i + 1 < rest.count + 1 && i + 1 <= rest.count {
                if i + 1 >= rest.count { break }
                let code = UInt16(rest[i]) | (UInt16(rest[i + 1]) << 8)
                scalars.unicodeScalars.append(UnicodeScalar(code) ?? UnicodeScalar(0xFFFD)!)
                i += 2
            }
            return scalars
        }
        if first == 0x01 {
            return String(bytes: rest, encoding: .isoLatin1) ?? String(decoding: rest, as: UTF8.self)
        }
        return String(decoding: Array(bytes), as: UTF8.self)
    }

    /// Reads one browser profile's `Local Storage/leveldb` folder into `origin → entries`.
    static func read(_ folder: URL) -> [String: [Entry]] {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var map: [String: [String: String]] = [:]

        func applyKey(_ key: [UInt8], _ value: [UInt8]?) {
            guard key.first == 0x5F, let nul = key.dropFirst().firstIndex(of: 0x00) else { return }   // "_origin\0key"
            let origin = String(decoding: Array(key[1..<nul]), as: UTF8.self)
            guard origin.contains("://") else { return }
            let scriptKey = decodeString(key[(nul + 1)...])
            if let value = value {
                map[origin, default: [:]][scriptKey] = decodeString(value[...])
            } else {
                map[origin]?[scriptKey] = nil
            }
        }

        // The .log files hold the newest writes, applied in order.
        for url in files.filter({ $0.pathExtension == "log" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let data = try? Data(contentsOf: url) else { continue }
            for batch in logRecords(data) {
                for (key, value) in batchEntries(batch) { applyKey(key, value) }
            }
        }
        // Older, compacted data lives in .ldb files; pull readable "_origin\0key…value" runs we don't already have.
        for url in files.filter({ $0.pathExtension == "ldb" || $0.pathExtension == "sst" }) {
            guard let data = try? Data(contentsOf: url) else { continue }
            heuristicScan([UInt8](data)) { origin, key, value in
                if map[origin]?[key] == nil { map[origin, default: [:]][key] = value }
            }
        }

        var result: [String: [Entry]] = [:]
        for (origin, pairs) in map {
            result[origin] = pairs.sorted { $0.key < $1.key }.map { Entry(key: $0.key, value: $0.value) }
        }
        return result
    }

    /// A light scan for `_https://…\0key` + value runs in compacted (possibly uncompressed) blocks.
    private static func heuristicScan(_ bytes: [UInt8], _ found: (String, String, String) -> Void) {
        var i = 0
        while i < bytes.count {
            if bytes[i] == 0x5F, i + 8 < bytes.count,
               bytes[i + 1] == 0x68, bytes[i + 2] == 0x74, bytes[i + 3] == 0x74, bytes[i + 4] == 0x70 {   // "_http"
                var j = i + 1
                while j < bytes.count, bytes[j] != 0x00, (32...126).contains(bytes[j]) { j += 1 }
                guard j < bytes.count, bytes[j] == 0x00 else { i += 1; continue }
                let origin = String(decoding: Array(bytes[(i + 1)..<j]), as: UTF8.self)
                var k = j + 1
                while k < bytes.count, (32...126).contains(bytes[k]) { k += 1 }
                let key = String(decoding: Array(bytes[(j + 1)..<k]), as: UTF8.self)
                var v = k
                while v < bytes.count, bytes[v] == 0x00 || bytes[v] == 0x01 { v += 1 }
                var e = v
                while e < bytes.count, (32...126).contains(bytes[e]) { e += 1 }
                let value = String(decoding: Array(bytes[v..<e]), as: UTF8.self)
                if origin.contains("://") && !key.isEmpty { found(origin, key, value) }
                i = max(e, i + 1)
            } else {
                i += 1
            }
        }
    }

    /// A console snippet that applies the user's edits on the real site, safely, in any browser.
    static func applyScript(origin: String, entries: [Entry], removed: [String]) -> String {
        func jsString(_ text: String) -> String {
            guard let data = try? JSONSerialization.data(withJSONObject: [text]),
                  let json = String(data: data, encoding: .utf8) else { return "\"\"" }
            return String(json.dropFirst().dropLast())   // the array's single quoted element
        }
        var lines = ["// Open \(origin) in your browser, open the DevTools Console (⌥⌘I), paste this and press Return:"]
        for key in removed { lines.append("localStorage.removeItem(\(jsString(key)));") }
        for entry in entries { lines.append("localStorage.setItem(\(jsString(entry.key)), \(jsString(entry.value)));") }
        lines.append("location.reload();")
        return lines.joined(separator: "\n")
    }
}

// MARK: - Browser discovery

struct BrowserProfile: Identifiable, Hashable {
    let id = UUID()
    let browser: String
    let profile: String
    let folder: URL
    var label: String { profile.isEmpty ? browser : "\(browser) – \(profile)" }
}

enum BrowserCatalog {
    /// name → the folder under Application Support that holds the profiles.
    private static let chromium: [(String, String)] = [
        ("Google Chrome", "Google/Chrome"),
        ("Chrome Beta", "Google/Chrome Beta"),
        ("Chrome Canary", "Google/Chrome Canary"),
        ("Chromium", "Chromium"),
        ("Microsoft Edge", "Microsoft Edge"),
        ("Brave", "BraveSoftware/Brave-Browser"),
        ("Vivaldi", "Vivaldi"),
        ("Opera", "com.operasoftware.Opera"),
        ("Arc", "Arc/User Data"),
    ]

    static func discover() -> [BrowserProfile] {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        var out: [BrowserProfile] = []
        for (name, path) in chromium {
            let base = support.appendingPathComponent(path)
            guard fm.fileExists(atPath: base.path) else { continue }
            // A browser keeps either one store (Opera) or one per profile folder (Default, Profile 1…).
            let direct = base.appendingPathComponent("Local Storage/leveldb")
            if fm.fileExists(atPath: direct.path) {
                out.append(BrowserProfile(browser: name, profile: "", folder: direct))
            }
            let subdirs = (try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            for sub in subdirs {
                let leveldb = sub.appendingPathComponent("Local Storage/leveldb")
                if fm.fileExists(atPath: leveldb.path) {
                    out.append(BrowserProfile(browser: name, profile: sub.lastPathComponent, folder: leveldb))
                }
            }
        }
        return out.sorted { $0.label < $1.label }
    }

    /// Whether a browser with this name is running (so we can warn that its on-disk data may be out of date).
    static func isRunning(_ browser: String) -> Bool {
        let names = NSWorkspace.shared.runningApplications.compactMap { $0.localizedName?.lowercased() }
        let needle = browser.lowercased().replacingOccurrences(of: " beta", with: "").replacingOccurrences(of: " canary", with: "")
        return names.contains { $0.contains(needle) || (needle == "google chrome" && $0.contains("chrome")) }
    }
}

// MARK: - View

struct LocalStorageEditorView: View {
    @State private var profiles: [BrowserProfile] = []
    @State private var selectedProfile: BrowserProfile?
    @State private var stores: [String: [ChromiumLocalStorage.Entry]] = [:]
    @State private var manualOrigin = ""
    @State private var selectedOrigin: String?
    @State private var entries: [ChromiumLocalStorage.Entry] = []
    @State private var removed: [String] = []
    @State private var search = ""
    @State private var loading = false
    @State private var note = ""

    var body: some View {
        ToolPage(tool: .localStorage) {
            Card(title: "Browser", icon: "globe") {
                HStack {
                    if profiles.isEmpty {
                        Text(loading ? "Looking for browsers…" : "No Chrome-family browser data found.")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Profile", selection: Binding(
                            get: { selectedProfile },
                            set: { if let p = $0 { choose(p) } }
                        )) {
                            ForEach(profiles) { profile in
                                Text(profile.label).tag(Optional(profile))
                            }
                        }
                        .frame(maxWidth: 360)
                    }
                    Button("Rescan") { discover() }
                    Spacer()
                }
                if let profile = selectedProfile, BrowserCatalog.isRunning(profile.browser) {
                    Label("\(profile.browser) is open – quit it to see the very latest values, and before anything you paste back takes effect cleanly.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
                Text("Reads localStorage from Chrome, Edge, Brave, Arc, Opera, Vivaldi and Chromium. Safari and Firefox: use “Any website” below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .top, spacing: 12) {
                originList
                    .frame(width: 280)
                editor
            }
        }
        .onAppear { if profiles.isEmpty { discover() } }
    }

    private var origins: [String] {
        let all = stores.keys.sorted()
        guard !search.trimmed.isEmpty else { return all }
        return all.filter { $0.localizedCaseInsensitiveContains(search.trimmed) }
    }

    private var originList: some View {
        Card(title: "Websites", icon: "list.bullet") {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter", text: $search).textFieldStyle(.plain)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(origins, id: \.self) { origin in
                        Button {
                            choose(origin: origin)
                        } label: {
                            HStack {
                                Text(origin).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text("\(stores[origin]?.count ?? 0)").foregroundStyle(.secondary).font(.caption)
                            }
                            .padding(.horizontal, 6).padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 6).fill(selectedOrigin == origin ? Color.accentColor.opacity(0.18) : .clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .font(.callout)
                    }
                }
            }
            .frame(minHeight: 260, maxHeight: 420)
            Divider()
            Text("Any website").font(.caption.bold()).foregroundStyle(.secondary)
            HStack {
                TextField("https://example.com", text: $manualOrigin)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(openManual)
                Button("Open", action: openManual)
                    .disabled(URL(string: manualOrigin)?.host == nil)
            }
            .help("Edit any site's storage (including Safari and Firefox) and apply it from the console.")
        }
    }

    @ViewBuilder
    private var editor: some View {
        if let origin = selectedOrigin {
            Card(title: origin, icon: "key") {
                HStack {
                    Text("\(entries.count) item\(entries.count == 1 ? "" : "s")").foregroundStyle(.secondary).font(.caption)
                    Spacer()
                    Button { entries.append(.init(key: "newKey", value: "")) } label: { Label("Add", systemImage: "plus") }
                    Button("Reload") { choose(origin: origin) }
                        .disabled(stores[origin] == nil)
                }
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach($entries) { $entry in
                            VStack(spacing: 3) {
                                HStack {
                                    TextField("key", text: $entry.key)
                                        .textFieldStyle(.roundedBorder)
                                        .font(.system(.callout, design: .monospaced))
                                    Button {
                                        removed.append(entry.key)
                                        entries.removeAll { $0.id == entry.id }
                                    } label: { Image(systemName: "trash") }
                                        .buttonStyle(.borderless)
                                }
                                TextField("value", text: $entry.value, axis: .vertical)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(.callout, design: .monospaced))
                                    .lineLimit(1...6)
                            }
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
                        }
                    }
                }
                .frame(minHeight: 240, maxHeight: 460)
                Divider()
                HStack {
                    Button {
                        apply()
                    } label: {
                        Label("Apply in Browser…", systemImage: "arrow.up.forward.app")
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Copy Apply Script") {
                        ClipboardHelper.copy(ChromiumLocalStorage.applyScript(origin: origin, entries: entries, removed: removed))
                        note = "Script copied. Paste it into the site's DevTools Console."
                    }
                    Button("Copy as JSON") {
                        let dict = Dictionary(entries.map { ($0.key, $0.value) }, uniquingKeysWith: { a, _ in a })
                        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]) {
                            ClipboardHelper.copy(String(decoding: data, as: UTF8.self))
                        }
                    }
                    Spacer()
                }
                Text("“Apply in Browser” copies a short script and opens the site. Paste it into the DevTools Console (⌥⌘I) and press Return – that's the safe way to change a site's storage, and it works in every browser. MacTools never writes to the browser's files.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !note.isEmpty {
                    Label(note, systemImage: "checkmark.circle").font(.caption).foregroundColor(.green)
                }
            }
        } else {
            Card(title: "Local Storage", icon: "key") {
                Text("Pick a website on the left to see and edit what it has saved in your browser, or type any site under “Any website”.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 30)
            }
        }
    }

    private func discover() {
        loading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let found = BrowserCatalog.discover()
            DispatchQueue.main.async {
                profiles = found
                loading = false
                if selectedProfile == nil, let first = found.first { choose(first) }
            }
        }
    }

    private func choose(_ profile: BrowserProfile) {
        selectedProfile = profile
        selectedOrigin = nil
        entries = []
        removed = []
        loading = true
        let folder = profile.folder
        DispatchQueue.global(qos: .userInitiated).async {
            let data = ChromiumLocalStorage.read(folder)
            DispatchQueue.main.async {
                stores = data
                loading = false
            }
        }
    }

    private func choose(origin: String) {
        selectedOrigin = origin
        entries = stores[origin] ?? []
        removed = []
        note = ""
    }

    private func openManual() {
        guard let url = URL(string: manualOrigin), let host = url.host else { return }
        let origin = "\(url.scheme ?? "https")://\(host)" + (url.port.map { ":\($0)" } ?? "")
        if stores[origin] == nil { stores[origin] = [] }
        choose(origin: origin)
    }

    private func apply() {
        guard let origin = selectedOrigin else { return }
        ClipboardHelper.copy(ChromiumLocalStorage.applyScript(origin: origin, entries: entries, removed: removed))
        if let url = URL(string: origin) { NSWorkspace.shared.open(url) }
        note = "Opened \(origin) and copied the script. Open the Console (⌥⌘I), paste and press Return."
    }
}
