import SwiftUI
import AppKit

struct ScreenshotSettings: Codable, Equatable {
    enum Mode: String, Codable, CaseIterable, Identifiable {
        case fullScreen, selection, window
        var id: String { rawValue }
        var title: String {
            switch self {
            case .fullScreen: return "Full Screen"
            case .selection: return "Selection"
            case .window: return "Window"
            }
        }
        var icon: String {
            switch self {
            case .fullScreen: return "display"
            case .selection: return "crop"
            case .window: return "macwindow"
            }
        }
    }

    var mode: Mode = .selection
    var delay: Int = 0
    var toClipboard = false
    var format = "png"
    var folder = (NSHomeDirectory() as NSString).appendingPathComponent("Desktop")
    var showCursor = false
    var playSound = true
    var hideMacTools = true
    var windowShadow = true
}

struct ScreenshotView: View {
    @State private var settings = Prefs.load("screenshotSettings", default: ScreenshotSettings())
    @State private var lastImage: NSImage?
    @State private var lastURL: URL?
    @State private var busy = false
    @State private var status = ""

    var body: some View {
        ToolPage(tool: .screenshot) {
            PermissionBanner(needs: [.screenRecording])

            Card(title: "Capture", icon: "camera.viewfinder") {
                HStack(spacing: 10) {
                    ForEach(ScreenshotSettings.Mode.allCases) { mode in
                        Button {
                            settings.mode = mode
                            capture()
                        } label: {
                            VStack(spacing: 6) {
                                Image(systemName: mode.icon).font(.title)
                                Text(mode.title)
                            }
                            .frame(width: 120, height: 70)
                        }
                        .buttonStyle(TileButtonStyle())
                        .disabled(busy)
                    }
                    Spacer()
                    if busy { ProgressView().controlSize(.small) }
                    Text(status).foregroundStyle(.secondary)
                }
                Text("Selection: drag to choose an area (press Space to switch to window mode, Esc cancels).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Card(title: "Options", icon: "slider.horizontal.3") {
                HStack(spacing: 20) {
                    Picker("Delay", selection: $settings.delay) {
                        Text("None").tag(0)
                        Text("3 s").tag(3)
                        Text("5 s").tag(5)
                        Text("10 s").tag(10)
                    }
                    .frame(width: 160)
                    Picker("Format", selection: $settings.format) {
                        Text("PNG").tag("png")
                        Text("JPEG").tag("jpg")
                        Text("HEIC").tag("heic")
                        Text("PDF").tag("pdf")
                        Text("TIFF").tag("tiff")
                    }
                    .frame(width: 160)
                }
                Toggle("Copy to clipboard instead of saving a file", isOn: $settings.toClipboard)
                if !settings.toClipboard {
                    HStack {
                        Text("Save to:")
                        Text(settings.folder).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Button("Change…") {
                            if let url = Panels.chooseFolder() { settings.folder = url.path }
                        }
                        Button("Open Folder") { NSWorkspace.shared.open(URL(fileURLWithPath: settings.folder)) }
                    }
                }
                HStack(spacing: 20) {
                    Toggle("Include mouse pointer", isOn: $settings.showCursor)
                    Toggle("Shutter sound", isOn: $settings.playSound)
                    Toggle("Window shadow", isOn: $settings.windowShadow)
                    Toggle("Hide MacTools while capturing", isOn: $settings.hideMacTools)
                }
                Button("Open macOS Screenshot Toolbar (also records video)") {
                    Shell.run("open -a Screenshot")
                }
            }

            if let image = lastImage {
                Card(title: "Last Capture", icon: "photo") {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 300)
                        .frame(maxWidth: .infinity)
                    HStack {
                        Button("Copy Image") { ClipboardHelper.copy(image: image) }
                        if let url = lastURL {
                            Button("Open") { NSWorkspace.shared.open(url) }
                            Button("Show in Finder") { Panels.reveal(url) }
                        }
                    }
                }
            }
        }
        .onChange(of: settings) { newValue in
            Prefs.save("screenshotSettings", newValue)
        }
    }

    private func capture() {
        let s = settings
        var args: [String] = []
        if !s.playSound { args.append("-x") }
        if s.toClipboard { args.append("-c") }
        if !s.windowShadow { args.append("-o") }
        switch s.mode {
        case .fullScreen:
            if s.showCursor { args.append("-C") }
        case .selection:
            args.append("-i")
        case .window:
            args += ["-i", "-W"]
        }
        if s.delay > 0 { args += ["-T", "\(s.delay)"] }
        args += ["-t", s.format]
        var fileURL: URL?
        if !s.toClipboard {
            let name = "Screenshot \(Format.timestamp.string(from: Date())).\(s.format)"
            let url = URL(fileURLWithPath: s.folder).appendingPathComponent(name)
            fileURL = url
            args.append(url.path)
        }
        busy = true
        status = s.delay > 0 ? "Capturing in \(s.delay)s…" : "Capturing…"
        let hide = s.hideMacTools && s.mode == .fullScreen
        if hide { NSApp.hide(nil) }
        let captureArgs = args
        let destination = fileURL
        DispatchQueue.global(qos: .userInitiated).async {
            if hide { Thread.sleep(forTimeInterval: 0.4) }
            let result = Shell.runSync("/usr/sbin/screencapture", captureArgs)
            DispatchQueue.main.async {
                busy = false
                if hide { NSApp.unhide(nil) }
                if let url = destination {
                    if FileManager.default.fileExists(atPath: url.path) {
                        lastURL = url
                        lastImage = NSImage(contentsOf: url)
                        status = "Saved \(url.lastPathComponent)"
                    } else {
                        status = result.succeeded ? "Cancelled" : result.combined
                    }
                } else {
                    let pb = NSPasteboard.general
                    if let images = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage], let image = images.first {
                        lastImage = image
                        lastURL = nil
                        status = "Copied to clipboard"
                    } else {
                        status = "Cancelled"
                    }
                }
            }
        }
    }
}
