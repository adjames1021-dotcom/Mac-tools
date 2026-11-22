import SwiftUI
import AppKit

/// Version details that build.sh writes into Info.plist.
struct BuildInfo {
    let sourceDir: String
    let sourceKind: String
    let commit: String
    let repo: String
    let branch: String
    let buildDate: Date?
    /// The MacTools version number from VERSION, e.g. "2.2".
    let version: String

    static let defaultRepo = "adjames1021-dotcom/Mac-tools"

    static var current: BuildInfo {
        let info = Bundle.main.infoDictionary ?? [:]
        func value(_ key: String) -> String { (info[key] as? String ?? "").trimmed }
        let repo = value("MTRepo")
        return BuildInfo(sourceDir: value("MTSourceDir"),
                         sourceKind: value("MTSourceKind"),
                         commit: value("MTCommit"),
                         repo: repo.isEmpty ? defaultRepo : repo,
                         branch: value("MTBranch"),
                         buildDate: ISO8601DateFormatter().date(from: value("MTBuildDate")),
                         version: value("MTVersion"))
    }

    var shortCommit: String { commit.isEmpty ? "unknown" : String(commit.prefix(7)) }
    var displayVersion: String { version.isEmpty ? "unknown" : version }
}

/// MacTools version numbers: +0.1 for a small update (2.2 → 2.3, 2.9 → 2.10),
/// the next whole number for a full one (2.7 → 3.0). See Scripts/bump-version.sh.
struct AppVersion: Comparable, CustomStringConvertible {
    let major: Int
    let minor: Int

    init(major: Int, minor: Int) {
        self.major = major
        self.minor = minor
    }

    init?(_ text: String) {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), let major = Int(parts[0]), major >= 0 else { return nil }
        var minor = 0
        if parts.count == 2 {
            guard let value = Int(parts[1]), value >= 0 else { return nil }
            minor = value
        }
        self.init(major: major, minor: minor)
    }

    var description: String { "\(major).\(minor)" }
    var nextSmall: AppVersion { AppVersion(major: major, minor: minor + 1) }
    var nextFull: AppVersion { AppVersion(major: major + 1, minor: 0) }

    static func < (a: AppVersion, b: AppVersion) -> Bool {
        (a.major, a.minor) < (b.major, b.minor)
    }
}

struct RemoteCommit: Identifiable, Equatable {
    let sha: String
    let message: String
    let date: Date?

    var id: String { sha }
    var title: String { message.components(separatedBy: "\n").first ?? message }
}

private final class DownloadBox {
    var url: URL?
    var error: Error?
    var status = 0
}

enum UpdateError: Error, LocalizedError {
    case badRepo
    case download(Int)
    case unzip(String)
    case buildFailed
    case noRelease

    var errorDescription: String? {
        switch self {
        case .badRepo: return "The repository name isn't valid (it should look like owner/name)."
        case .download(let code): return "Downloading the update failed (HTTP \(code))."
        case .unzip(let detail): return "Couldn't unpack the update. \(detail)"
        case .buildFailed: return "Building the new version failed – see the build log below. Your current version still works."
        case .noRelease: return "There's no ready-made version on GitHub yet. Use Build & Install instead."
        }
    }
}

/// Checks GitHub for new commits, downloads the source, rebuilds it and swaps the app in place.
final class UpdateManager: ObservableObject {
    static let shared = UpdateManager()

    enum Phase: Equatable {
        case idle, checking, upToDate, available, installing, ready
        case failed(String)
    }

    let build = BuildInfo.current

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var latest: RemoteCommit?
    /// The version number of `latest`, read from its VERSION file on GitHub.
    @Published private(set) var latestVersion: String?
    @Published private(set) var newCommits: [RemoteCommit] = []
    @Published private(set) var log = ""
    @Published private(set) var step = ""
    @Published private(set) var lastChecked: Date?
    @Published var autoCheck: Bool {
        didSet {
            UserDefaults.standard.set(autoCheck, forKey: "updateAutoCheck")
            scheduleTimer()
        }
    }
    @Published var autoInstall: Bool {
        didSet { UserDefaults.standard.set(autoInstall, forKey: "updateAutoInstall") }
    }
    @Published var repo: String {
        didSet { UserDefaults.standard.set(repo, forKey: "updateRepo") }
    }
    @Published var branch: String {
        didSet { UserDefaults.standard.set(branch, forKey: "updateBranch") }
    }

    private var timer: Timer?
    private var installedCommit: String?

    private init() {
        let defaults = UserDefaults.standard
        let info = BuildInfo.current
        autoCheck = defaults.object(forKey: "updateAutoCheck") as? Bool ?? true
        autoInstall = defaults.object(forKey: "updateAutoInstall") as? Bool ?? false
        repo = defaults.string(forKey: "updateRepo") ?? info.repo
        branch = defaults.string(forKey: "updateBranch") ?? info.branch
        lastChecked = defaults.object(forKey: "updateLastChecked") as? Date
    }

    var currentCommit: String { installedCommit ?? build.commit }

    var updateAvailable: Bool { phase == .available }

    var isInstalling: Bool { phase == .installing }

    // MARK: Scheduling

    func start() {
        scheduleTimer()
        if autoCheck {
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                self?.check(userInitiated: false)
            }
        }
    }

    private func scheduleTimer() {
        timer?.invalidate()
        timer = nil
        guard autoCheck else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if let last = self.lastChecked, Date().timeIntervalSince(last) < 6 * 3600 { return }
            self.check(userInitiated: false)
        }
    }

    // MARK: Checking

    func check(userInitiated: Bool = true) {
        if phase == .checking || phase == .installing { return }
        phase = .checking
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.github.com"
        components.path = "/repos/\(repo.trimmed)/commits"
        var query = [URLQueryItem(name: "per_page", value: "50")]
        if !branch.trimmed.isEmpty { query.append(URLQueryItem(name: "sha", value: branch.trimmed)) }
        components.queryItems = query
        guard let url = components.url else {
            phase = .failed(UpdateError.badRepo.errorDescription ?? "")
            return
        }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MacTools-Updater", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            DispatchQueue.main.async {
                self?.handleCheck(data: data, status: status, error: error, userInitiated: userInitiated)
            }
        }.resume()
    }

    private func handleCheck(data: Data?, status: Int, error: Error?, userInitiated: Bool) {
        let now = Date()
        lastChecked = now
        UserDefaults.standard.set(now, forKey: "updateLastChecked")
        if let error = error {
            phase = .failed("Couldn't reach GitHub: \(error.localizedDescription)")
            return
        }
        guard status == 200, let data = data,
              let array = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            if status == 403 || status == 429 {
                phase = .failed("GitHub's rate limit was reached. Try again in a little while.")
            } else {
                phase = .failed("GitHub returned an error (\(status)). Check the repository and branch under Advanced.")
            }
            return
        }
        let iso = ISO8601DateFormatter()
        let commits = array.compactMap { (item: [String: Any]) -> RemoteCommit? in
            guard let sha = item["sha"] as? String else { return nil }
            let commit = item["commit"] as? [String: Any]
            let message = commit?["message"] as? String ?? ""
            let committer = commit?["committer"] as? [String: Any]
            let date = (committer?["date"] as? String).flatMap { iso.date(from: $0) }
            return RemoteCommit(sha: sha, message: message, date: date)
        }
        guard let newest = commits.first else {
            phase = .failed("No versions were found on GitHub.")
            return
        }
        latest = newest
        fetchVersion(sha: newest.sha)
        if newest.sha == currentCommit {
            newCommits = []
            phase = installedCommit == nil ? .upToDate : .ready
            return
        }
        if let index = commits.firstIndex(where: { $0.sha == currentCommit }) {
            newCommits = Array(commits[..<index])
        } else {
            newCommits = commits
        }
        phase = .available
        if !userInitiated {
            if autoInstall {
                install()
            } else if UserDefaults.standard.string(forKey: "updateNotifiedSHA") != newest.sha {
                UserDefaults.standard.set(newest.sha, forKey: "updateNotifiedSHA")
                Shell.notify("A MacTools update is available. Open MacTools ▸ Updates to install it.")
            }
        }
    }

    /// Reads the VERSION file of a commit so the update can be shown as "2.3" rather than a commit id.
    private func fetchVersion(sha: String) {
        latestVersion = nil
        let parts = repo.trimmed.split(separator: "/")
        guard parts.count == 2,
              let url = URL(string: "https://raw.githubusercontent.com/\(parts[0])/\(parts[1])/\(sha)/VERSION") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("MacTools-Updater", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let text = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            DispatchQueue.main.async {
                guard let self = self, self.latest?.sha == sha else { return }
                self.latestVersion = status == 200 ? AppVersion(text)?.description : nil
            }
        }.resume()
    }

    // MARK: Installing

    func install() {
        if phase == .installing || phase == .checking { return }
        guard let target = latest else {
            check()
            return
        }
        phase = .installing
        log = ""
        step = "Getting the new version…"
        let info = build
        let repoName = repo.trimmed
        let appPath = Bundle.main.bundlePath
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                let source = try self.prepareSource(info: info, repo: repoName, sha: target.sha)
                self.setStep("Building the new version – this takes a minute or two…")
                let status = self.runBuild(in: source, commit: target.sha, dest: appPath)
                guard status == 0 else { throw UpdateError.buildFailed }
                DispatchQueue.main.async {
                    self.installedCommit = target.sha
                    self.newCommits = []
                    self.phase = .ready
                    self.step = "Update installed. Restart MacTools to start using it."
                    Shell.notify("MacTools has been updated. Restart it to use the new version.")
                }
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                DispatchQueue.main.async {
                    self.phase = .failed(message)
                    self.step = ""
                }
            }
        }
    }

    /// Name of the zipped app attached to each GitHub release (see Scripts/publish-release.sh).
    static let releaseAsset = "MacTools.zip"

    /// Downloads the ready-made app from the newest GitHub release and swaps it in – no compiling.
    func installDownload() {
        if phase == .installing || phase == .checking { return }
        phase = .installing
        log = ""
        step = "Downloading the ready-made version…"
        let repoName = repo.trimmed
        let appPath = Bundle.main.bundlePath
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                let commit = try self.downloadRelease(repo: repoName, replacing: appPath)
                DispatchQueue.main.async {
                    self.installedCommit = commit.isEmpty ? nil : commit
                    self.newCommits = []
                    self.phase = .ready
                    self.step = "Update installed. Restart MacTools to start using it."
                    Shell.notify("MacTools has been updated. Restart it to use the new version.")
                }
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                DispatchQueue.main.async {
                    self.phase = .failed(message)
                    self.step = ""
                }
            }
        }
    }

    /// Fetches the latest release's MacTools.zip, unpacks it and replaces the app. Returns the new app's commit.
    private func downloadRelease(repo: String, replacing appPath: String) throws -> String {
        let fm = FileManager.default
        guard repo.split(separator: "/").count == 2,
              let api = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { throw UpdateError.badRepo }
        appendLog("Looking up the latest release of \(repo)…\n")
        let json = try download(api)
        defer { try? fm.removeItem(at: json) }
        guard let data = try? Data(contentsOf: json),
              let release = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let assets = release["assets"] as? [[String: Any]],
              let asset = assets.first(where: { $0["name"] as? String == Self.releaseAsset }),
              let link = asset["browser_download_url"] as? String, let url = URL(string: link),
              url.host == "github.com" || url.host?.hasSuffix(".githubusercontent.com") == true else {
            throw UpdateError.noRelease
        }
        appendLog("Downloading \(release["tag_name"] as? String ?? "") from \(link)\n")
        let zip = try download(url)
        defer { try? fm.removeItem(at: zip) }

        let staging = DataStore.directory.appendingPathComponent("Download.new", isDirectory: true)
        try? fm.removeItem(at: staging)
        defer { try? fm.removeItem(at: staging) }
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        let unzip = Shell.runSync("/usr/bin/ditto", ["-x", "-k", zip.path, staging.path])
        guard unzip.succeeded else { throw UpdateError.unzip(unzip.combined) }
        let app = staging.appendingPathComponent("MacTools.app")
        // Only ever swap in MacTools itself, with an intact signature.
        guard let bundle = Bundle(url: app), bundle.bundleIdentifier == Bundle.main.bundleIdentifier else {
            throw UpdateError.unzip("The download didn't contain MacTools.")
        }
        let verify = Shell.runSync("/usr/bin/codesign", ["--verify", "--deep", app.path])
        guard verify.succeeded else { throw UpdateError.unzip("The downloaded app's signature is broken. \(verify.combined)") }
        _ = Shell.runSync("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
        // Same swap as build.sh: copy next to the app, then replace it.
        let script = "rm -rf \"$1.new\" && /usr/bin/ditto \"$0\" \"$1.new\" && rm -rf \"$1\" && mv \"$1.new\" \"$1\""
        let swap = Shell.runSync("/bin/sh", ["-c", script, app.path, appPath])
        guard swap.succeeded else { throw UpdateError.unzip("Couldn't replace the app: \(swap.combined)") }
        appendLog("Installed to \(appPath)\n")
        return (bundle.infoDictionary?["MTCommit"] as? String ?? "").trimmed
    }

    private func setStep(_ text: String) {
        DispatchQueue.main.async { self.step = text }
    }

    private func appendLog(_ text: String) {
        DispatchQueue.main.async {
            self.log += text
            if self.log.count > 200_000 { self.log = String(self.log.suffix(200_000)) }
        }
    }

    /// Returns a folder containing the new source code (git pull, or a fresh download).
    private func prepareSource(info: BuildInfo, repo: String, sha: String) throws -> URL {
        let fm = FileManager.default
        if info.sourceKind == "git", !info.sourceDir.isEmpty, fm.fileExists(atPath: info.sourceDir + "/.git") {
            appendLog("Updating the git checkout at \(info.sourceDir)…\n")
            let env = ["GIT_TERMINAL_PROMPT": "0"]
            let pull = Shell.runSync("/usr/bin/git", ["-C", info.sourceDir, "pull", "--ff-only"], environment: env)
            appendLog(pull.combined + "\n")
            let head = Shell.runSync("/usr/bin/git", ["-C", info.sourceDir, "rev-parse", "HEAD"]).output.trimmed
            if pull.succeeded && head == sha {
                return URL(fileURLWithPath: info.sourceDir)
            }
            appendLog("The git checkout isn't on the update branch – downloading a fresh copy instead.\n")
        }

        let parts = repo.split(separator: "/")
        guard parts.count == 2, let url = URL(string: "https://codeload.github.com/\(parts[0])/\(parts[1])/zip/\(sha)") else {
            throw UpdateError.badRepo
        }
        appendLog("Downloading \(url.absoluteString)\n")
        let zip = try download(url)
        defer { try? fm.removeItem(at: zip) }

        let base = DataStore.directory
        let staging = base.appendingPathComponent("Source.new", isDirectory: true)
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        let unzip = Shell.runSync("/usr/bin/ditto", ["-x", "-k", zip.path, staging.path])
        guard unzip.succeeded else { throw UpdateError.unzip(unzip.combined) }
        let contents = (try? fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)) ?? []
        guard let folder = contents.first(where: { fm.fileExists(atPath: $0.appendingPathComponent("build.sh").path) }) else {
            throw UpdateError.unzip("The download didn't contain MacTools' source code.")
        }
        let source = base.appendingPathComponent("Source", isDirectory: true)
        try? fm.removeItem(at: source)
        try fm.moveItem(at: folder, to: source)
        try? fm.removeItem(at: staging)
        appendLog("Source saved to \(source.path)\n")
        return source
    }

    private func download(_ url: URL) throws -> URL {
        let semaphore = DispatchSemaphore(value: 0)
        let box = DownloadBox()
        var request = URLRequest(url: url)
        request.timeoutInterval = 120
        URLSession.shared.downloadTask(with: request) { location, response, error in
            box.status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if let location = location {
                let dest = FileManager.default.temporaryDirectory.appendingPathComponent("mactools-update-\(UUID().uuidString).zip")
                do {
                    try FileManager.default.moveItem(at: location, to: dest)
                    box.url = dest
                } catch {
                    box.error = error
                }
            } else {
                box.error = error
            }
            semaphore.signal()
        }.resume()
        semaphore.wait()
        if let error = box.error { throw error }
        guard box.status == 200, let file = box.url else { throw UpdateError.download(box.status) }
        return file
    }

    /// Runs build.sh, streaming its output into the log. Returns the exit status.
    private func runBuild(in dir: URL, commit: String, dest: String) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [dir.appendingPathComponent("build.sh").path, "--force", "--no-quit", "--dest", dest]
        process.currentDirectoryURL = dir
        var environment = ProcessInfo.processInfo.environment
        environment["MACTOOLS_COMMIT"] = commit
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self?.appendLog(String(decoding: data, as: UTF8.self))
        }
        do {
            try process.run()
        } catch {
            appendLog("Couldn't start the build: \(error.localizedDescription)\n")
            return -1
        }
        process.waitUntilExit()
        Thread.sleep(forTimeInterval: 0.3)
        pipe.fileHandleForReading.readabilityHandler = nil
        return process.terminationStatus
    }

    // MARK: Relaunching

    func relaunch() {
        relaunch(at: Bundle.main.bundlePath)
    }

    private func relaunch(at path: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1.5; /usr/bin/open \"$0\"", path]
        try? task.run()
        NSApp.terminate(nil)
    }

    var isInApplicationsFolder: Bool {
        let path = Bundle.main.bundlePath
        return path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/")
    }

    /// Copies the app into /Applications (or ~/Applications) and relaunches from there.
    func moveToApplications() {
        var folder = "/Applications"
        if !FileManager.default.isWritableFile(atPath: folder) {
            folder = NSHomeDirectory() + "/Applications"
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        }
        let dest = folder + "/MacTools.app"
        let script = "rm -rf \"$1.new\" && /usr/bin/ditto \"$0\" \"$1.new\" && rm -rf \"$1\" && mv \"$1.new\" \"$1\""
        let result = Shell.runSync("/bin/sh", ["-c", script, Bundle.main.bundlePath, dest])
        if result.succeeded {
            relaunch(at: dest)
        } else {
            phase = .failed("Couldn't copy MacTools to \(folder): \(result.combined)")
        }
    }
}

struct UpdatesView: View {
    @ObservedObject private var updater = UpdateManager.shared
    @State private var showAdvanced = false

    var body: some View {
        ToolPage(tool: .updates) {
            Card(title: "This Version", icon: "shippingbox") {
                InfoRow(label: "Version", value: updater.build.displayVersion)
                InfoRow(label: "Commit", value: updater.build.shortCommit)
                if let date = updater.build.buildDate {
                    InfoRow(label: "Built", value: date.formatted(date: .abbreviated, time: .shortened), copyable: false)
                }
                InfoRow(label: "App location", value: Bundle.main.bundlePath)
                InfoRow(label: "Source code", value: updater.build.sourceKind == "git"
                        ? "git checkout at \(updater.build.sourceDir)"
                        : (updater.build.sourceDir.isEmpty ? "unknown" : updater.build.sourceDir))
                if !updater.isInApplicationsFolder {
                    HStack {
                        Button("Move to Applications Folder") { updater.moveToApplications() }
                        Text("So you can open MacTools from Launchpad and Spotlight. Updates go there too.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Card(title: "Updates", icon: "arrow.down.circle") {
                HStack(spacing: 10) {
                    statusIcon
                    VStack(alignment: .leading, spacing: 2) {
                        Text(statusTitle).font(.headline)
                        if !updater.step.isEmpty {
                            Text(updater.step).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if updater.phase == .installing || updater.phase == .checking {
                        ProgressView().controlSize(.small)
                    }
                }
                HStack {
                    Button("Check Now") { updater.check() }
                        .disabled(updater.phase == .checking || updater.isInstalling)
                    if updater.phase == .available || isFailedWithLatest {
                        Button {
                            updater.install()
                        } label: {
                            Label("Build & Install", systemImage: "hammer.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .help("Downloads the source code and compiles it on this Mac (needs the Command Line Tools)")
                    }
                    if updater.phase != .ready {
                        Button {
                            updater.installDownload()
                        } label: {
                            Label("Download Ready-Made", systemImage: "arrow.down.circle.fill")
                        }
                        .disabled(updater.phase == .checking || updater.isInstalling)
                        .help("Downloads the already-built app from the latest GitHub release – no compiling, takes seconds")
                    }
                    if updater.phase == .ready {
                        Button {
                            updater.relaunch()
                        } label: {
                            Label("Restart MacTools", systemImage: "arrow.clockwise.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Spacer()
                    if let checked = updater.lastChecked {
                        Text("Last checked \(checked.formatted(date: .omitted, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle("Check for updates automatically", isOn: $updater.autoCheck)
                Toggle("Install updates automatically in the background", isOn: $updater.autoInstall)
                Text("Build & Install downloads the newest code from GitHub and compiles it on this Mac. Download Ready-Made grabs the already-built app from the latest GitHub release instead – quicker, but it can be behind the newest code. Either way MacTools swaps itself in place and keeps your settings, macros and permissions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Version numbers go up by 0.1 for each small update (2.2 → 2.3) and to the next whole number for a full update (2.x → 3.0).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            #if !LITE
            LiteUSBCard()
            #endif

            if !updater.newCommits.isEmpty {
                Card(title: updater.latestVersion.map { "What's New in \($0)" } ?? "What's New (\(updater.newCommits.count))", icon: "sparkles") {
                    ForEach(updater.newCommits.prefix(40)) { commit in
                        HStack(alignment: .firstTextBaseline) {
                            Text("•")
                            Text(commit.title)
                            Spacer()
                            if let date = commit.date {
                                Text(date.formatted(date: .abbreviated, time: .omitted))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            if !updater.log.isEmpty {
                Card(title: "Build Log", icon: "terminal") {
                    OutputBox(text: updater.log, minHeight: 120, maxHeight: 300)
                }
            }

            DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Repository").frame(width: 90, alignment: .leading)
                        TextField("owner/name", text: $updater.repo).textFieldStyle(.roundedBorder)
                    }
                    HStack {
                        Text("Branch").frame(width: 90, alignment: .leading)
                        TextField("Leave empty for the default branch", text: $updater.branch).textFieldStyle(.roundedBorder)
                    }
                    Button("Reinstall Latest Version") {
                        updater.check()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { updater.install() }
                    }
                    .help("Downloads and rebuilds the newest version even if you already have it")
                }
                .padding(.top, 6)
            }
        }
    }

    private var isFailedWithLatest: Bool {
        if case .failed = updater.phase { return updater.latest != nil && updater.latest?.sha != updater.currentCommit }
        return false
    }

    private var statusTitle: String {
        switch updater.phase {
        case .idle: return "Not checked yet"
        case .checking: return "Checking for updates…"
        case .upToDate: return updater.build.version.isEmpty ? "MacTools is up to date" : "MacTools \(updater.build.version) is up to date"
        case .available:
            if let version = updater.latestVersion { return "MacTools \(version) is available" }
            return "An update is available" + (updater.latest.map { " (\(String($0.sha.prefix(7))))" } ?? "")
        case .installing: return updater.latestVersion.map { "Installing MacTools \($0)…" } ?? "Installing update…"
        case .ready: return updater.latestVersion.map { "MacTools \($0) installed – restart to finish" } ?? "Update installed – restart to finish"
        case .failed(let message): return message
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch updater.phase {
        case .upToDate:
            Image(systemName: "checkmark.seal.fill").foregroundColor(.green).font(.title)
        case .available, .ready:
            Image(systemName: "arrow.down.circle.fill").foregroundColor(.accentColor).font(.title)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange).font(.title)
        default:
            Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.secondary).font(.title)
        }
    }
}
