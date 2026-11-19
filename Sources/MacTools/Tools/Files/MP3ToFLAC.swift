import SwiftUI
import UniformTypeIdentifiers

struct MP3ToFLACView: View {
    @State private var files: [URL] = []
    @State private var outputFolder: URL?
    @State private var log = ""
    @State private var working = false
    @State private var done = 0

    var body: some View {
        ToolPage(tool: .mp3ToFlac) {
            Card(title: "MP3 Files", icon: "music.note.list") {
                HStack {
                    Button("Add MP3s…") { add(Panels.chooseFiles(multiple: true, types: [.mp3])) }
                    Button("Add Folder…") { if let folder = Panels.chooseFolder() { add([folder]) } }
                    Button("Clear") { files = [] }.disabled(working)
                    Spacer()
                    Text("\(files.count) files").foregroundStyle(.secondary)
                }
                if files.isEmpty {
                    Text("Add MP3 files or folders, or drop them here.").foregroundStyle(.secondary)
                } else {
                    OutputBox(text: files.map(\.lastPathComponent).joined(separator: "\n"), minHeight: 40, maxHeight: 160)
                }
            }
            .acceptsFileDrops { add($0) }

            Card(title: "Convert", icon: "waveform") {
                Text("Encodes lossless 24-bit FLAC and copies the title, artist, album, track numbers, year, genre, lyrics, cover art and other tags. FLAC can't restore what MP3 compression already removed — it stores the MP3's sound exactly, without losing any more.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Text("Save to:")
                    Text(outputFolder?.path ?? "Same folder as each MP3").foregroundStyle(.secondary).lineLimit(1)
                    Button("Choose…") { outputFolder = Panels.chooseFolder() }
                    if outputFolder != nil { Button("Reset") { outputFolder = nil } }
                }
                HStack {
                    Button {
                        convert()
                    } label: {
                        Label("Convert \(files.count) Files", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(files.isEmpty || working)
                    if working {
                        ProgressView(value: Double(done), total: Double(files.count)).frame(width: 160)
                        Text("\(done)/\(files.count)").monospacedDigit()
                    }
                }
            }

            if !log.isEmpty {
                Card(title: "Log", icon: "list.bullet.rectangle") {
                    OutputBox(text: log, minHeight: 60, maxHeight: 220)
                }
            }
        }
    }

    private func add(_ urls: [URL]) {
        var found: [URL] = []
        for url in urls {
            if url.hasDirectoryPath, let items = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) {
                found += items.compactMap { $0 as? URL }.filter { $0.pathExtension.lowercased() == "mp3" }
            } else if url.pathExtension.lowercased() == "mp3" {
                found.append(url)
            }
        }
        let existing = Set(files)
        files += found.filter { !existing.contains($0) }.sorted { $0.path < $1.path }
    }

    private func convert() {
        working = true
        done = 0
        log = ""
        let list = files
        let folder = outputFolder
        Task {
            for url in list {
                let dir = folder ?? url.deletingLastPathComponent()
                let name = url.deletingPathExtension().lastPathComponent
                var out = dir.appendingPathComponent(name).appendingPathExtension("flac")
                var n = 2
                while FileManager.default.fileExists(atPath: out.path) {
                    out = dir.appendingPathComponent("\(name) \(n)").appendingPathExtension("flac")
                    n += 1
                }
                do {
                    try await FLACConverter.convert(url, to: out)
                    log += "✓ \(url.lastPathComponent) → \(out.lastPathComponent)\n"
                } catch {
                    log += "✗ \(url.lastPathComponent): \(error.localizedDescription)\n"
                }
                done += 1
            }
            working = false
        }
    }
}
