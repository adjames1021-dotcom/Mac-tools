import SwiftUI
import AppKit
import Darwin
import UniformTypeIdentifiers

// MARK: - Git helper

struct GitHelperView: View {
    @StateObject private var runner = CommandRunner()
    @AppStorage("gitRepoPath") private var repoPath = ""
    @AppStorage("gitRecentRepos") private var recentRaw = ""
    @State private var branch = ""
    @State private var remote = ""
    @State private var statusText = ""
    @State private var logText = ""
    @State private var branches: [String] = []
    @State private var commitMessage = ""
    @State private var newBranch = ""
    @State private var isRepo = false
    @State private var confirmDiscard = false

    private var recent: [String] { recentRaw.split(separator: "\n").map(String.init).filter { !$0.isEmpty } }

    var body: some View {
        ToolPage(tool: .gitHelper) {
            Card(title: "Repository", icon: "folder") {
                HStack {
                    Button("Choose Folder…") {
                        if let url = Panels.chooseFolder(message: "Choose a git repository") { select(url.path) }
                    }
                    if !recent.isEmpty {
                        Menu("Recent") {
                            ForEach(recent, id: \.self) { path in
                                Button((path as NSString).lastPathComponent) { select(path) }
                            }
                        }
                        .frame(width: 100)
                    }
                    Text(repoPath.isEmpty ? "No repository selected" : repoPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        refresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(repoPath.isEmpty)
                }
                if !repoPath.isEmpty && !isRepo {
                    HStack {
                        Label("This folder isn't a git repository.", systemImage: "exclamationmark.triangle").foregroundColor(.orange)
                        Button("Initialise Repository") { git(["init"]) }
                    }
                }
                if isRepo {
                    InfoRow(label: "Branch", value: branch)
                    InfoRow(label: "Remote", value: remote)
                    HStack {
                        Button("Open in Terminal") {
                            Shell.appleScript("tell application \"Terminal\"\nactivate\ndo script \"cd \(repoPath.shellQuoted.appleScriptEscaped)\"\nend tell")
                        }
                        Button("Open in Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: repoPath)) }
                        Button("Open in VS Code") { Shell.run("open -a 'Visual Studio Code' \(repoPath.shellQuoted)") }
                        if let web = webURL {
                            Button("Open on Web") { NSWorkspace.shared.open(web) }
                        }
                    }
                }
            }

            if isRepo {
                Card(title: "Actions", icon: "bolt") {
                    HStack {
                        Button("Fetch") { git(["fetch", "--all", "--prune"]) }
                        Button("Pull") { git(["pull"]) }
                        Button("Push") { git(["push"]) }
                        Button("Stash") { git(["stash", "push", "-u"]) }
                        Button("Pop Stash") { git(["stash", "pop"]) }
                        Button("Discard Changes…") { confirmDiscard = true }
                    }
                    HStack {
                        TextField("Commit message", text: $commitMessage)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(commitAll)
                        Button("Commit All Changes", action: commitAll)
                            .buttonStyle(.borderedProminent)
                            .disabled(commitMessage.trimmed.isEmpty)
                    }
                    HStack {
                        Picker("Switch to", selection: Binding(get: { branch }, set: { git(["checkout", $0]) })) {
                            ForEach(branches, id: \.self) { Text($0).tag($0) }
                        }
                        .frame(maxWidth: 300)
                        TextField("New branch name", text: $newBranch)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 200)
                        Button("Create Branch") {
                            git(["checkout", "-b", newBranch.trimmed])
                            newBranch = ""
                        }
                        .disabled(newBranch.trimmed.isEmpty)
                    }
                }
                HStack(alignment: .top, spacing: 12) {
                    Card(title: "Status", icon: "list.bullet") {
                        OutputBox(text: statusText.isEmpty ? "Working tree clean ✓" : statusText, minHeight: 120, maxHeight: 260)
                    }
                    Card(title: "Recent Commits", icon: "clock") {
                        OutputBox(text: logText, minHeight: 120, maxHeight: 260)
                    }
                }
                Card(title: "Output", icon: "terminal") {
                    OutputBox(text: runner.output, minHeight: 80, maxHeight: 260)
                }
            }
        }
        .onAppear { if !repoPath.isEmpty { refresh() } }
        .onChange(of: runner.running) { running in
            if !running { refresh() }
        }
        .confirmationDialog("Discard all uncommitted changes?", isPresented: $confirmDiscard) {
            Button("Discard Changes to Tracked Files", role: .destructive) { git(["reset", "--hard", "HEAD"]) }
        } message: {
            Text("This can't be undone. Untracked (new) files are kept.")
        }
    }

    private var webURL: URL? {
        var text = remote.trimmed
        guard !text.isEmpty else { return nil }
        if text.hasPrefix("git@") {
            text = text.replacingOccurrences(of: ":", with: "/").replacingOccurrences(of: "git@", with: "https://")
        }
        if text.hasSuffix(".git") { text = String(text.dropLast(4)) }
        return text.hasPrefix("http") ? URL(string: text) : nil
    }

    private func select(_ path: String) {
        repoPath = path
        var list = recent.filter { $0 != path }
        list.insert(path, at: 0)
        recentRaw = list.prefix(8).joined(separator: "\n")
        refresh()
    }

    private func commitAll() {
        let message = commitMessage.trimmed
        guard !message.isEmpty else { return }
        runner.runShell("git -C \(repoPath.shellQuoted) add -A && git -C \(repoPath.shellQuoted) commit -m \(message.shellQuoted)")
        commitMessage = ""
    }

    private func git(_ args: [String]) {
        runner.run(executable: "/usr/bin/git", args: ["-C", repoPath] + args, header: "$ git " + args.joined(separator: " "))
    }

    private func refresh() {
        let path = repoPath
        guard !path.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            func g(_ args: [String]) -> String { Shell.runSync("/usr/bin/git", ["-C", path] + args).output.trimmed }
            let inside = g(["rev-parse", "--is-inside-work-tree"]) == "true"
            let b = inside ? g(["rev-parse", "--abbrev-ref", "HEAD"]) : ""
            let r = inside ? g(["remote", "get-url", "origin"]) : ""
            let st = inside ? g(["status", "--short", "--branch"]) : ""
            let lg = inside ? g(["log", "--oneline", "--decorate", "-25"]) : ""
            let br = inside ? g(["branch", "--format=%(refname:short)"]).split(separator: "\n").map(String.init) : []
            DispatchQueue.main.async {
                isRepo = inside
                branch = b
                remote = r
                statusText = st.split(separator: "\n").count <= 1 ? "" : st
                logText = lg
                branches = br
            }
        }
    }
}

// MARK: - Ports & local web server

struct ListeningPort: Identifiable, Hashable {
    let command: String
    let pid: Int32
    let user: String
    let address: String
    let port: String
    var id: String { "\(pid)-\(address)" }
}

final class LocalServer: ObservableObject {
    static let shared = LocalServer()
    @Published private(set) var running = false
    @Published private(set) var url: URL?
    @Published var output = ""
    private var process: Process?

    func start(folder: URL, port: Int) {
        stop()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = ["-m", "http.server", "\(port)", "--bind", "127.0.0.1", "--directory", folder.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            let text = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.output += text
                if self.output.count > 50_000 { self.output = String(self.output.suffix(50_000)) }
            }
        }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                self?.running = false
                self?.process = nil
            }
        }
        do {
            try p.run()
            process = p
            running = true
            url = URL(string: "http://localhost:\(port)/")
            output = "Serving \(folder.path) at http://localhost:\(port)/\n"
        } catch {
            output = "Couldn't start the server: \(error.localizedDescription)\n"
        }
    }

    func stop() {
        process?.terminate()
        process = nil
        running = false
    }
}

struct PortMonitorView: View {
    @State private var ports: [ListeningPort] = []
    @State private var loading = false
    @State private var checkPort = 3000
    @State private var checkResult = ""
    @ObservedObject private var server = LocalServer.shared
    @AppStorage("serverFolder") private var serverFolder = ""
    @AppStorage("serverPort") private var serverPort = 8000
    @State private var message = ""

    var body: some View {
        ToolPage(tool: .portMonitor) {
            Card(title: "Listening Ports", icon: "dot.radiowaves.left.and.right") {
                HStack {
                    Button {
                        refresh()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    if loading { ProgressView().controlSize(.small) }
                    Spacer()
                    IntField(title: "Is port", value: $checkPort, width: 70)
                    Button("free?") { check() }
                    Text(checkResult).font(.caption).foregroundStyle(.secondary)
                }
                if !message.isEmpty { Text(message).font(.caption).foregroundColor(.accentColor) }
                if ports.isEmpty && !loading {
                    Text("No TCP ports are being listened on by your processes.").foregroundStyle(.secondary)
                }
                ForEach(ports) { port in
                    HStack {
                        Text(port.port)
                            .font(.system(.body, design: .monospaced).bold())
                            .frame(width: 70, alignment: .leading)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(port.command).bold()
                            Text("PID \(port.pid) · \(port.user) · \(port.address)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let url = URL(string: "http://localhost:\(port.port)") {
                            Button("Open") { NSWorkspace.shared.open(url) }
                        }
                        Button("Stop Process") { kill(port) }
                            .foregroundColor(.red)
                    }
                    Divider()
                }
            }

            Card(title: "Quick Web Server", icon: "server.rack") {
                Text("Serve a folder (like a website you're building) at http://localhost so you can test it in a browser.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Choose Folder…") {
                        if let url = Panels.chooseFolder() { serverFolder = url.path }
                    }
                    Text(serverFolder.isEmpty ? "No folder chosen" : serverFolder).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    Spacer()
                    IntField(title: "Port", value: $serverPort, width: 70)
                }
                HStack {
                    if server.running {
                        Button("Stop Server") { server.stop() }
                            .buttonStyle(.borderedProminent)
                            .tint(.red)
                        if let url = server.url {
                            Button("Open in Browser") { NSWorkspace.shared.open(url) }
                            Text(url.absoluteString).font(.system(.body, design: .monospaced))
                        }
                    } else {
                        Button("Start Server") {
                            server.start(folder: URL(fileURLWithPath: serverFolder), port: serverPort)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(serverFolder.isEmpty)
                    }
                }
                if !server.output.isEmpty {
                    OutputBox(text: server.output, minHeight: 60, maxHeight: 160)
                }
            }
        }
        .onAppear(perform: refresh)
    }

    private func refresh() {
        loading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let output = Shell.runSync("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN"]).output
            var seen = Set<String>()
            var list: [ListeningPort] = []
            for line in output.split(separator: "\n").dropFirst() {
                let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
                guard parts.count >= 9, let pid = Int32(parts[1]) else { continue }
                let address = parts[8]
                let port = address.split(separator: ":").last.map(String.init) ?? address
                let key = "\(pid)-\(address)"
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                list.append(ListeningPort(command: parts[0].replacingOccurrences(of: "\\x20", with: " "), pid: pid, user: parts[2], address: address, port: port))
            }
            list.sort { (Int($0.port) ?? 0) < (Int($1.port) ?? 0) }
            DispatchQueue.main.async {
                ports = list
                loading = false
            }
        }
    }

    private func check() {
        let result = Shell.runSync("/usr/sbin/lsof", ["-nP", "-iTCP:\(checkPort)", "-sTCP:LISTEN"]).output
        let lines = result.split(separator: "\n").dropFirst()
        if let first = lines.first {
            let name = first.split(separator: " ").first.map(String.init) ?? "a process"
            checkResult = "Port \(checkPort) is in use by \(name)"
        } else {
            checkResult = "Port \(checkPort) is free ✓"
        }
    }

    private func kill(_ port: ListeningPort) {
        if Darwin.kill(port.pid, SIGTERM) == 0 {
            message = "Stopped \(port.command) (PID \(port.pid))"
        } else {
            Shell.runAsAdmin("kill \(port.pid)")
            message = "Asked for admin rights to stop \(port.command)"
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { refresh() }
    }
}

// MARK: - Developer environment

struct DevToolStatus: Identifiable {
    let name: String
    let path: String
    let version: String
    var id: String { name }
    var installed: Bool { !path.isEmpty }
}

struct DevEnvironmentView: View {
    @State private var tools: [DevToolStatus] = []
    @State private var pathEntries: [String] = []
    @State private var envVars: [(String, String)] = []
    @State private var loading = false
    @State private var revealSecrets = false
    @State private var envFilter = ""

    private static let checks: [(String, String, String)] = [
        ("Git", "git", "git --version"), ("Swift", "swift", "swift --version 2>&1 | head -1"),
        ("Xcode", "xcodebuild", "xcodebuild -version 2>&1 | head -1"), ("Clang", "clang", "clang --version | head -1"),
        ("Python 3", "python3", "python3 --version"), ("pip", "pip3", "pip3 --version"),
        ("Node.js", "node", "node --version"), ("npm", "npm", "npm --version"), ("Yarn", "yarn", "yarn --version"),
        ("pnpm", "pnpm", "pnpm --version"), ("Bun", "bun", "bun --version"), ("Deno", "deno", "deno --version | head -1"),
        ("Ruby", "ruby", "ruby --version"), ("Go", "go", "go version"), ("Rust", "rustc", "rustc --version"),
        ("Cargo", "cargo", "cargo --version"), ("PHP", "php", "php --version | head -1"), ("Perl", "perl", "perl -e 'print $^V'"),
        ("Docker", "docker", "docker --version"), ("kubectl", "kubectl", "kubectl version --client 2>&1 | head -1"),
        ("Homebrew", "brew", "brew --version | head -1"), ("GitHub CLI", "gh", "gh --version | head -1"),
        ("VS Code", "code", "code --version | head -1"), ("CMake", "cmake", "cmake --version | head -1"),
        ("Make", "make", "make --version | head -1"), (".NET", "dotnet", "dotnet --version"),
        ("Terraform", "terraform", "terraform version | head -1"), ("CocoaPods", "pod", "pod --version")
    ]

    var body: some View {
        ToolPage(tool: .devEnvironment) {
            Card(title: "Installed Developer Tools", icon: "hammer") {
                HStack {
                    Button {
                        load()
                    } label: {
                        Label("Rescan", systemImage: "arrow.clockwise")
                    }
                    if loading {
                        ProgressView().controlSize(.small)
                        Text("Checking…").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(tools.filter { $0.installed }.count) of \(tools.count) installed").foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 330), alignment: .topLeading)], alignment: .leading, spacing: 8) {
                    ForEach(tools) { tool in
                        HStack(alignment: .top) {
                            Image(systemName: tool.installed ? "checkmark.circle.fill" : "circle.dashed")
                                .foregroundColor(tool.installed ? Color.green : Color.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(tool.name).bold()
                                Text(tool.installed ? tool.version : "Not installed")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                if tool.installed {
                                    Text(tool.path).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                }
                            }
                            Spacer()
                        }
                    }
                }
            }
            Card(title: "PATH (\(pathEntries.count) folders, in search order)", icon: "point.topleft.down.curvedto.point.bottomright.up") {
                ForEach(Array(pathEntries.enumerated()), id: \.offset) { item in
                    HStack {
                        Text("\(item.offset + 1).").foregroundStyle(.secondary).frame(width: 28, alignment: .trailing)
                        Text(item.element).font(.system(.callout, design: .monospaced))
                        if !FileManager.default.fileExists(atPath: item.element) {
                            Text("missing").font(.caption).foregroundColor(.orange)
                        }
                        Spacer()
                    }
                }
            }
            Card(title: "Environment Variables", icon: "list.bullet.rectangle") {
                HStack {
                    TextField("Filter", text: $envFilter).textFieldStyle(.roundedBorder).frame(width: 200)
                    Toggle("Show secret values", isOn: $revealSecrets)
                }
                ForEach(envVars.filter { envFilter.isEmpty || $0.0.localizedCaseInsensitiveContains(envFilter) }, id: \.0) { item in
                    InfoRow(label: item.0, value: displayValue(item))
                }
            }
        }
        .onAppear { if tools.isEmpty { load() } }
    }

    private func displayValue(_ item: (String, String)) -> String {
        let secretWords = ["TOKEN", "SECRET", "PASSWORD", "KEY", "AUTH", "CREDENTIAL"]
        if !revealSecrets && secretWords.contains(where: { item.0.uppercased().contains($0) }) {
            return String(repeating: "•", count: min(12, max(4, item.1.count)))
        }
        return item.1
    }

    private func load() {
        loading = true
        // Also load ~/.zshrc, where tools like nvm, pyenv and rbenv usually add themselves to PATH.
        var script = "[ -f ~/.zshrc ] && source ~/.zshrc >/dev/null 2>&1 </dev/null\n"
        for (name, command, version) in DevEnvironmentView.checks {
            script += "p=$(command -v \(command) 2>/dev/null); if [ -n \"$p\" ]; then v=$(\(version) 2>&1 | head -1); echo \"\(name)|$p|$v\"; else echo \"\(name)||\"; fi\n"
        }
        let finalScript = script
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Shell.runSync("/bin/zsh", ["-lc", finalScript]).output
            var found: [DevToolStatus] = []
            for line in result.split(separator: "\n") {
                let parts = line.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
                guard parts.count == 3 else { continue }
                found.append(DevToolStatus(name: parts[0], path: parts[1], version: parts[2]))
            }
            let rc = "[ -f ~/.zshrc ] && source ~/.zshrc >/dev/null 2>&1 </dev/null; "
            let path = Shell.runSync("/bin/zsh", ["-lc", rc + "echo $PATH"]).output.trimmed
            let env = Shell.runSync("/bin/zsh", ["-lc", rc + "env"]).output
            let vars = env.split(separator: "\n").compactMap { line -> (String, String)? in
                guard let eq = line.firstIndex(of: "=") else { return nil }
                return (String(line[..<eq]), String(line[line.index(after: eq)...]))
            }.sorted { $0.0 < $1.0 }
            DispatchQueue.main.async {
                tools = found.sorted { ($0.installed ? 0 : 1, $0.name) < ($1.installed ? 0 : 1, $1.name) }
                pathEntries = path.split(separator: ":").map(String.init)
                envVars = vars
                loading = false
            }
        }
    }
}

// MARK: - Homebrew

struct HomebrewView: View {
    @StateObject private var runner = CommandRunner()
    @State private var formulae: [String] = []
    @State private var casks: [String] = []
    @State private var outdated: [String] = []
    @State private var searchText = ""
    @State private var searchFormulae: [String] = []
    @State private var searchCasks: [String] = []
    @State private var tab = 0
    @State private var loading = false
    @State private var filter = ""

    private var brew: String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static let installCommand = "/bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""

    var body: some View {
        ToolPage(tool: .homebrew) {
            if let brew = brew {
                Card(title: "Homebrew", icon: "mug") {
                    HStack {
                        Button("Update") { run(brew, ["update"]) }
                        Button("Upgrade All") { run(brew, ["upgrade"]) }
                        Button("Clean Up") { run(brew, ["cleanup"]) }
                        Button("Doctor") { run(brew, ["doctor"]) }
                        Spacer()
                        if loading || runner.running { ProgressView().controlSize(.small) }
                        Button {
                            reload(brew)
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    Picker("", selection: $tab) {
                        Text("Installed (\(formulae.count + casks.count))").tag(0)
                        Text("Outdated (\(outdated.count))").tag(1)
                        Text("Search & Install").tag(2)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 460)
                }
                switch tab {
                case 0: installedList(brew)
                case 1: outdatedList(brew)
                default: searchView(brew)
                }
                Card(title: "Output", icon: "terminal") {
                    OutputBox(text: runner.output, minHeight: 100, maxHeight: 300)
                    if runner.running {
                        Button("Stop") { runner.stop() }
                    }
                }
            } else {
                Card(title: "Homebrew isn't installed", icon: "mug") {
                    Text("Homebrew is the most popular package manager for macOS. It installs command-line tools (like node, python, ffmpeg) and apps with one command.")
                    Text(HomebrewView.installCommand)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                    HStack {
                        Button("Install in Terminal") {
                            Shell.appleScript("tell application \"Terminal\"\nactivate\ndo script \"\(HomebrewView.installCommand.appleScriptEscaped)\"\nend tell")
                        }
                        .buttonStyle(.borderedProminent)
                        CopyButton(text: HomebrewView.installCommand)
                        Button("brew.sh") { if let url = URL(string: "https://brew.sh") { NSWorkspace.shared.open(url) } }
                    }
                }
            }
        }
        .onAppear { if let brew = brew, formulae.isEmpty { reload(brew) } }
        .onChange(of: runner.running) { running in
            if !running, let brew = brew { reload(brew) }
        }
    }

    private func installedList(_ brew: String) -> some View {
        Card(title: "Installed", icon: "shippingbox") {
            TextField("Filter", text: $filter).textFieldStyle(.roundedBorder).frame(width: 220)
            ForEach(formulae.filter { filter.isEmpty || $0.localizedCaseInsensitiveContains(filter) }, id: \.self) { name in
                packageRow(name, cask: false, brew: brew, installed: true)
            }
            ForEach(casks.filter { filter.isEmpty || $0.localizedCaseInsensitiveContains(filter) }, id: \.self) { name in
                packageRow(name, cask: true, brew: brew, installed: true)
            }
        }
    }

    private func outdatedList(_ brew: String) -> some View {
        Card(title: "Outdated", icon: "arrow.up.circle") {
            if outdated.isEmpty {
                Text("Everything is up to date ✓").foregroundStyle(.secondary)
            }
            ForEach(outdated, id: \.self) { line in
                HStack {
                    Text(line).font(.system(.callout, design: .monospaced))
                    Spacer()
                    Button("Upgrade") {
                        if let name = line.split(separator: " ").first { run(brew, ["upgrade", String(name)]) }
                    }
                }
            }
        }
    }

    private func searchView(_ brew: String) -> some View {
        Card(title: "Search", icon: "magnifyingglass") {
            HStack {
                TextField("Search packages, e.g. ffmpeg, firefox", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { search(brew) }
                Button("Search") { search(brew) }.disabled(searchText.trimmed.isEmpty)
            }
            if !searchFormulae.isEmpty {
                Text("Command-line tools").font(.headline)
                ForEach(searchFormulae.prefix(60), id: \.self) { name in
                    packageRow(name, cask: false, brew: brew, installed: formulae.contains(name))
                }
            }
            if !searchCasks.isEmpty {
                Text("Apps").font(.headline)
                ForEach(searchCasks.prefix(60), id: \.self) { name in
                    packageRow(name, cask: true, brew: brew, installed: casks.contains(name))
                }
            }
        }
    }

    private func packageRow(_ name: String, cask: Bool, brew: String, installed: Bool) -> some View {
        HStack {
            Image(systemName: cask ? "app" : "terminal").foregroundStyle(.secondary).frame(width: 18)
            Text(name)
            if cask { Text("app").font(.caption).foregroundStyle(.secondary) }
            Spacer()
            Button("Info") { run(brew, ["info"] + (cask ? ["--cask"] : []) + [name]) }
            if installed {
                Button("Uninstall") { run(brew, ["uninstall"] + (cask ? ["--cask"] : []) + [name]) }
                    .foregroundColor(.red)
            } else {
                Button("Install") { run(brew, ["install"] + (cask ? ["--cask"] : []) + [name]) }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private func run(_ brew: String, _ args: [String]) {
        runner.run(executable: brew, args: args, header: "$ brew " + args.joined(separator: " "))
    }

    private func reload(_ brew: String) {
        loading = true
        DispatchQueue.global(qos: .userInitiated).async {
            func lines(_ args: [String]) -> [String] {
                Shell.runSync(brew, args, environment: ["HOMEBREW_NO_AUTO_UPDATE": "1"]).output
                    .split(separator: "\n").map(String.init).filter { !$0.isEmpty }
            }
            let f = lines(["list", "--formula", "-1"])
            let c = lines(["list", "--cask", "-1"])
            let o = lines(["outdated", "--verbose"])
            DispatchQueue.main.async {
                formulae = f
                casks = c
                outdated = o
                loading = false
            }
        }
    }

    private func search(_ brew: String) {
        let query = searchText.trimmed
        guard !query.isEmpty else { return }
        loading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let env = ["HOMEBREW_NO_AUTO_UPDATE": "1"]
            let f = Shell.runSync(brew, ["search", "--formula", query], environment: env).output
            let c = Shell.runSync(brew, ["search", "--cask", query], environment: env).output
            func names(_ s: String) -> [String] {
                s.split(separator: "\n").map(String.init).filter { !$0.isEmpty && !$0.hasPrefix("==>") && !$0.contains(" ") }
            }
            let fNames = names(f)
            let cNames = names(c)
            DispatchQueue.main.async {
                searchFormulae = fNames
                searchCasks = cNames
                loading = false
            }
        }
    }
}

// MARK: - SSH keys

struct SSHKeyInfo: Identifiable {
    let url: URL
    let publicKey: String
    let fingerprint: String
    var id: String { url.path }
}

struct SSHKeysView: View {
    @StateObject private var runner = CommandRunner()
    @State private var keys: [SSHKeyInfo] = []
    @State private var keyType = "ed25519"
    @State private var comment = ""
    @State private var fileName = "id_ed25519"
    @State private var passphrase = ""

    private var sshDir: String { NSHomeDirectory() + "/.ssh" }

    var body: some View {
        ToolPage(tool: .sshKeys) {
            Card(title: "Your SSH Keys", icon: "key") {
                if keys.isEmpty {
                    Text("No public keys found in ~/.ssh").foregroundStyle(.secondary)
                }
                ForEach(keys) { key in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(key.url.lastPathComponent).bold()
                            Spacer()
                            CopyButton(text: key.publicKey, label: "Copy Public Key")
                            Button("Add to Agent") {
                                let privatePath = String(key.url.path.dropLast(4))
                                runner.run(executable: "/usr/bin/ssh-add", args: ["--apple-use-keychain", privatePath])
                            }
                            Button {
                                Panels.reveal(key.url)
                            } label: {
                                Image(systemName: "magnifyingglass")
                            }
                        }
                        Text(key.fingerprint).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                        Text(key.publicKey).font(.system(.caption, design: .monospaced)).lineLimit(2).truncationMode(.middle)
                    }
                    Divider()
                }
                HStack {
                    Button("Test GitHub Connection") {
                        runner.run(executable: "/usr/bin/ssh", args: ["-T", "-o", "StrictHostKeyChecking=accept-new", "-o", "BatchMode=yes", "git@github.com"])
                    }
                    Button("Add Key on GitHub…") {
                        if let url = URL(string: "https://github.com/settings/ssh/new") { NSWorkspace.shared.open(url) }
                    }
                    Button("Edit ~/.ssh/config") { editConfig() }
                    Button("Reload") { load() }
                }
            }
            Card(title: "Create a New Key", icon: "plus.circle") {
                HStack {
                    Picker("Type", selection: $keyType) {
                        Text("Ed25519 (recommended)").tag("ed25519")
                        Text("RSA 4096").tag("rsa")
                        Text("ECDSA").tag("ecdsa")
                    }
                    .frame(width: 260)
                    .onChange(of: keyType) { type in fileName = "id_" + type }
                    TextField("Comment (usually your email)", text: $comment).textFieldStyle(.roundedBorder)
                }
                HStack {
                    TextField("File name", text: $fileName).textFieldStyle(.roundedBorder).frame(width: 200)
                    SecureField("Passphrase (optional)", text: $passphrase).textFieldStyle(.roundedBorder)
                    Button("Generate Key") { generate() }
                        .buttonStyle(.borderedProminent)
                        .disabled(fileName.trimmed.isEmpty || FileManager.default.fileExists(atPath: sshDir + "/" + fileName.trimmed))
                }
                if FileManager.default.fileExists(atPath: sshDir + "/" + fileName.trimmed) {
                    Text("A key with that file name already exists – pick another name.").font(.caption).foregroundColor(.orange)
                }
            }
            if !runner.output.isEmpty {
                Card(title: "Output", icon: "terminal") {
                    OutputBox(text: runner.output, minHeight: 60, maxHeight: 220)
                }
            }
        }
        .onAppear(perform: load)
        .onChange(of: runner.running) { running in if !running { load() } }
    }

    private func load() {
        let dir = sshDir
        DispatchQueue.global(qos: .userInitiated).async {
            let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".pub") }.sorted()
            let list = files.map { file -> SSHKeyInfo in
                let url = URL(fileURLWithPath: dir + "/" + file)
                let text = (try? String(contentsOf: url, encoding: .utf8))?.trimmed ?? ""
                let fp = Shell.runSync("/usr/bin/ssh-keygen", ["-lf", url.path]).output.trimmed
                return SSHKeyInfo(url: url, publicKey: text, fingerprint: fp)
            }
            DispatchQueue.main.async { keys = list }
        }
    }

    private func generate() {
        try? FileManager.default.createDirectory(atPath: sshDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var args = ["-t", keyType]
        if keyType == "rsa" { args += ["-b", "4096"] }
        if !comment.trimmed.isEmpty { args += ["-C", comment.trimmed] }
        args += ["-f", sshDir + "/" + fileName.trimmed, "-N", passphrase]
        runner.run(executable: "/usr/bin/ssh-keygen", args: args, header: "$ ssh-keygen -t \(keyType) -f ~/.ssh/\(fileName.trimmed)")
        passphrase = ""
    }

    private func editConfig() {
        let path = sshDir + "/config"
        if !FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.createDirectory(atPath: sshDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            FileManager.default.createFile(atPath: path, contents: Data("# SSH config\n# Host github.com\n#   AddKeysToAgent yes\n#   UseKeychain yes\n#   IdentityFile ~/.ssh/id_ed25519\n".utf8))
        }
        Shell.run("open -e \(path.shellQuoted)")
    }
}

// MARK: - .gitignore generator

struct GitignoreView: View {
    @State private var selected: Set<String> = ["macOS"]
    @State private var message = ""

    private var output: String { GitignoreTemplates.combined(GitignoreTemplates.all.map { $0.0 }.filter { selected.contains($0) }) }

    var body: some View {
        ToolPage(tool: .gitignoreGen) {
            Card(title: "Pick What Your Project Uses", icon: "checklist") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)], alignment: .leading, spacing: 6) {
                    ForEach(GitignoreTemplates.all, id: \.0) { template in
                        Toggle(template.0, isOn: Binding(
                            get: { selected.contains(template.0) },
                            set: { if $0 { selected.insert(template.0) } else { selected.remove(template.0) } }))
                    }
                }
            }
            Card(title: ".gitignore", icon: "doc.text") {
                OutputBox(text: output, minHeight: 200, maxHeight: 420)
                HStack {
                    CopyButton(text: output)
                    Button("Save into a Project Folder…") { save() }
                        .buttonStyle(.borderedProminent)
                        .disabled(selected.isEmpty)
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func save() {
        guard let folder = Panels.chooseFolder(message: "Choose your project folder") else { return }
        let url = folder.appendingPathComponent(".gitignore")
        if let existing = try? String(contentsOf: url, encoding: .utf8) {
            try? (existing + "\n\n" + output).write(to: url, atomically: true, encoding: .utf8)
            message = "Added to the existing .gitignore"
        } else {
            try? output.write(to: url, atomically: true, encoding: .utf8)
            message = "Created \(url.path)"
        }
    }
}

// MARK: - Snippet library

struct CodeSnippet: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var language: String
    var code: String
    var modified = Date()
}

final class SnippetStore: ObservableObject {
    static let shared = SnippetStore()
    static let languages = ["Swift", "Python", "JavaScript", "TypeScript", "Shell", "SQL", "HTML", "CSS", "JSON", "Go",
                            "Rust", "Java", "Kotlin", "C", "C++", "C#", "Ruby", "PHP", "YAML", "Markdown", "Other"]

    @Published var snippets: [CodeSnippet] {
        didSet { DataStore.save(snippets, to: "code-snippets.json") }
    }

    private init() {
        snippets = DataStore.load([CodeSnippet].self, from: "code-snippets.json") ?? [
            CodeSnippet(title: "Fetch JSON (Swift)", language: "Swift", code: "let (data, _) = try await URLSession.shared.data(from: url)\nlet items = try JSONDecoder().decode([Item].self, from: data)"),
            CodeSnippet(title: "Find big files", language: "Shell", code: "find . -type f -size +100M -exec ls -lh {} \\;"),
            CodeSnippet(title: "Debounce (JavaScript)", language: "JavaScript", code: "function debounce(fn, ms) {\n  let t;\n  return (...args) => {\n    clearTimeout(t);\n    t = setTimeout(() => fn(...args), ms);\n  };\n}"),
            CodeSnippet(title: "Read a file (Python)", language: "Python", code: "with open(\"file.txt\", encoding=\"utf-8\") as f:\n    for line in f:\n        print(line.rstrip())")
        ]
    }
}

struct SnippetsView: View {
    @ObservedObject private var store = SnippetStore.shared
    @State private var selectedID: UUID?
    @State private var search = ""
    @State private var language = "All"

    private var filtered: [CodeSnippet] {
        store.snippets
            .filter { language == "All" || $0.language == language }
            .filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.code.localizedCaseInsensitiveContains(search) }
            .sorted { $0.modified > $1.modified }
    }

    private var index: Int? {
        guard let id = selectedID ?? filtered.first?.id else { return nil }
        return store.snippets.firstIndex { $0.id == id }
    }

    var body: some View {
        ToolPage(tool: .snippets, scrolls: false) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        TextField("Search", text: $search).textFieldStyle(.roundedBorder)
                        Button {
                            let snippet = CodeSnippet(title: "New snippet", language: language == "All" ? "Swift" : language, code: "")
                            store.snippets.insert(snippet, at: 0)
                            selectedID = snippet.id
                        } label: {
                            Image(systemName: "plus")
                        }
                        .help("New snippet")
                    }
                    Picker("", selection: $language) {
                        Text("All languages").tag("All")
                        ForEach(SnippetStore.languages, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    List(filtered, selection: $selectedID) { snippet in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(snippet.title).lineLimit(1)
                            Text(snippet.language).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .listStyle(.inset)
                }
                .frame(width: 240)

                if let i = index {
                    editor(i)
                } else {
                    Text("Create a snippet with +").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    private func binding<T>(_ i: Int, _ keyPath: WritableKeyPath<CodeSnippet, T>, default value: T) -> Binding<T> {
        Binding(
            get: { store.snippets.indices.contains(i) ? store.snippets[i][keyPath: keyPath] : value },
            set: { newValue in
                if store.snippets.indices.contains(i) {
                    store.snippets[i][keyPath: keyPath] = newValue
                    store.snippets[i].modified = Date()
                }
            })
    }

    private func editor(_ i: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Title", text: binding(i, \.title, default: "")).textFieldStyle(.roundedBorder)
                Picker("", selection: binding(i, \.language, default: "Other")) {
                    ForEach(SnippetStore.languages, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(width: 140)
                CopyButton(text: store.snippets.indices.contains(i) ? store.snippets[i].code : "")
                Button(role: .destructive) {
                    if store.snippets.indices.contains(i) {
                        store.snippets.remove(at: i)
                        selectedID = nil
                    }
                } label: {
                    Image(systemName: "trash")
                }
            }
            CodeEditor(text: binding(i, \.code, default: ""), minHeight: 300)
                .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Developer cache cleaner

struct CacheLocation: Identifiable {
    let name: String
    let path: String
    let detail: String
    var size: Int64?
    var id: String { path }
    var exists: Bool { FileManager.default.fileExists(atPath: path) }
}

struct DevCleanerView: View {
    @State private var locations: [CacheLocation] = DevCleanerView.defaultLocations()
    @State private var scanning = false
    @State private var pending: CacheLocation?
    @State private var nodeModules: [SizedItem] = []
    @State private var scanningNode = false
    @State private var message = ""

    static func defaultLocations() -> [CacheLocation] {
        let h = NSHomeDirectory()
        return [
            CacheLocation(name: "Xcode DerivedData", path: h + "/Library/Developer/Xcode/DerivedData", detail: "Build products – Xcode recreates them"),
            CacheLocation(name: "Xcode Archives", path: h + "/Library/Developer/Xcode/Archives", detail: "Old app archives (keep ones you may need to re-upload)"),
            CacheLocation(name: "iOS Device Support", path: h + "/Library/Developer/Xcode/iOS DeviceSupport", detail: "Debug symbols for old iOS versions"),
            CacheLocation(name: "Simulator Caches", path: h + "/Library/Developer/CoreSimulator/Caches", detail: "Simulator dyld caches"),
            CacheLocation(name: "SwiftUI Previews", path: h + "/Library/Developer/Xcode/UserData/Previews", detail: "Preview simulators"),
            CacheLocation(name: "Swift Package Manager", path: h + "/Library/Caches/org.swift.swiftpm", detail: "Downloaded packages"),
            CacheLocation(name: "CocoaPods", path: h + "/Library/Caches/CocoaPods", detail: "Pod downloads"),
            CacheLocation(name: "Homebrew", path: h + "/Library/Caches/Homebrew", detail: "Downloaded bottles"),
            CacheLocation(name: "npm", path: h + "/.npm/_cacache", detail: "npm package cache"),
            CacheLocation(name: "Yarn", path: h + "/Library/Caches/Yarn", detail: "Yarn package cache"),
            CacheLocation(name: "pnpm store", path: h + "/Library/pnpm/store", detail: "pnpm content store"),
            CacheLocation(name: "pip", path: h + "/Library/Caches/pip", detail: "Python package cache"),
            CacheLocation(name: "Gradle", path: h + "/.gradle/caches", detail: "Gradle build cache"),
            CacheLocation(name: "Maven", path: h + "/.m2/repository", detail: "Maven artifacts"),
            CacheLocation(name: "Go build cache", path: h + "/Library/Caches/go-build", detail: "Compiled Go packages"),
            CacheLocation(name: "Cargo registry", path: h + "/.cargo/registry", detail: "Rust crate downloads"),
            CacheLocation(name: "Bun", path: h + "/.bun/install/cache", detail: "Bun package cache")
        ]
    }

    var body: some View {
        ToolPage(tool: .devCleaner) {
            Card(title: "Developer Caches", icon: "externaldrive.badge.minus") {
                HStack {
                    Button {
                        measure()
                    } label: {
                        Label("Measure Sizes", systemImage: "chart.bar")
                    }
                    if scanning { ProgressView().controlSize(.small) }
                    Spacer()
                    let total = locations.compactMap { $0.size }.reduce(Int64(0), +)
                    if total > 0 { Text("Total: \(Format.bytes(total))").bold() }
                }
                Text("Everything here is re-downloaded or rebuilt automatically when needed. Items are moved to the Trash.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !message.isEmpty { Text(message).font(.caption).foregroundColor(.accentColor) }
                ForEach(locations.filter { $0.exists }) { location in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(location.name).bold()
                            Text(location.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(location.size.map { Format.bytes($0) } ?? "—").monospacedDigit().foregroundStyle(.secondary)
                        Button {
                            Panels.reveal(URL(fileURLWithPath: location.path))
                        } label: {
                            Image(systemName: "magnifyingglass")
                        }
                        .buttonStyle(.borderless)
                        Button("Clean") { pending = location }
                    }
                    Divider()
                }
                HStack {
                    Button("Delete Unavailable Simulators") {
                        Shell.run("xcrun simctl delete unavailable") { result in
                            message = result.succeeded ? "Removed simulators for runtimes you no longer have." : result.combined
                        }
                    }
                    Text("Removes simulators whose iOS version is no longer installed.").font(.caption).foregroundStyle(.secondary)
                }
            }

            Card(title: "node_modules Finder", icon: "shippingbox") {
                HStack {
                    Button("Scan a Folder…") {
                        if let folder = Panels.chooseFolder(message: "Choose a folder containing your projects") { scanNodeModules(folder) }
                    }
                    if scanningNode { ProgressView().controlSize(.small) }
                    Spacer()
                    if !nodeModules.isEmpty {
                        Text("\(nodeModules.count) folders · \(Format.bytes(nodeModules.reduce(Int64(0)) { $0 + $1.size }))").bold()
                    }
                }
                Text("Old projects' node_modules folders can be deleted safely – run npm install to get them back.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(nodeModules) { item in
                    HStack {
                        Text(item.url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .lineLimit(1)
                            .truncationMode(.head)
                        Spacer()
                        Text(Format.bytes(item.size)).monospacedDigit().foregroundStyle(.secondary)
                        Button("Move to Trash") {
                            if (try? FileManager.default.trashItem(at: item.url, resultingItemURL: nil)) != nil {
                                nodeModules.removeAll { $0.url == item.url }
                            }
                        }
                    }
                }
            }
        }
        .onAppear { if locations.allSatisfy({ $0.size == nil }) { measure() } }
        .confirmationDialog("Clean \(pending?.name ?? "")?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            Button("Move Contents to Trash", role: .destructive) {
                if let location = pending { clean(location) }
                pending = nil
            }
        } message: {
            Text(pending?.path ?? "")
        }
    }

    private func measure() {
        scanning = true
        let current = locations
        DispatchQueue.global(qos: .userInitiated).async {
            let measured = current.map { location -> CacheLocation in
                var copy = location
                copy.size = location.exists ? AppFiles.size(of: URL(fileURLWithPath: location.path)) : nil
                return copy
            }
            DispatchQueue.main.async {
                locations = measured
                scanning = false
            }
        }
    }

    private func clean(_ location: CacheLocation) {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: URL(fileURLWithPath: location.path), includingPropertiesForKeys: nil)) ?? []
        var removed = 0
        for item in items where (try? fm.trashItem(at: item, resultingItemURL: nil)) != nil {
            removed += 1
        }
        message = "Moved \(removed) items from \(location.name) to the Trash."
        measure()
    }

    private func scanNodeModules(_ folder: URL) {
        scanningNode = true
        nodeModules = []
        DispatchQueue.global(qos: .userInitiated).async {
            var found: [SizedItem] = []
            let fm = FileManager.default
            if let enumerator = fm.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in true }) {
                for case let url as URL in enumerator {
                    guard url.lastPathComponent == "node_modules",
                          (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                    enumerator.skipDescendants()
                    found.append(SizedItem(url: url, size: AppFiles.size(of: url), isDirectory: true))
                }
            }
            found.sort { $0.size > $1.size }
            DispatchQueue.main.async {
                nodeModules = found
                scanningNode = false
            }
        }
    }
}
