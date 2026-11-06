import SwiftUI
import AppKit

enum CRXError: Error, LocalizedError {
    case badID
    case notCRX
    case download(Int)
    case unzip(String)

    var errorDescription: String? {
        switch self {
        case .badID: return "Paste a Chrome Web Store link or a 32-letter extension ID."
        case .notCRX: return "That file isn't a Chrome extension (.crx or .zip)."
        case .download(let code): return "Downloading the extension failed (HTTP \(code)). It may have been removed from the store."
        case .unzip(let detail): return "Couldn't unpack the extension. \(detail)"
        }
    }
}

enum CRX {
    /// Finds the extension ID in a Web Store URL or a bare ID (IDs use only the letters a–p).
    static func extensionID(from text: String) -> String? {
        guard let range = text.lowercased().range(of: "[a-p]{32}", options: .regularExpression) else { return nil }
        return String(text.lowercased()[range])
    }

    /// Strips the CRX2/CRX3 header and returns the zip archive inside. Plain zips pass through.
    static func zipData(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        func u32(_ at: Int) -> Int {
            guard at + 4 <= bytes.count else { return -1 }
            return Int(bytes[at]) | Int(bytes[at + 1]) << 8 | Int(bytes[at + 2]) << 16 | Int(bytes[at + 3]) << 24
        }
        if bytes.starts(with: [0x50, 0x4B]) { return data }
        guard bytes.starts(with: Array("Cr24".utf8)) else { throw CRXError.notCRX }
        let start: Int
        switch u32(4) {
        case 2: start = 16 + u32(8) + u32(12)    // public key + signature
        case 3: start = 12 + u32(8)              // protobuf header
        default: throw CRXError.notCRX
        }
        guard start > 0, start < bytes.count, bytes[start] == 0x50, bytes[start + 1] == 0x4B else { throw CRXError.notCRX }
        return data.subdata(in: start..<data.count)
    }

    static func downloadURL(id: String) -> URL? {
        URL(string: "https://clients2.google.com/service/update2/crx?response=redirect&prodversion=130.0&acceptformat=crx2,crx3&x=id%3D\(id)%26uc")
    }
}

struct ChromeExtensionViewerView: View {
    @State private var input = ""
    @State private var folder: URL?
    @State private var files: [String] = []
    @State private var selected: String?
    @State private var content = ""
    @State private var filter = ""
    @State private var status = ""
    @State private var busy = false
    // shortcut: very large files are cut off so the text view stays responsive; add paging if needed.
    private let maxShown = 400_000

    var body: some View {
        ToolPage(tool: .chromeExtensionViewer) {
            Card(title: "Extension", icon: "puzzlepiece.extension") {
                HStack {
                    TextField("Chrome Web Store link or extension ID", text: $input)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(download)
                    Button("Download") { download() }
                        .disabled(busy || input.trimmed.isEmpty)
                    Button("Open .crx / .zip…") {
                        if let url = Panels.chooseFiles(multiple: false).first { openLocal(url) }
                    }
                    .disabled(busy)
                }
                HStack {
                    if busy { ProgressView().controlSize(.small) }
                    Text(status).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if let folder = folder {
                        Button("Show in Finder") { Panels.reveal(folder) }
                    }
                }
            }
            .acceptsFileDrops { urls in if let url = urls.first { openLocal(url) } }

            if !files.isEmpty {
                Card(title: "Source Code (\(files.count) files)", icon: "chevron.left.forwardslash.chevron.right") {
                    HStack(alignment: .top, spacing: 10) {
                        VStack(spacing: 6) {
                            TextField("Filter files", text: $filter).textFieldStyle(.roundedBorder)
                            List(shownFiles, id: \.self, selection: $selected) { Text($0).lineLimit(1) }
                                .frame(minHeight: 420)
                        }
                        .frame(width: 260)
                        VStack(alignment: .leading, spacing: 6) {
                            OutputBox(text: content, minHeight: 420, maxHeight: 700)
                            if !content.isEmpty { CopyButton(text: content) }
                        }
                    }
                }
            }
        }
        .onChange(of: selected) { _ in loadSelected() }
    }

    private var shownFiles: [String] {
        filter.trimmed.isEmpty ? files : files.filter { $0.localizedCaseInsensitiveContains(filter.trimmed) }
    }

    private func download() {
        guard let id = CRX.extensionID(from: input), let url = CRX.downloadURL(id: id) else {
            status = CRXError.badID.errorDescription ?? ""
            return
        }
        start("Downloading \(id)…")
        URLSession.shared.dataTask(with: url) { data, response, error in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let result = Result<URL, Error> {
                if let error = error { throw error }
                guard code == 200, let data = data, !data.isEmpty else { throw CRXError.download(code) }
                return try unpack(data, name: id)
            }
            DispatchQueue.main.async { finish(result) }
        }.resume()
    }

    private func openLocal(_ url: URL) {
        start("Opening \(url.lastPathComponent)…")
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result<URL, Error> {
                try unpack(try Data(contentsOf: url), name: url.deletingPathExtension().lastPathComponent)
            }
            DispatchQueue.main.async { finish(result) }
        }
    }

    /// Writes the zip inside the CRX to disk and extracts it to Application Support/MacTools/ChromeExtensions/<name>.
    private func unpack(_ data: Data, name: String) throws -> URL {
        let fm = FileManager.default
        let zip = fm.temporaryDirectory.appendingPathComponent("crx-\(UUID().uuidString).zip")
        try CRX.zipData(data).write(to: zip)
        defer { try? fm.removeItem(at: zip) }
        let dest = DataStore.directory.appendingPathComponent("ChromeExtensions/\(name)", isDirectory: true)
        try? fm.removeItem(at: dest)
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        let result = Shell.runSync("/usr/bin/ditto", ["-x", "-k", zip.path, dest.path])
        guard result.succeeded else { throw CRXError.unzip(result.combined) }
        return dest
    }

    private func start(_ message: String) {
        busy = true
        status = message
        files = []
        selected = nil
        content = ""
    }

    private func finish(_ result: Result<URL, Error>) {
        busy = false
        switch result {
        case .success(let dir):
            folder = dir
            let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey])
            files = (enumerator?.allObjects as? [URL] ?? [])
                .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
                .map { String($0.standardizedFileURL.path.dropFirst(dir.standardizedFileURL.path.count + 1)) }
                .sorted()
            let manifest = (try? Data(contentsOf: dir.appendingPathComponent("manifest.json")))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let title = [manifest?["name"] as? String, manifest?["version"] as? String].compactMap { $0 }.joined(separator: " ")
            status = "\(title.isEmpty ? dir.lastPathComponent : title) · saved to \(dir.path)"
            selected = files.contains("manifest.json") ? "manifest.json" : files.first
        case .failure(let error):
            status = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func loadSelected() {
        guard let folder = folder, let file = selected,
              let data = try? Data(contentsOf: folder.appendingPathComponent(file)) else { content = ""; return }
        if data.prefix(8000).contains(0) {
            content = "Binary file (\(Format.bytes(Int64(data.count)))) – use Show in Finder to open it."
            return
        }
        let text = String(decoding: data.prefix(maxShown), as: UTF8.self)
        content = data.count > maxShown ? text + "\n\n… cut off (file is \(Format.bytes(Int64(data.count))))" : text
    }
}
