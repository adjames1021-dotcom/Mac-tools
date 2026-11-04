import SwiftUI
import AppKit

struct LaunchItemInfo: Identifiable, Hashable {
    let url: URL
    let label: String
    let program: String
    let runAtLoad: Bool
    let keepAlive: Bool
    let scope: String
    let isUser: Bool
    var loaded: Bool

    var id: String { url.path }
    var isApple: Bool { label.hasPrefix("com.apple.") }
}

final class StartupItemsModel: ObservableObject {
    @Published private(set) var items: [LaunchItemInfo] = []
    @Published private(set) var loading = false
    @Published var status = ""

    func reload() {
        loading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let loadedLabels = StartupItemsModel.loadedLabels()
            let home = NSHomeDirectory()
            let folders: [(String, String, Bool)] = [
                (home + "/Library/LaunchAgents", "Your login (agent)", true),
                ("/Library/LaunchAgents", "All users (agent)", false),
                ("/Library/LaunchDaemons", "System (daemon)", false)
            ]
            var result: [LaunchItemInfo] = []
            for (folder, scope, isUser) in folders {
                let files = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
                for file in files where file.hasSuffix(".plist") {
                    let url = URL(fileURLWithPath: folder + "/" + file)
                    let dict = NSDictionary(contentsOf: url) as? [String: Any] ?? [:]
                    let label = dict["Label"] as? String ?? String(file.dropLast(6))
                    var program = dict["Program"] as? String ?? ""
                    if program.isEmpty, let args = dict["ProgramArguments"] as? [String] {
                        program = args.joined(separator: " ")
                    }
                    let keepAlive: Bool
                    if let b = dict["KeepAlive"] as? Bool { keepAlive = b } else { keepAlive = dict["KeepAlive"] != nil }
                    result.append(LaunchItemInfo(url: url, label: label, program: program,
                                                 runAtLoad: dict["RunAtLoad"] as? Bool ?? false,
                                                 keepAlive: keepAlive, scope: scope, isUser: isUser,
                                                 loaded: loadedLabels.contains(label)))
                }
            }
            result.sort { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
            DispatchQueue.main.async {
                self.items = result
                self.loading = false
            }
        }
    }

    static func loadedLabels() -> Set<String> {
        let output = Shell.runSync("/bin/launchctl", ["list"]).output
        var labels = Set<String>()
        for line in output.split(separator: "\n").dropFirst() {
            let parts = line.split(separator: "\t")
            if let last = parts.last { labels.insert(String(last)) }
        }
        return labels
    }

    func setEnabled(_ item: LaunchItemInfo, _ enabled: Bool) {
        let uid = getuid()
        if item.isUser {
            let args = enabled ? ["bootstrap", "gui/\(uid)", item.url.path] : ["bootout", "gui/\(uid)", item.url.path]
            let result = Shell.runSync("/bin/launchctl", args)
            status = result.succeeded ? "\(enabled ? "Started" : "Stopped") \(item.label)" : result.combined
            reload()
        } else {
            let domain = item.url.path.hasPrefix("/Library/LaunchDaemons") ? "system" : "gui/\(uid)"
            let verb = enabled ? "bootstrap" : "bootout"
            Shell.runAsAdmin("launchctl \(verb) \(domain) \(item.url.path.shellQuoted)") { result in
                self.status = result.succeeded ? "\(enabled ? "Started" : "Stopped") \(item.label)" : result.combined
                self.reload()
            }
        }
    }

    func remove(_ item: LaunchItemInfo) {
        let uid = getuid()
        if item.isUser {
            Shell.runSync("/bin/launchctl", ["bootout", "gui/\(uid)", item.url.path])
            do {
                try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
                status = "Removed \(item.label) (moved to Trash)"
            } catch {
                status = "Couldn't remove: \(error.localizedDescription)"
            }
            reload()
        } else {
            let domain = item.url.path.hasPrefix("/Library/LaunchDaemons") ? "system" : "gui/\(uid)"
            let target = NSHomeDirectory() + "/.Trash/" + item.url.lastPathComponent + " \(Int(Date().timeIntervalSince1970))"
            let command = "launchctl bootout \(domain) \(item.url.path.shellQuoted) 2>/dev/null; mv -f \(item.url.path.shellQuoted) \(target.shellQuoted)"
            Shell.runAsAdmin(command) { result in
                self.status = result.succeeded ? "Removed \(item.label) (moved to Trash)" : result.combined
                self.reload()
            }
        }
    }
}

struct StartupItemsView: View {
    @StateObject private var model = StartupItemsModel()
    @State private var search = ""
    @State private var hideApple = true
    @State private var pendingRemoval: LaunchItemInfo?

    private var filtered: [LaunchItemInfo] {
        model.items.filter { item in
            (!hideApple || !item.isApple)
                && (search.isEmpty || item.label.localizedCaseInsensitiveContains(search) || item.program.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        ToolPage(tool: .startupItems) {
            Card(title: "Login Items", icon: "person.crop.circle.badge.checkmark") {
                Text("Apps that open when you log in, and apps allowed to run in the background, are managed by macOS.")
                    .foregroundStyle(.secondary)
                Button("Open Login Items Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }

            Card(title: "Background Services (Launch Agents & Daemons)", icon: "gearshape.2") {
                HStack {
                    TextField("Filter", text: $search).textFieldStyle(.roundedBorder).frame(width: 220)
                    Toggle("Hide Apple items", isOn: $hideApple)
                    Spacer()
                    if model.loading { ProgressView().controlSize(.small) }
                    Button {
                        model.reload()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                Text("These run helpers and updaters for your apps. Stopping one turns it off until next login; removing it moves its file to the Trash. Items outside your user folder need your password.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !model.status.isEmpty {
                    Text(model.status).font(.caption).foregroundColor(.accentColor)
                }
                if filtered.isEmpty && !model.loading {
                    Text("Nothing found.").foregroundStyle(.secondary)
                }
                ForEach(filtered) { item in
                    HStack(alignment: .top, spacing: 10) {
                        Circle()
                            .fill(item.loaded ? Color.green : Color.secondary.opacity(0.4))
                            .frame(width: 9, height: 9)
                            .padding(.top, 5)
                            .help(item.loaded ? "Running / loaded" : "Not loaded")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.label).bold().lineLimit(1)
                            Text(item.program.isEmpty ? "—" : item.program)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(item.scope + (item.runAtLoad ? " · runs at login" : "") + (item.keepAlive ? " · kept alive" : ""))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(item.loaded ? "Stop" : "Start") { model.setEnabled(item, !item.loaded) }
                        Button {
                            Panels.reveal(item.url)
                        } label: {
                            Image(systemName: "magnifyingglass")
                        }
                        .help("Show in Finder")
                        Button(role: .destructive) {
                            pendingRemoval = item
                        } label: {
                            Image(systemName: "trash")
                        }
                        .help("Remove")
                    }
                    Divider()
                }
            }
        }
        .onAppear { model.reload() }
        .confirmationDialog("Remove \(pendingRemoval?.label ?? "")?", isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } })) {
            Button("Stop and Move to Trash", role: .destructive) {
                if let item = pendingRemoval { model.remove(item) }
                pendingRemoval = nil
            }
        } message: {
            Text("Only remove items you recognise. You can restore the file from the Trash.")
        }
    }
}
