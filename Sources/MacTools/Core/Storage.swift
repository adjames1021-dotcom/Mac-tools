import Foundation
import AppKit
import UniformTypeIdentifiers

/// JSON files stored in ~/Library/Application Support/MacTools
enum DataStore {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("MacTools", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func url(_ name: String) -> URL { directory.appendingPathComponent(name) }

    static func load<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        guard let data = try? Data(contentsOf: url(name)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(T.self, from: data)
    }

    static func save<T: Encodable>(_ value: T, to name: String) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(value) {
            try? data.write(to: url(name), options: .atomic)
        }
    }
}

/// Small Codable settings structs stored in UserDefaults.
enum Prefs {
    static func load<T: Decodable>(_ key: String, default value: T) -> T {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode(T.self, from: data) else { return value }
        return decoded
    }

    static func save<T: Encodable>(_ key: String, _ value: T) {
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

/// Thread-safe cancellation flag used by background automation loops.
final class CancelToken {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    /// Sleeps for `seconds`, waking early if cancelled. Returns false when cancelled.
    @discardableResult
    func pause(_ seconds: Double) -> Bool {
        let end = ProcessInfo.processInfo.systemUptime + max(0, seconds)
        while true {
            if isCancelled { return false }
            let remaining = end - ProcessInfo.processInfo.systemUptime
            if remaining <= 0 { return true }
            Thread.sleep(forTimeInterval: min(remaining, 0.02))
        }
    }
}

enum ClipboardHelper {
    static func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    static func copy(image: NSImage) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([image])
    }

    static var string: String? { NSPasteboard.general.string(forType: .string) }
}

enum Panels {
    static func chooseFolder(message: String = "Choose a folder") -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = message
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseFiles(multiple: Bool = true, types: [UTType]? = nil, directories: Bool = false, message: String = "") -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = directories
        panel.allowsMultipleSelection = multiple
        if let types = types { panel.allowedContentTypes = types }
        if !message.isEmpty { panel.message = message }
        return panel.runModal() == .OK ? panel.urls : []
    }

    static func saveFile(name: String, types: [UTType] = []) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        if !types.isEmpty { panel.allowedContentTypes = types }
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

enum Format {
    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func duration(_ seconds: Double, showFraction: Bool = true) -> String {
        let total = max(0, seconds)
        let h = Int(total) / 3600
        let m = (Int(total) % 3600) / 60
        let s = Int(total) % 60
        let cs = Int((total - floor(total)) * 100)
        var out = h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
        if showFraction { out += String(format: ".%02d", cs) }
        return out
    }

    static func number(_ value: Double, maxFraction: Int = 6) -> String {
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value > 0 ? "∞" : "-∞" }
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = maxFraction
        f.usesGroupingSeparator = false
        if abs(value) >= 1e15 || (abs(value) < 1e-6 && value != 0) {
            return String(format: "%g", value)
        }
        return f.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    static let timestamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return f
    }()
}

extension String {
    /// Quotes a string for safe use as a single shell argument.
    var shellQuoted: String { "'" + replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Escapes a string for use inside an AppleScript string literal.
    var appleScriptEscaped: String {
        replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
