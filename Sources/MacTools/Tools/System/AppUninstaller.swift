import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct InstalledApp: Identifiable, Hashable {
    let url: URL
    let name: String
    let bundleID: String
    let version: String
    let executable: String

    var id: String { url.path }
    var isApple: Bool { bundleID.hasPrefix("com.apple.") }

    init?(url: URL) {
        guard let bundle = Bundle(url: url) else { return nil }
        let info = bundle.infoDictionary ?? [:]
        self.url = url
        name = url.deletingPathExtension().lastPathComponent
        bundleID = bundle.bundleIdentifier ?? ""
        version = (info["CFBundleShortVersionString"] as? String) ?? (info["CFBundleVersion"] as? String) ?? ""
        executable = (info["CFBundleExecutable"] as? String) ?? ""
    }
}

struct RelatedItem: Identifiable, Hashable {
    let url: URL
    let category: String
    var size: Int64
    let needsAdmin: Bool
    var selected = true

    var id: String { url.path }
}

enum AppFiles {
    static var home: String { NSHomeDirectory() }

    static func installedApps() -> [InstalledApp] {
        let fm = FileManager.default
        let roots = ["/Applications", "/Applications/Utilities", home + "/Applications"]
        var apps: [InstalledApp] = []
        var seen = Set<String>()
        func add(_ url: URL) {
            guard !seen.contains(url.path), let app = InstalledApp(url: url) else { return }
            seen.insert(url.path)
            apps.append(app)
        }
        for root in roots {
            let items = (try? fm.contentsOfDirectory(at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
            for item in items {
                if item.pathExtension == "app" {
                    add(item)
                } else if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true, item.lastPathComponent != "Utilities" {
                    // Apps inside vendor folders, e.g. /Applications/Adobe Photoshop/Photoshop.app
                    let inner = (try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
                    for app in inner where app.pathExtension == "app" { add(app) }
                }
            }
        }
        let ownID = Bundle.main.bundleIdentifier ?? ""
        return apps
            .filter { $0.bundleID != ownID }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Folders that may hold an app's data, with a category label and whether to match by app name too.
    static var searchLocations: [(path: String, category: String, byName: Bool)] {
        let lib = home + "/Library"
        return [
            (lib + "/Application Support", "Application Support", true),
            (lib + "/Caches", "Caches", true),
            (lib + "/Preferences", "Preferences", false),
            (lib + "/Preferences/ByHost", "Preferences", false),
            (lib + "/Containers", "Sandbox Container", false),
            (lib + "/Group Containers", "Shared Container", false),
            (lib + "/Saved Application State", "Saved Window State", false),
            (lib + "/Logs", "Logs", true),
            (lib + "/Logs/DiagnosticReports", "Crash Reports", true),
            (lib + "/HTTPStorages", "Web Data", false),
            (lib + "/WebKit", "Web Data", false),
            (lib + "/Cookies", "Cookies", false),
            (lib + "/LaunchAgents", "Launch Agent", false),
            (lib + "/Application Scripts", "Scripts", false),
            ("/Library/Application Support", "Application Support (all users)", true),
            ("/Library/Caches", "Caches (all users)", true),
            ("/Library/Preferences", "Preferences (all users)", false),
            ("/Library/LaunchAgents", "Launch Agent (all users)", false),
            ("/Library/LaunchDaemons", "Background Service", false),
            ("/Library/PrivilegedHelperTools", "Helper Tool", false),
            ("/Library/Logs", "Logs (all users)", true)
        ]
    }

    static func matches(_ entry: String, app: InstalledApp, byName: Bool, isGroupContainer: Bool) -> Bool {
        let lower = entry.lowercased()
        let bid = app.bundleID.lowercased()
        if !bid.isEmpty {
            if lower == bid || lower.hasPrefix(bid + ".") { return true }
            if isGroupContainer && (lower.hasSuffix("." + bid) || lower.contains(bid + ".") || lower.hasSuffix(bid)) { return true }
        }
        if byName {
            let names = Set([app.name, app.executable].map { $0.lowercased() }.filter { $0.count >= 3 })
            if names.contains(lower) { return true }
            // Crash reports look like "AppName_2024-01-01-....ips" / "AppName-2024-..."
            for name in names where lower.hasPrefix(name + "_") || lower.hasPrefix(name + "-20") {
                if lower.hasSuffix(".ips") || lower.hasSuffix(".crash") || lower.hasSuffix(".diag") || lower.hasSuffix(".hang") { return true }
            }
        }
        return false
    }

    static func relatedItems(for app: InstalledApp) -> [RelatedItem] {
        let fm = FileManager.default
        var items: [RelatedItem] = []
        var seen = Set<String>()
        for location in searchLocations {
            let entries = (try? fm.contentsOfDirectory(atPath: location.path)) ?? []
            let isGroup = location.path.hasSuffix("Group Containers")
            for entry in entries where matches(entry, app: app, byName: location.byName, isGroupContainer: isGroup) {
                let path = location.path + "/" + entry
                guard !seen.contains(path) else { continue }
                seen.insert(path)
                let url = URL(fileURLWithPath: path)
                items.append(RelatedItem(url: url, category: location.category, size: size(of: url), needsAdmin: needsAdmin(url)))
            }
        }
        return items.sorted { $0.size > $1.size }
    }

    static func needsAdmin(_ url: URL) -> Bool {
        let fm = FileManager.default
        let parent = url.deletingLastPathComponent().path
        if !fm.isWritableFile(atPath: parent) { return true }
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue, !fm.isWritableFile(atPath: url.path) {
            return true
        }
        return false
    }

    static func size(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileSizeKey, .isDirectoryKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
        if values.isDirectory != true {
            return Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
        }
        var total: Int64 = 0
        if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in true }) {
            for case let file as URL in enumerator {
                if let v = try? file.resourceValues(forKeys: keys), v.isDirectory != true {
                    total += Int64(v.totalFileAllocatedSize ?? v.fileSize ?? 0)
                }
            }
        }
        return total
    }

    /// Bundle-ID–named data whose app is no longer installed.
    static func leftovers(installed: [InstalledApp]) -> [RelatedItem] {
        let lib = home + "/Library"
        let locations: [(String, String, String)] = [
            (lib + "/Containers", "Sandbox Container", ""),
            (lib + "/Caches", "Caches", ""),
            (lib + "/Preferences", "Preferences", ".plist"),
            (lib + "/Saved Application State", "Saved Window State", ".savedState"),
            (lib + "/HTTPStorages", "Web Data", ""),
            (lib + "/WebKit", "Web Data", ""),
            (lib + "/Application Scripts", "Scripts", "")
        ]
        let ids = installed.map { $0.bundleID.lowercased() }.filter { !$0.isEmpty }
        let vendors = Set(ids.map { vendor(of: $0) })
        let ownID = (Bundle.main.bundleIdentifier ?? "").lowercased()
        var results: [RelatedItem] = []
        let fm = FileManager.default
        for (path, category, suffix) in locations {
            for entry in (try? fm.contentsOfDirectory(atPath: path)) ?? [] {
                var id = entry.lowercased()
                if !suffix.isEmpty {
                    guard id.hasSuffix(suffix.lowercased()) else { continue }
                    id = String(id.dropLast(suffix.count))
                }
                guard looksLikeBundleID(id), !id.hasPrefix("com.apple."), !id.hasPrefix(ownID) else { continue }
                if ids.contains(where: { id == $0 || id.hasPrefix($0 + ".") }) { continue }
                if vendors.contains(vendor(of: id)) { continue }
                if NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil { continue }
                let url = URL(fileURLWithPath: path + "/" + entry)
                results.append(RelatedItem(url: url, category: category, size: size(of: url), needsAdmin: false, selected: false))
            }
        }
        return results.sorted { $0.size > $1.size }
    }

    static func looksLikeBundleID(_ s: String) -> Bool {
        let parts = s.split(separator: ".")
        guard parts.count >= 3 else { return false }
        return s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }
    }

    static func vendor(of id: String) -> String {
        id.split(separator: ".").prefix(2).joined(separator: ".")
    }
}

final class UninstallerModel: ObservableObject {
    @Published private(set) var apps: [InstalledApp] = []
    @Published var selectedApp: InstalledApp? {
        didSet { if selectedApp != oldValue { scanSelected() } }
    }
    @Published var related: [RelatedItem] = []
    @Published private(set) var appSize: Int64 = 0
    @Published private(set) var scanning = false
    @Published private(set) var loadingApps = false
    @Published var leftovers: [RelatedItem] = []
    @Published private(set) var scanningLeftovers = false
    @Published var status = ""

    func loadApps() {
        loadingApps = true
        DispatchQueue.global(qos: .userInitiated).async {
            let list = AppFiles.installedApps()
            DispatchQueue.main.async {
                self.apps = list
                self.loadingApps = false
                if let current = self.selectedApp, !list.contains(current) { self.selectedApp = nil }
            }
        }
    }

    func select(url: URL) {
        if let app = apps.first(where: { $0.url == url }) {
            selectedApp = app
        } else if let app = InstalledApp(url: url) {
            selectedApp = app
        }
    }

    private func scanSelected() {
        related = []
        appSize = 0
        guard let app = selectedApp else { return }
        scanning = true
        DispatchQueue.global(qos: .userInitiated).async {
            let items = AppFiles.relatedItems(for: app)
            let size = AppFiles.size(of: app.url)
            DispatchQueue.main.async {
                guard self.selectedApp == app else { return }
                self.related = items
                self.appSize = size
                self.scanning = false
            }
        }
    }

    func scanLeftovers() {
        scanningLeftovers = true
        let installed = apps
        DispatchQueue.global(qos: .userInitiated).async {
            let items = AppFiles.leftovers(installed: installed)
            DispatchQueue.main.async {
                self.leftovers = items
                self.scanningLeftovers = false
            }
        }
    }

    var selectedSize: Int64 {
        related.filter { $0.selected }.reduce(Int64(0)) { $0 + $1.size }
    }

    /// Moves the app (optional) and the selected files to the Trash.
    func remove(includeApp: Bool) {
        guard let app = selectedApp else { return }
        quit(app)
        var urls = related.filter { $0.selected }.map { $0.url }
        if includeApp { urls.insert(app.url, at: 0) }
        unloadLaunchItems(urls)
        trash(urls) { failed in
            if includeApp {
                self.status = failed.isEmpty ? "Uninstalled \(app.name) and \(urls.count - 1) related items. Everything is in the Trash if you change your mind." : "Some items couldn't be removed: " + failed.map { $0.lastPathComponent }.joined(separator: ", ")
                if failed.isEmpty {
                    self.apps.removeAll { $0.id == app.id }
                    self.selectedApp = nil
                }
            } else {
                self.status = failed.isEmpty ? "Reset \(app.name): removed \(urls.count) data items." : "Some items couldn't be removed: " + failed.map { $0.lastPathComponent }.joined(separator: ", ")
                self.scanSelected()
            }
        }
    }

    func removeLeftovers() {
        let urls = leftovers.filter { $0.selected }.map { $0.url }
        guard !urls.isEmpty else { return }
        trash(urls) { failed in
            self.status = "Moved \(urls.count - failed.count) leftover items to the Trash."
            self.leftovers.removeAll { item in urls.contains(item.url) && !failed.contains(item.url) }
        }
    }

    private func quit(_ app: InstalledApp) {
        guard !app.bundleID.isEmpty else { return }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID)
        guard !running.isEmpty else { return }
        running.forEach { $0.terminate() }
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline && running.contains(where: { !$0.isTerminated }) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        running.filter { !$0.isTerminated }.forEach { $0.forceTerminate() }
    }

    private func unloadLaunchItems(_ urls: [URL]) {
        let uid = getuid()
        for url in urls where url.pathExtension == "plist" && url.path.contains("/LaunchAgents/") && url.path.hasPrefix(NSHomeDirectory()) {
            Shell.runSync("/bin/launchctl", ["bootout", "gui/\(uid)", url.path])
        }
    }

    private func trash(_ urls: [URL], completion: @escaping ([URL]) -> Void) {
        var failed: [URL] = []
        for url in urls {
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            } catch {
                failed.append(url)
            }
        }
        guard !failed.isEmpty else {
            completion([])
            return
        }
        // Items owned by the system (or by root) need an administrator password.
        let trashDir = NSHomeDirectory() + "/.Trash"
        let stamp = Int(Date().timeIntervalSince1970)
        var commands: [String] = []
        for url in failed {
            if url.path.hasPrefix("/Library/LaunchDaemons/") || url.path.hasPrefix("/Library/LaunchAgents/") {
                commands.append("launchctl bootout system \(url.path.shellQuoted) 2>/dev/null")
            }
            let target = trashDir + "/" + url.lastPathComponent + " \(stamp)"
            commands.append("mv -f \(url.path.shellQuoted) \(target.shellQuoted)")
        }
        status = "Asking for your password to remove protected items…"
        Shell.runAsAdmin(commands.joined(separator: "; ")) { _ in
            let stillThere = failed.filter { FileManager.default.fileExists(atPath: $0.path) }
            completion(stillThere)
        }
    }
}

struct AppUninstallerView: View {
    @StateObject private var model = UninstallerModel()
    @State private var tab = 0
    @State private var search = ""
    @State private var showAppleApps = false
    @State private var confirmUninstall = false
    @State private var confirmReset = false
    @State private var confirmLeftovers = false

    private var filteredApps: [InstalledApp] {
        model.apps.filter { app in
            (showAppleApps || !app.isApple)
                && (search.isEmpty || app.name.localizedCaseInsensitiveContains(search) || app.bundleID.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        ToolPage(tool: .appUninstaller, scrolls: false) {
            HStack {
                Picker("", selection: $tab) {
                    Text("Uninstall Apps").tag(0)
                    Text("Leftovers").tag(1)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 260)
                Spacer()
                if !model.status.isEmpty {
                    Text(model.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            if tab == 0 { appsTab } else { leftoversTab }
        }
        .onAppear { if model.apps.isEmpty { model.loadApps() } }
        .confirmationDialog("Uninstall \(model.selectedApp?.name ?? "")?", isPresented: $confirmUninstall) {
            Button("Move App and \(model.related.filter { $0.selected }.count) Items to Trash", role: .destructive) {
                model.remove(includeApp: true)
            }
        } message: {
            Text("The app will be quit if it's running. Everything goes to the Trash, so you can put it back until you empty it.")
        }
        .confirmationDialog("Reset \(model.selectedApp?.name ?? "")?", isPresented: $confirmReset) {
            Button("Delete Its Data (Keep the App)", role: .destructive) { model.remove(includeApp: false) }
        } message: {
            Text("Removes the selected settings, caches and data so the app starts fresh. Items go to the Trash.")
        }
        .confirmationDialog("Move selected leftovers to the Trash?", isPresented: $confirmLeftovers) {
            Button("Move to Trash", role: .destructive) { model.removeLeftovers() }
        }
    }

    private var appsTab: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    TextField("Search apps", text: $search).textFieldStyle(.roundedBorder)
                    Button {
                        model.loadApps()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Reload the list")
                }
                Toggle("Show Apple apps", isOn: $showAppleApps).font(.caption)
                List(filteredApps, selection: Binding<String?>(
                    get: { model.selectedApp?.id },
                    set: { id in model.selectedApp = model.apps.first { $0.id == id } })) { app in
                    HStack(spacing: 8) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                            .resizable()
                            .frame(width: 24, height: 24)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(app.name).lineLimit(1)
                            Text(app.version).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                .listStyle(.inset)
                if model.loadingApps {
                    ProgressView().controlSize(.small)
                }
                Text("Tip: drop an app here to select it.").font(.caption).foregroundStyle(.secondary)
            }
            .frame(width: 260)
            .acceptsFileDrops { urls in
                if let url = urls.first(where: { $0.pathExtension == "app" }) { model.select(url: url) }
            }

            Group {
                if let app = model.selectedApp {
                    appDetail(app)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "trash.square").font(.system(size: 48)).foregroundStyle(.secondary)
                        Text("Choose an app to see everything it stores on your Mac").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxHeight: .infinity)
    }

    private func appDetail(_ app: InstalledApp) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                    .resizable()
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name).font(.title2.bold())
                    Text("\(app.bundleID.isEmpty ? "No bundle ID" : app.bundleID) · version \(app.version)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(app.url.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Button("Show in Finder") { Panels.reveal(app.url) }
            }
            if app.isApple {
                Label("This is an Apple app. Many Apple apps are part of macOS and can't be removed.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
            HStack {
                Text("App: \(Format.bytes(model.appSize))")
                Text("· Data selected: \(Format.bytes(model.selectedSize))")
                Text("· Total: \(Format.bytes(model.appSize + model.selectedSize))").bold()
                Spacer()
                if model.scanning { ProgressView().controlSize(.small) }
                Button("Select All") { setAll(true) }.disabled(model.related.isEmpty)
                Button("Select None") { setAll(false) }.disabled(model.related.isEmpty)
            }
            .font(.callout)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if !model.scanning && model.related.isEmpty {
                        Text("No extra files found for this app.").foregroundStyle(.secondary).padding(8)
                    }
                    ForEach($model.related) { $item in
                        RelatedRow(item: $item)
                    }
                }
                .padding(6)
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
            HStack {
                Button(role: .destructive) {
                    confirmUninstall = true
                } label: {
                    Label("Uninstall App + Selected Data", systemImage: "trash")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(model.scanning)
                Button("Reset App (Delete Data Only)") { confirmReset = true }
                    .disabled(model.scanning || model.related.filter { $0.selected }.isEmpty)
                Spacer()
                if model.related.contains(where: { $0.needsAdmin && $0.selected }) {
                    Label("Some items need your password", systemImage: "lock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func setAll(_ value: Bool) {
        for i in model.related.indices { model.related[i].selected = value }
    }

    private var leftoversTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button {
                    if model.apps.isEmpty { model.loadApps() }
                    model.scanLeftovers()
                } label: {
                    Label("Scan for Leftovers", systemImage: "magnifyingglass")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.scanningLeftovers)
                if model.scanningLeftovers { ProgressView().controlSize(.small) }
                Spacer()
                let selected = model.leftovers.filter { $0.selected }
                Text("\(selected.count) selected · \(Format.bytes(selected.reduce(Int64(0)) { $0 + $1.size }))")
                    .foregroundStyle(.secondary)
                Button("Move Selected to Trash") { confirmLeftovers = true }
                    .disabled(selected.isEmpty)
            }
            Text("These folders and settings belong to apps that are no longer installed. Nothing is selected automatically – check the ones you recognise. Items go to the Trash, so you can restore them.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if !model.scanningLeftovers && model.leftovers.isEmpty {
                        Text("Click “Scan for Leftovers” to look for data from deleted apps.").foregroundStyle(.secondary).padding(8)
                    }
                    ForEach($model.leftovers) { $item in
                        RelatedRow(item: $item)
                    }
                }
                .padding(6)
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
        }
        .frame(maxHeight: .infinity)
    }
}

private struct RelatedRow: View {
    @Binding var item: RelatedItem

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: $item.selected).labelsHidden()
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                .resizable()
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                Text(item.category + " · " + item.url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if item.needsAdmin {
                Image(systemName: "lock").foregroundStyle(.secondary).help("Needs your password to remove")
            }
            Text(Format.bytes(item.size)).monospacedDigit().foregroundStyle(.secondary)
            Button {
                Panels.reveal(item.url)
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("Show in Finder")
        }
        .padding(.vertical, 2)
    }
}
