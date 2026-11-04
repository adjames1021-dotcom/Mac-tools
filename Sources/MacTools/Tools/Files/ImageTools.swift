import SwiftUI
import AppKit
import PDFKit
import UniformTypeIdentifiers

struct ImageToolsView: View {
    @State private var images: [URL] = []
    @State private var format = "jpeg"
    @State private var quality = 80.0
    @State private var resize = false
    @State private var maxSize = 1600
    @State private var rotate = 0
    @State private var flip = "none"
    @State private var outputFolder: URL?
    @State private var suffix = "-converted"
    @State private var log = ""
    @State private var working = false

    private let formats: [(String, String)] = [("jpeg", "JPEG"), ("png", "PNG"), ("heic", "HEIC"), ("tiff", "TIFF"), ("gif", "GIF"), ("bmp", "BMP"), ("pdf", "PDF")]

    var body: some View {
        ToolPage(tool: .imageTools) {
            Card(title: "Images", icon: "photo.on.rectangle") {
                HStack {
                    Button("Add Images…") { add(Panels.chooseFiles(multiple: true, types: [.image])) }
                    Button("Clear") { images = [] }
                    Spacer()
                    Text("\(images.count) images").foregroundStyle(.secondary)
                }
                if images.isEmpty {
                    Text("Add images or drop them here.").foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 8)], spacing: 8) {
                    ForEach(images, id: \.self) { url in
                        VStack(spacing: 4) {
                            if let img = NSImage(contentsOf: url) {
                                Image(nsImage: img).resizable().scaledToFit().frame(height: 70)
                                Text(dimensions(img)).font(.caption2).foregroundStyle(.secondary)
                            }
                            Text(url.lastPathComponent).font(.caption).lineLimit(1).truncationMode(.middle)
                        }
                        .frame(width: 110)
                        .contextMenu {
                            Button("Remove") { images.removeAll { $0 == url } }
                            Button("Show in Finder") { Panels.reveal(url) }
                        }
                    }
                }
            }
            .acceptsFileDrops { add($0) }

            Card(title: "Convert & Resize", icon: "arrow.triangle.2.circlepath") {
                HStack(spacing: 16) {
                    Picker("Format", selection: $format) {
                        ForEach(formats, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    .frame(width: 180)
                    if format == "jpeg" || format == "heic" {
                        Text("Quality")
                        Slider(value: $quality, in: 10...100, step: 5).frame(width: 160)
                        Text("\(Int(quality))%").monospacedDigit()
                    }
                }
                HStack(spacing: 16) {
                    Toggle("Resize so the longest side is", isOn: $resize)
                    IntField(title: "", value: $maxSize, unit: "px").disabled(!resize)
                }
                HStack(spacing: 16) {
                    Picker("Rotate", selection: $rotate) {
                        Text("None").tag(0)
                        Text("90° right").tag(90)
                        Text("180°").tag(180)
                        Text("90° left").tag(270)
                    }
                    .frame(width: 200)
                    Picker("Flip", selection: $flip) {
                        Text("None").tag("none")
                        Text("Horizontal").tag("horizontal")
                        Text("Vertical").tag("vertical")
                    }
                    .frame(width: 200)
                }
                HStack {
                    Text("Save to:")
                    Text(outputFolder?.path ?? "Same folder as each image").foregroundStyle(.secondary).lineLimit(1)
                    Button("Choose…") { outputFolder = Panels.chooseFolder() }
                    if outputFolder != nil { Button("Reset") { outputFolder = nil } }
                    TextField("Name suffix", text: $suffix).textFieldStyle(.roundedBorder).frame(width: 140)
                }
                HStack {
                    Button {
                        convert()
                    } label: {
                        Label("Convert \(images.count) Images", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(images.isEmpty || working)
                    Button("Combine into PDF…") { combinePDF() }
                        .disabled(images.isEmpty || working)
                    if working { ProgressView().controlSize(.small) }
                }
            }

            if !log.isEmpty {
                Card(title: "Log", icon: "list.bullet.rectangle") {
                    OutputBox(text: log, minHeight: 60, maxHeight: 220)
                }
            }
        }
    }

    private func dimensions(_ image: NSImage) -> String {
        if let rep = image.representations.first, rep.pixelsWide > 0 {
            return "\(rep.pixelsWide)×\(rep.pixelsHigh)"
        }
        return "\(Int(image.size.width))×\(Int(image.size.height))"
    }

    private func add(_ urls: [URL]) {
        let existing = Set(images)
        images += urls.filter { !existing.contains($0) }
    }

    private func convert() {
        working = true
        log = ""
        let list = images
        let fmt = format
        let q = Int(quality)
        let doResize = resize
        let size = maxSize
        let rot = rotate
        let flipMode = flip
        let folder = outputFolder
        let nameSuffix = suffix
        DispatchQueue.global(qos: .userInitiated).async {
            var lines: [String] = []
            for url in list {
                let ext = fmt == "jpeg" ? "jpg" : fmt
                let dir = folder ?? url.deletingLastPathComponent()
                var out = dir.appendingPathComponent(url.deletingPathExtension().lastPathComponent + nameSuffix).appendingPathExtension(ext)
                var n = 2
                while FileManager.default.fileExists(atPath: out.path) {
                    out = dir.appendingPathComponent(url.deletingPathExtension().lastPathComponent + nameSuffix + " \(n)").appendingPathExtension(ext)
                    n += 1
                }
                var args = ["-s", "format", fmt]
                if fmt == "jpeg" || fmt == "heic" { args += ["-s", "formatOptions", "\(q)"] }
                if doResize { args += ["-Z", "\(size)"] }
                if rot != 0 { args += ["-r", "\(rot)"] }
                if flipMode != "none" { args += ["-f", flipMode] }
                args += [url.path, "--out", out.path]
                let result = Shell.runSync("/usr/bin/sips", args)
                if result.succeeded && FileManager.default.fileExists(atPath: out.path) {
                    lines.append("✓ \(url.lastPathComponent) → \(out.lastPathComponent)")
                } else {
                    lines.append("✗ \(url.lastPathComponent): \(result.combined)")
                }
            }
            let text = lines.joined(separator: "\n")
            DispatchQueue.main.async {
                log = text
                working = false
            }
        }
    }

    private func combinePDF() {
        guard let url = Panels.saveFile(name: "Combined.pdf", types: [.pdf]) else { return }
        let document = PDFDocument()
        var added = 0
        for imageURL in images {
            if let image = NSImage(contentsOf: imageURL), let page = PDFPage(image: image) {
                document.insert(page, at: document.pageCount)
                added += 1
            }
        }
        if document.write(to: url) {
            log = "Created \(url.lastPathComponent) with \(added) pages."
            Panels.reveal(url)
        } else {
            log = "Couldn't write the PDF."
        }
    }
}
