import SwiftUI
import AppKit

// MARK: - Chrome DevTools Protocol: pure parsing (unit-testable, no I/O)

/// A debuggable target reported by Chrome's /json endpoint (a tab, iframe, worker…).
struct CDPTarget: Identifiable, Hashable {
    let id: String
    let type: String
    let title: String
    let url: String
    let webSocketDebuggerURL: String

    /// Pages and iframes are the targets worth inspecting a document in.
    var isInspectablePage: Bool { (type == "page" || type == "iframe") && !webSocketDebuggerURL.isEmpty }

    var displayTitle: String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
        return url.isEmpty ? "(untitled)" : url
    }
}

enum CDPParse {
    /// Parses the JSON array returned by http://127.0.0.1:PORT/json.
    static func targets(from data: Data) -> [CDPTarget] {
        guard let array = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        return array.compactMap { object in
            guard let id = object["id"] as? String else { return nil }
            return CDPTarget(
                id: id,
                type: (object["type"] as? String) ?? "",
                title: (object["title"] as? String) ?? "",
                url: (object["url"] as? String) ?? "",
                webSocketDebuggerURL: (object["webSocketDebuggerUrl"] as? String) ?? ""
            )
        }
    }
}

/// One node of the inspected document, mirrored from CDP's DOM.Node shape.
final class DOMNode: Identifiable, ObservableObject {
    let id = UUID()
    let nodeId: Int
    let backendNodeId: Int
    let nodeType: Int
    let nodeName: String
    let localName: String
    var nodeValue: String
    var attributes: [(name: String, value: String)]
    let childNodeCount: Int
    var children: [DOMNode]
    weak var parent: DOMNode?

    init(nodeId: Int, backendNodeId: Int, nodeType: Int, nodeName: String, localName: String,
         nodeValue: String, attributes: [(name: String, value: String)], childNodeCount: Int, children: [DOMNode]) {
        self.nodeId = nodeId
        self.backendNodeId = backendNodeId
        self.nodeType = nodeType
        self.nodeName = nodeName
        self.localName = localName
        self.nodeValue = nodeValue
        self.attributes = attributes
        self.childNodeCount = childNodeCount
        self.children = children
    }

    var isElement: Bool { nodeType == 1 }
    var tag: String { (localName.isEmpty ? nodeName : localName).lowercased() }

    /// For OutlineGroup: nil collapses the row, an array makes it expandable.
    var outlineChildren: [DOMNode]? { children.isEmpty ? nil : children }

    var idAttribute: String? { attributes.first(where: { $0.name == "id" })?.value }
    var classAttribute: String? { attributes.first(where: { $0.name == "class" })?.value }

    /// A short "div#main.row" style label for the tree and breadcrumbs.
    var summary: String {
        switch nodeType {
        case 1:
            var s = tag
            if let id = idAttribute, !id.isEmpty { s += "#" + id }
            if let cls = classAttribute, !cls.isEmpty {
                let names = cls.split(separator: " ").prefix(2).map { "." + $0 }.joined()
                s += names
            }
            return s
        case 3:
            let text = nodeValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? "\"\"" : "“" + String(text.prefix(40)) + "”"
        case 8: return "<!-- comment -->"
        case 9: return "#document"
        case 10: return "<!DOCTYPE \(nodeName.lowercased())>"
        default: return nodeName.lowercased()
        }
    }
}

enum DOMParse {
    /// CDP sends attributes as a flat [name, value, name, value, …] array.
    static func attributes(from flat: [Any]) -> [(name: String, value: String)] {
        var out: [(String, String)] = []
        var index = 0
        while index + 1 < flat.count {
            let name = (flat[index] as? String) ?? ""
            let value = (flat[index + 1] as? String) ?? ""
            out.append((name, value))
            index += 2
        }
        return out
    }

    /// Builds a DOMNode tree from a CDP DOM.Node dictionary.
    static func node(from dict: [String: Any], parent: DOMNode? = nil) -> DOMNode {
        let node = DOMNode(
            nodeId: (dict["nodeId"] as? Int) ?? 0,
            backendNodeId: (dict["backendNodeId"] as? Int) ?? 0,
            nodeType: (dict["nodeType"] as? Int) ?? 0,
            nodeName: (dict["nodeName"] as? String) ?? "",
            localName: (dict["localName"] as? String) ?? "",
            nodeValue: (dict["nodeValue"] as? String) ?? "",
            attributes: attributes(from: (dict["attributes"] as? [Any]) ?? []),
            childNodeCount: (dict["childNodeCount"] as? Int) ?? 0,
            children: []
        )
        node.parent = parent
        var kids: [DOMNode] = []
        for child in (dict["children"] as? [[String: Any]]) ?? [] {
            kids.append(DOMParse.node(from: child, parent: node))
        }
        // The content document of an <iframe> is exposed separately.
        if let frameDoc = dict["contentDocument"] as? [String: Any] {
            kids.append(DOMParse.node(from: frameDoc, parent: node))
        }
        node.children = kids
        return node
    }

    /// Depth-first search for a node by its CDP nodeId.
    static func find(_ nodeId: Int, in root: DOMNode) -> DOMNode? {
        if root.nodeId == nodeId { return root }
        for child in root.children {
            if let hit = find(nodeId, in: child) { return hit }
        }
        return nil
    }

    /// backendNodeId survives DOM.getDocument (nodeIds don't), so it finds the same element in a reloaded tree.
    static func find(backendNodeId: Int, in root: DOMNode) -> DOMNode? {
        if backendNodeId != 0 && root.backendNodeId == backendNodeId { return root }
        for child in root.children {
            if let hit = find(backendNodeId: backendNodeId, in: child) { return hit }
        }
        return nil
    }

    /// Child indexes from the root down to `node`.
    static func path(of node: DOMNode) -> [Int] {
        var path: [Int] = []
        var current = node
        while let parent = current.parent, let index = parent.children.firstIndex(where: { $0 === current }) {
            path.insert(index, at: 0)
            current = parent
        }
        return path
    }

    /// Follows a path from `path(of:)` in another tree, as far as it still exists.
    static func node(at path: [Int], in root: DOMNode) -> DOMNode? {
        var current = root
        for index in path {
            guard index < current.children.count else { return nil }
            current = current.children[index]
        }
        return current
    }
}

// MARK: - CDP connection (callback based, state on the main thread)

enum CDPError: LocalizedError {
    case protocolError(String)
    case disconnected
    case badResponse

    var errorDescription: String? {
        switch self {
        case .protocolError(let message): return message
        case .disconnected: return "The debugger connection closed."
        case .badResponse: return "The debugger sent a response that couldn't be read."
        }
    }
}

/// A single WebSocket connection to one CDP target. All completions and events fire on the main thread.
final class CDPConnection: NSObject {
    private let task: URLSessionWebSocketTask
    private let session: URLSession
    private var nextId = 1
    private var pending: [Int: (Result<[String: Any], Error>) -> Void] = [:]
    private var alive = true
    /// Whether any message ever arrived; a socket that drops before that was refused.
    private(set) var receivedAny = false

    /// Called for every event message (method + params), on the main thread.
    var onEvent: ((String, [String: Any]) -> Void)?
    /// Called once when the socket drops.
    var onClose: (() -> Void)?

    init(webSocketURL: URL) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        // The debugger is strictly on loopback; never route it through a proxy.
        config.connectionProxyDictionary = [:]
        session = URLSession(configuration: config)
        task = session.webSocketTask(with: webSocketURL)
        // Whole-document snapshots of big pages are far larger than the 1 MB default.
        task.maximumMessageSize = 256 * 1024 * 1024
        super.init()
    }

    func connect() {
        task.resume()
        receive()
    }

    func close() {
        guard alive else { return }
        alive = false
        task.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
        let drop = pending
        pending.removeAll()
        for (_, handler) in drop { handler(.failure(CDPError.disconnected)) }
    }

    /// Sends a CDP command and delivers the `result` object (or an error) on the main thread.
    func send(_ method: String, _ params: [String: Any] = [:], completion: ((Result<[String: Any], Error>) -> Void)? = nil) {
        guard alive else { completion?(.failure(CDPError.disconnected)); return }
        let id = nextId
        nextId += 1
        if let completion = completion { pending[id] = completion }
        var message: [String: Any] = ["id": id, "method": method]
        if !params.isEmpty { message["params"] = params }
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let text = String(data: data, encoding: .utf8) else {
            pending[id] = nil
            completion?(.failure(CDPError.badResponse))
            return
        }
        task.send(.string(text)) { [weak self] error in
            guard let error = error else { return }
            DispatchQueue.main.async {
                guard let self = self, let handler = self.pending.removeValue(forKey: id) else { return }
                handler(.failure(error))
            }
        }
    }

    private func receive() {
        task.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure:
                DispatchQueue.main.async { self.handleDrop() }
            case .success(let message):
                let text: String
                switch message {
                case .string(let s): text = s
                case .data(let d): text = String(decoding: d, as: UTF8.self)
                @unknown default: text = ""
                }
                DispatchQueue.main.async { self.dispatch(text) }
                self.receive()
            }
        }
    }

    private func handleDrop() {
        guard alive else { return }
        alive = false
        let drop = pending
        pending.removeAll()
        for (_, handler) in drop { handler(.failure(CDPError.disconnected)) }
        onClose?()
    }

    private func dispatch(_ text: String) {
        receivedAny = true
        guard let data = text.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        if let id = object["id"] as? Int {
            guard let handler = pending.removeValue(forKey: id) else { return }
            if let error = object["error"] as? [String: Any] {
                handler(.failure(CDPError.protocolError((error["message"] as? String) ?? "Unknown CDP error")))
            } else {
                handler(.success((object["result"] as? [String: Any]) ?? [:]))
            }
        } else if let method = object["method"] as? String {
            onEvent?(method, (object["params"] as? [String: Any]) ?? [:])
        }
    }
}

// MARK: - Launching / discovering a debuggable browser

/// A Chromium-family browser MacTools can drive over CDP.
struct DebugBrowser: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let supportPath: String   // relative to ~/Library/Application Support
    let bundleID: String

    static let all: [DebugBrowser] = [
        DebugBrowser(name: "Google Chrome", supportPath: "Google/Chrome", bundleID: "com.google.Chrome"),
        DebugBrowser(name: "Chrome Beta", supportPath: "Google/Chrome Beta", bundleID: "com.google.Chrome.beta"),
        DebugBrowser(name: "Chrome Canary", supportPath: "Google/Chrome Canary", bundleID: "com.google.Chrome.canary"),
        DebugBrowser(name: "Chromium", supportPath: "Chromium", bundleID: "org.chromium.Chromium"),
        DebugBrowser(name: "Microsoft Edge", supportPath: "Microsoft Edge", bundleID: "com.microsoft.edgemac"),
        DebugBrowser(name: "Brave", supportPath: "BraveSoftware/Brave-Browser", bundleID: "com.brave.Browser"),
        DebugBrowser(name: "Vivaldi", supportPath: "Vivaldi", bundleID: "com.vivaldi.Vivaldi"),
    ]

    var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// The browser's own user-data folder (holds Local State and the profile folders).
    var dataURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent(supportPath)
    }

    /// The names people gave their profiles ("Work", "School"…), keyed by folder, from Local State.
    func profileNames() -> [String: String] {
        guard let data = try? Data(contentsOf: dataURL.appendingPathComponent("Local State")),
              let state = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let cache = (state["profile"] as? [String: Any])?["info_cache"] as? [String: Any] else { return [:] }
        var names: [String: String] = [:]
        for (folder, info) in cache {
            if let name = (info as? [String: Any])?["name"] as? String, !name.isEmpty { names[folder] = name }
        }
        return names
    }

    /// Profile folders (Default, Profile 1…) found on disk for this browser.
    func profiles() -> [String] {
        let fm = FileManager.default
        let base = dataURL
        var found: [String] = []
        let entries = (try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for entry in entries {
            let name = entry.lastPathComponent
            if name == "Default" || name.hasPrefix("Profile ") {
                if fm.fileExists(atPath: entry.appendingPathComponent("Preferences").path) { found.append(name) }
            }
        }
        return found.sorted { ($0 == "Default" ? "" : $0) < ($1 == "Default" ? "" : $1) }
    }
}

enum CDPLauncher {
    static let defaultPort = 9222

    /// Fetches the debuggable targets from a running browser's debug port.
    static func fetchTargets(port: Int, completion: @escaping (Result<[CDPTarget], Error>) -> Void) {
        guard let url = URL(string: "http://127.0.0.1:\(port)/json") else {
            completion(.failure(CDPError.badResponse)); return
        }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 4
        config.connectionProxyDictionary = [:]
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config)
        session.dataTask(with: url) { data, _, error in
            DispatchQueue.main.async {
                if let error = error { completion(.failure(error)); return }
                guard let data = data else { completion(.failure(CDPError.badResponse)); return }
                completion(.success(CDPParse.targets(from: data)))
            }
            session.finishTasksAndInvalidate()
        }.resume()
    }

    /// Asks the debug port for a new blank tab.
    static func openTab(port: Int, url: String = "about:blank") {
        guard let endpoint = URL(string: "http://127.0.0.1:\(port)/json/new?\(url)") else { return }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "PUT" // Chrome refuses GET here
        request.timeoutInterval = 4
        URLSession.shared.dataTask(with: request).resume()
    }

    /// Where the debug copy of a profile lives.
    static func debugCopyURL(_ browser: DebugBrowser, profile: String) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("MacTools/InspectorProfiles/\(browser.bundleID)/\(profile)")
    }

    /// Big, rebuildable folders left out of a debug copy so it stays quick to refresh.
    static let copyExclusions = ["Cache", "Code Cache", "GPUCache", "DawnGraphiteCache", "DawnWebGPUCache",
                                 "GrShaderCache", "ShaderCache", "Service Worker", "IndexedDB", "Singleton*"]

    /// Refreshes the debug copy of `profile` from the real one (bookmarks, cookies, logins, extensions).
    /// Chrome's cookie/password key lives in the Keychain, not the folder, so sign-ins carry over.
    static func syncDebugCopy(_ browser: DebugBrowser, profile: String, into copy: URL) -> String? {
        let fm = FileManager.default
        let source = browser.dataURL.appendingPathComponent(profile)
        guard fm.fileExists(atPath: source.path) else { return nil } // nothing to copy: a fresh profile
        try? fm.createDirectory(at: copy.appendingPathComponent(profile), withIntermediateDirectories: true)
        let localState = browser.dataURL.appendingPathComponent("Local State")
        if fm.fileExists(atPath: localState.path) {
            try? fm.removeItem(at: copy.appendingPathComponent("Local State"))
            try? fm.copyItem(at: localState, to: copy.appendingPathComponent("Local State"))
        }
        let args = ["-a", "--delete"] + copyExclusions.map { "--exclude=\($0)" }
            + [source.path + "/", copy.appendingPathComponent(profile).path + "/"]
        let result = Shell.runSync("/usr/bin/rsync", args)
        return result.succeeded ? nil : "Couldn't copy the profile: \(result.combined)"
    }

    /// A fresh, empty user-data folder with no account bound to the browser. Signing into a managed
    /// account's websites here doesn't pull down its cloud policy, so a school's "developer tools off"
    /// rule (which only applies to the managed browser profile) doesn't block the inspector.
    static func freshProfileURL(_ browser: DebugBrowser) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("MacTools/InspectorProfiles/\(browser.bundleID)/__signed_out__")
    }

    /// Quits the browser (if running), then relaunches it for the chosen profile with the debug port open.
    /// `debugCopy` runs a copy of the profile in its own folder instead: Chrome 136+ only allows remote
    /// debugging outside its default folder, and the user's normal browser keeps running untouched.
    /// `freshProfile` opens an empty, signed-out profile for when the chosen one is locked down by policy.
    static func relaunch(_ browser: DebugBrowser, profile: String, port: Int, debugCopy: Bool,
                         freshProfile: Bool = false, completion: @escaping (String?) -> Void) {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.bundleID) else {
            completion("\(browser.name) isn't installed."); return
        }
        var arguments = ["--remote-debugging-port=\(port)", "--remote-debugging-address=127.0.0.1"]
        let profileFolder = profile.isEmpty ? "Default" : profile
        let copyURL = debugCopyURL(browser, profile: profileFolder)
        if freshProfile {
            try? FileManager.default.createDirectory(at: freshProfileURL(browser), withIntermediateDirectories: true)
            arguments += ["--user-data-dir=\(freshProfileURL(browser).path)", "--no-first-run", "--no-default-browser-check"]
        } else if debugCopy {
            arguments += ["--user-data-dir=\(copyURL.path)", "--profile-directory=\(profileFolder)"]
        } else if !profile.isEmpty {
            arguments.append("--profile-directory=\(profile)")
        }

        func launch() {
            let config = NSWorkspace.OpenConfiguration()
            config.arguments = arguments
            // A separate profile runs as a second Chrome next to the user's; otherwise macOS just activates
            // the running Chrome and drops the debugging flags.
            config.createsNewApplicationInstance = debugCopy || freshProfile
            NSWorkspace.shared.openApplication(at: appURL, configuration: config) { _, error in
                DispatchQueue.main.async { completion(error?.localizedDescription) }
            }
        }

        // Chrome can take several seconds to close its windows; relaunching earlier reuses the old process.
        func waitForQuit(attemptsLeft: Int) {
            if !browser.isRunning { launch(); return }
            guard attemptsLeft > 0 else {
                completion("\(browser.name) didn't quit. Quit it yourself, then try again.")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { waitForQuit(attemptsLeft: attemptsLeft - 1) }
        }

        // A browser is running on this folder. "( |$)" stops "…/Profile 1" from matching "…/Profile 10".
        func inUse(_ folder: URL) -> Bool {
            Shell.runSync("/usr/bin/pgrep", ["-f", "--", "--user-data-dir=" + folder.path + "( |$)"]).succeeded
        }

        if freshProfile {
            // Nothing to copy or quit: open the signed-out profile (or reuse it if it's already up).
            if inUse(freshProfileURL(browser)) { completion(nil) } else { launch() }
        } else if debugCopy {
            // Don't copy over a debug copy that is open right now; just bring it up.
            if inUse(copyURL) { launch(); return }
            DispatchQueue.global(qos: .userInitiated).async {
                let error = syncDebugCopy(browser, profile: profileFolder, into: copyURL)
                DispatchQueue.main.async {
                    if let error = error { completion(error) } else { launch() }
                }
            }
        } else if browser.isRunning {
            // Relaunching the real profile means fully quitting first; the flags are ignored otherwise.
            Shell.appleScript("tell application id \"\(browser.bundleID)\" to quit") { _ in
                waitForQuit(attemptsLeft: 50)
            }
        } else {
            launch()
        }
    }
}

// MARK: - Console

/// One line in the console pane: a log, an evaluated result, an error, or an echoed command.
struct ConsoleLine: Identifiable {
    enum Kind { case log, warning, error, input, result, info, ai }
    let id = UUID()
    let kind: Kind
    let text: String
    /// JavaScript the AI wrote, offered with a Run button.
    var code: String? = nil
    let time = Date()
}

enum RemoteObjectRender {
    /// Turns a CDP RemoteObject into a short human-readable string for the console.
    static func describe(_ object: [String: Any]) -> String {
        let type = (object["type"] as? String) ?? ""
        let subtype = object["subtype"] as? String
        if type == "undefined" { return "undefined" }
        if subtype == "null" { return "null" }
        if type == "string" { return "\"" + ((object["value"] as? String) ?? "") + "\"" }
        if type == "number" || type == "boolean" {
            if let value = object["value"] { return String(describing: value) }
            return (object["description"] as? String) ?? ""
        }
        if type == "function" {
            let desc = (object["description"] as? String) ?? "function"
            return desc.split(separator: "\n").first.map(String.init) ?? "ƒ"
        }
        if let description = object["description"] as? String, !description.isEmpty { return description }
        if let className = object["className"] as? String { return className }
        if let preview = object["preview"] as? [String: Any] {
            return (preview["description"] as? String) ?? type
        }
        return type
    }

    /// Flattens a CDP exceptionDetails object into a readable error string.
    static func describeException(_ details: [String: Any]) -> String {
        if let exception = details["exception"] as? [String: Any] {
            if let desc = exception["description"] as? String { return desc }
            return describe(exception)
        }
        if let text = details["text"] as? String { return text }
        return "Uncaught error"
    }
}

// MARK: - Inspector session

/// Drives one inspected page: holds the connection, the DOM mirror, styles, console and AI state.
final class InspectorSession: ObservableObject {
    // Connection / targets
    @Published var browsers: [DebugBrowser] = []
    @Published var selectedBrowser: DebugBrowser?
    @Published var profiles: [String] = []
    @Published var selectedProfile: String = ""
    @Published var port: Int = CDPLauncher.defaultPort
    @Published var profileNames: [String: String] = [:]
    /// Run a debug copy of the profile (Chrome 136+ refuses debugging on the real profile folder).
    @Published var useDebugCopy = UserDefaults.standard.object(forKey: "inspectorUseDebugCopy") as? Bool ?? true {
        didSet { UserDefaults.standard.set(useDebugCopy, forKey: "inspectorUseDebugCopy") }
    }
    /// Open an empty, signed-out profile instead of copying the chosen one — the way around a school
    /// or company policy that turns off developer tools for the managed profile.
    @Published var useFreshProfile = false

    func profileLabel(_ folder: String) -> String {
        guard let name = profileNames[folder], name != folder else { return folder }
        return "\(name) (\(folder))"
    }
    @Published var targets: [CDPTarget] = []
    @Published var connectedTarget: CDPTarget?
    @Published var status = ""
    @Published var busy = false
    @Published var connected = false

    // DOM
    @Published var root: DOMNode?
    @Published var selectedNode: DOMNode?
    @Published var outerHTML = ""
    /// The HTML as last read from the page; edits are "dirty" until applied.
    @Published var loadedOuterHTML = ""
    var outerHTMLDirty: Bool { outerHTML != loadedOuterHTML }
    @Published var computedStyles: [(name: String, value: String)] = []
    @Published var styleFilter = ""

    // Console
    @Published var console: [ConsoleLine] = [] {
        didSet { if console.count > Self.consoleLimit { console.removeFirst(console.count - Self.consoleLimit) } }
    }
    static let consoleLimit = 1000
    @Published var evalInput = ""
    /// Commands run so far, newest last, for ↑/↓ in the input.
    @Published var evalHistory: [String] = []
    /// The input asks the AI (in plain English) instead of running JavaScript.
    @Published var consoleAIMode = false
    @Published var consoleAIBusy = false

    enum ConsoleFilter: String, CaseIterable { case all = "All", errors = "Errors", warnings = "Warnings", logs = "Logs" }
    @Published var consoleFilter: ConsoleFilter = .all

    var visibleConsole: [ConsoleLine] {
        switch consoleFilter {
        case .all: return console
        case .errors: return console.filter { $0.kind == .error }
        case .warnings: return console.filter { $0.kind == .warning }
        case .logs: return console.filter { $0.kind == .log || $0.kind == .info }
        }
    }

    // Picker
    @Published var picking = false

    // Godot
    @Published var godotReport = ""

    // AI
    @Published var aiProvider: AIProvider = InspectorAI.defaultProvider
    @Published var aiOutput = ""
    @Published var aiBusy = false
    @Published var aiSuggestedHTML = ""
    /// What the user wants changed, for "Suggest an Edit".
    @Published var aiInstruction = ""

    var aiModel: String { InspectorAI.model(for: aiProvider) }

    /// Asks the model to explain or edit the selected element, given the live HTML and recent console output.
    func askAI(editMode: Bool) {
        guard let node = selectedNode else { aiOutput = "Select an element first."; return }
        let html = outerHTML.isEmpty ? node.summary : outerHTML
        let recentConsole = console.suffix(12).map { "\($0.kind): \($0.text)" }.joined(separator: "\n")
        let system = editMode
            ? "You are a web developer helping someone edit a page they are inspecting in their own browser. Return a short explanation, then the complete replacement outer HTML for the element inside a single ```html code block. Keep it valid and self-contained."
            : "You are a web developer explaining a page element to someone inspecting it in their own browser. Be concise and concrete: what the element is, what its attributes and styles do, and anything notable. Plain text, no code block unless it clarifies."
        var user = "Element on \(connectedTarget?.url ?? "the page"):\n\n\(html)\n"
        if !computedStyles.isEmpty {
            let styleText = computedStyles.prefix(40).map { "\($0.name): \($0.value)" }.joined(separator: "; ")
            user += "\nKey computed styles: \(styleText)\n"
        }
        if !recentConsole.isEmpty { user += "\nRecent console output:\n\(recentConsole)\n" }
        if editMode {
            let wanted = aiInstruction.trimmed
            user += wanted.isEmpty
                ? "\nEdit requested: improve this element (clarity, accessibility, valid markup). Return the full new outer HTML for this element."
                : "\nEdit requested: \(wanted)\nReturn the full new outer HTML for this element."
        }
        aiBusy = true
        aiOutput = ""
        aiSuggestedHTML = ""
        InspectorAI.ask(provider: aiProvider, system: system, user: user) { [weak self] result in
            guard let self = self else { return }
            self.aiBusy = false
            switch result {
            case .success(let text):
                self.aiOutput = text
                if editMode, let code = InspectorAI.firstCodeBlock(in: text) { self.aiSuggestedHTML = code }
            case .failure(let error):
                self.aiOutput = "⚠️ " + (error.localizedDescription)
            }
        }
    }

    /// Applies the AI's suggested HTML to the live element.
    func applySuggestedHTML() {
        guard !aiSuggestedHTML.isEmpty else { return }
        outerHTML = aiSuggestedHTML
        applyOuterHTML()
        aiSuggestedHTML = ""
    }

    private var connection: CDPConnection?

    // MARK: Setup

    func refreshBrowsers() {
        browsers = DebugBrowser.all.filter { $0.isInstalled }
        if selectedBrowser == nil { selectedBrowser = browsers.first }
        refreshProfiles()
    }

    func refreshProfiles() {
        guard let browser = selectedBrowser else { profiles = []; return }
        profiles = browser.profiles()
        profileNames = browser.profileNames()
        if !profiles.contains(selectedProfile) { selectedProfile = profiles.first ?? "Default" }
    }

    // MARK: Target discovery / launch

    func discover() {
        busy = true
        status = "Looking for a debuggable tab on port \(port)…"
        CDPLauncher.fetchTargets(port: port) { [weak self] result in
            guard let self = self else { return }
            self.busy = false
            switch result {
            case .success(let targets):
                let pages = targets.filter { $0.isInspectablePage }
                self.targets = pages
                if pages.isEmpty {
                    self.status = "The debug port is open but no page tab was found. Open a tab and refresh."
                } else {
                    self.status = "Found \(pages.count) tab\(pages.count == 1 ? "" : "s"). Pick one to inspect."
                }
            case .failure:
                self.targets = []
                self.status = "Nothing is listening on port \(port). Launch the browser with debugging below."
            }
        }
    }

    func launchAndDiscover() {
        guard let browser = selectedBrowser else { return }
        busy = true
        status = useFreshProfile
            ? "Opening a fresh, signed-out \(browser.name)… sign into the sites you need in it, and decline any “your organization will manage this profile” prompt."
            : useDebugCopy
            ? "Copying your “\(profileNames[selectedProfile] ?? selectedProfile)” profile and opening it with debugging (the first copy can take a minute)…"
            : "Launching \(browser.name)…"
        CDPLauncher.relaunch(browser, profile: selectedProfile, port: port, debugCopy: useDebugCopy, freshProfile: useFreshProfile) { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                self.busy = false
                self.status = "Couldn't launch \(browser.name): \(error)"
                return
            }
            // Give the browser a moment to open its debug port, then retry discovery a few times.
            self.pollForTargets(attemptsLeft: 20)
        }
    }

    private func pollForTargets(attemptsLeft: Int) {
        CDPLauncher.fetchTargets(port: port) { [weak self] result in
            guard let self = self else { return }
            if case .success(let targets) = result, !targets.filter({ $0.isInspectablePage }).isEmpty {
                self.busy = false
                self.targets = targets.filter { $0.isInspectablePage }
                self.status = "Ready. Pick a tab to inspect."
                return
            }
            // The port is up but no tab is open (only extension workers): open one to inspect.
            // Not on the first poll: Chrome is often still opening its own startup tab then.
            if case .success = result, attemptsLeft < 20, attemptsLeft % 4 == 0 {
                CDPLauncher.openTab(port: self.port)
            }
            if attemptsLeft <= 1 {
                self.busy = false
                self.status = self.useDebugCopy
                    ? "The browser started but didn't open its debug port. Quit any other debug copy using port \(self.port), then try again."
                    : "The browser started but didn't expose a debug tab. Chrome 136+ needs “Open a debug copy of the profile” turned on."
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                self.pollForTargets(attemptsLeft: attemptsLeft - 1)
            }
        }
    }

    // MARK: Connect

    func connect(to target: CDPTarget) {
        guard let url = URL(string: target.webSocketDebuggerURL) else {
            status = "That tab has no usable debugger address."; return
        }
        disconnect()
        let connection = CDPConnection(webSocketURL: url)
        connection.onEvent = { [weak self] method, params in self?.handleEvent(method, params) }
        connection.onClose = { [weak self, weak connection] in
            self?.connected = false
            if connection?.receivedAny == false, let port = self?.port {
                // Either the browser is gone, or Chrome answered 403 "Target is not inspectable"
                // (an admin policy turning off DevTools). The debug port tells them apart.
                CDPLauncher.fetchTargets(port: port) { result in
                    if case .success = result {
                        self?.status = "Chrome refused to let MacTools inspect this tab. If this profile is managed by a school or company, its admin has turned off developer tools; try another profile."
                    } else {
                        self?.status = "The browser isn't running with debugging any more. Launch it again below."
                    }
                }
            } else {
                self?.status = "The connection to the tab closed (the tab or browser was closed). Reconnect to continue."
            }
        }
        connection.connect()
        self.connection = connection
        // Drop the previous tab's tree and selection: their nodeIds mean nothing in this tab.
        root = nil
        selectedNode = nil
        outerHTML = ""
        loadedOuterHTML = ""
        computedStyles = []
        aiOutput = ""
        aiSuggestedHTML = ""
        godotReport = ""
        connectedTarget = target
        connected = true
        status = "Connected to \(target.displayTitle)."
        console = [ConsoleLine(kind: .info, text: "Connected to \(target.url)")]
        // Turn on the domains we use.
        connection.send("Page.enable")
        connection.send("DOM.enable")
        connection.send("CSS.enable")
        connection.send("Overlay.enable")
        connection.send("Log.enable")
        connection.send("Runtime.enable")
        loadDocument()
    }

    func disconnect() {
        connection?.close()
        connection = nil
        connected = false
        picking = false
        status = "Disconnected."
    }

    // MARK: DOM

    /// Reloads the tree. Every old nodeId is invalid afterwards, so the selection moves to the same
    /// element in the new tree (by backendNodeId, else by position) or is cleared.
    func loadDocument(then done: (() -> Void)? = nil) {
        let previous = selectedNode
        let previousPath = previous.map(DOMParse.path(of:))
        connection?.send("DOM.getDocument", ["depth": -1, "pierce": true]) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let value):
                if let rootDict = value["root"] as? [String: Any] {
                    let root = DOMParse.node(from: rootDict)
                    self.root = root
                    if let previous = previous, self.selectedNode === previous {
                        if let same = DOMParse.find(backendNodeId: previous.backendNodeId, in: root)
                            ?? previousPath.flatMap({ DOMParse.node(at: $0, in: root) }), same.nodeType != 9 {
                            self.select(same)
                        } else {
                            self.selectedNode = nil
                            self.outerHTML = ""
                            self.loadedOuterHTML = ""
                            self.computedStyles = []
                        }
                    }
                }
                done?()
            case .failure(let error):
                self.status = error.localizedDescription
            }
        }
    }

    func select(_ node: DOMNode) {
        selectedNode = node
        aiSuggestedHTML = ""
        // Don't leave the previous element's HTML in the editor while this one loads.
        outerHTML = ""
        loadedOuterHTML = ""
        guard let connection = connection else { return }
        // Replies can arrive after the user has clicked another element; ignore stale ones.
        connection.send("DOM.getOuterHTML", ["nodeId": node.nodeId]) { [weak self] result in
            guard let self = self, self.selectedNode === node, case .success(let value) = result else { return }
            let html = (value["outerHTML"] as? String) ?? ""
            self.outerHTML = html
            self.loadedOuterHTML = html
        }
        if node.isElement {
            connection.send("CSS.getComputedStyleForNode", ["nodeId": node.nodeId]) { [weak self] result in
                guard let self = self, self.selectedNode === node else { return }
                guard case .success(let value) = result,
                      let styles = value["computedStyle"] as? [[String: Any]] else { self.computedStyles = []; return }
                self.computedStyles = styles.compactMap { entry in
                    guard let name = entry["name"] as? String, let value = entry["value"] as? String else { return nil }
                    return (name, value)
                }
            }
        } else {
            computedStyles = []
        }
        highlight(node)
    }

    func highlight(_ node: DOMNode) {
        let config: [String: Any] = [
            "showInfo": true,
            "contentColor": ["r": 111, "g": 168, "b": 220, "a": 0.45],
            "paddingColor": ["r": 147, "g": 196, "b": 125, "a": 0.4],
            "borderColor": ["r": 255, "g": 229, "b": 153, "a": 0.5],
            "marginColor": ["r": 246, "g": 178, "b": 107, "a": 0.4],
        ]
        connection?.send("Overlay.highlightNode", ["highlightConfig": config, "nodeId": node.nodeId])
    }

    func clearHighlight() { connection?.send("Overlay.hideHighlight") }

    func applyOuterHTML() {
        guard let node = selectedNode, let connection = connection else { return }
        connection.send("DOM.setOuterHTML", ["nodeId": node.nodeId, "outerHTML": outerHTML]) { [weak self] result in
            switch result {
            case .success:
                self?.loadedOuterHTML = self?.outerHTML ?? ""
                self?.status = "Applied the edit to the live page."
                self?.loadDocument()
            case .failure(let error):
                self?.status = "Couldn't apply: \(error.localizedDescription)"
            }
        }
    }

    func setAttribute(_ name: String, _ value: String) {
        guard let node = selectedNode, let connection = connection, !name.isEmpty else { return }
        // Shown at once (the focused field re-reads it right away), put back if Chrome refuses.
        let before = node.attributes
        if let index = node.attributes.firstIndex(where: { $0.name == name }) {
            node.attributes[index].value = value
        } else {
            node.attributes.append((name, value))
        }
        objectWillChange.send()
        connection.send("DOM.setAttributeValue", ["nodeId": node.nodeId, "name": name, "value": value]) { [weak self] result in
            switch result {
            case .success:
                self?.status = "Set \(name)=\"\(value)\"."
                self?.refreshOuterHTML()
            case .failure(let error):
                node.attributes = before
                self?.objectWillChange.send()
                self?.status = "Couldn't set \(name): \(error.localizedDescription)"
            }
        }
    }

    func removeAttribute(_ name: String) {
        guard let node = selectedNode, let connection = connection else { return }
        connection.send("DOM.removeAttribute", ["nodeId": node.nodeId, "name": name]) { [weak self] result in
            if case .success = result {
                node.attributes.removeAll { $0.name == name }
                self?.objectWillChange.send()
                self?.refreshOuterHTML()
            }
        }
    }

    func deleteSelectedNode() {
        guard let node = selectedNode, let connection = connection else { return }
        connection.send("DOM.removeNode", ["nodeId": node.nodeId]) { [weak self] result in
            if case .success = result {
                self?.selectedNode = nil
                self?.outerHTML = ""
                self?.loadedOuterHTML = ""
                self?.status = "Removed the element from the page."
                self?.loadDocument()
            }
        }
    }

    private func refreshOuterHTML() {
        guard let node = selectedNode, let connection = connection else { return }
        connection.send("DOM.getOuterHTML", ["nodeId": node.nodeId]) { [weak self] result in
            guard let self = self, self.selectedNode === node, case .success(let value) = result else { return }
            let html = (value["outerHTML"] as? String) ?? ""
            self.outerHTML = html
            self.loadedOuterHTML = html
        }
    }

    // MARK: Element picker

    func togglePick() {
        picking.toggle()
        let config: [String: Any] = [
            "showInfo": true,
            "contentColor": ["r": 111, "g": 168, "b": 220, "a": 0.45],
            "borderColor": ["r": 255, "g": 229, "b": 153, "a": 0.6],
        ]
        connection?.send("Overlay.setInspectMode", [
            "mode": picking ? "searchForNode" : "none",
            "highlightConfig": config,
        ])
        status = picking ? "Click an element in the browser to select it here." : ""
    }

    // MARK: Console / evaluation

    /// Runs what's in the input: JavaScript, or a question for the AI in AI mode.
    func submitConsoleInput() {
        let text = evalInput.trimmed
        guard !text.isEmpty else { return }
        if evalHistory.last != text { evalHistory.append(text) }
        if evalHistory.count > 200 { evalHistory.removeFirst() }
        evalInput = ""
        if consoleAIMode { askConsoleAI(text) } else { runEval(text) }
    }

    func runEval(_ expression: String) {
        guard !expression.isEmpty, let connection = connection else { return }
        console.append(ConsoleLine(kind: .input, text: expression))
        connection.send("Runtime.evaluate", [
            "expression": expression,
            "returnByValue": false,
            "generatePreview": true,
            "awaitPromise": true,
            "userGesture": true,
            "replMode": true,
        ]) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let value):
                if let details = value["exceptionDetails"] as? [String: Any] {
                    self.console.append(ConsoleLine(kind: .error, text: RemoteObjectRender.describeException(details)))
                } else if let object = value["result"] as? [String: Any] {
                    self.console.append(ConsoleLine(kind: .result, text: RemoteObjectRender.describe(object)))
                }
            case .failure(let error):
                self.console.append(ConsoleLine(kind: .error, text: error.localizedDescription))
            }
        }
    }

    func clearConsole() { console.removeAll() }

    /// Page context for the console AI: address, title, selected element and recent output.
    private func consoleContext(lines: Int) -> String {
        var context = "Page: \(connectedTarget?.url ?? "unknown")\nTitle: \(connectedTarget?.title ?? "")\n"
        if !outerHTML.isEmpty { context += "\nSelected element:\n\(outerHTML.prefix(4000))\n" }
        let recent = console.suffix(lines).map { "[\($0.kind)] \($0.text.prefix(600))" }.joined(separator: "\n")
        if !recent.isEmpty { context += "\nRecent console:\n\(recent)\n" }
        return context
    }

    /// Plain-English request → JavaScript for this page, shown in the console with a Run button.
    func askConsoleAI(_ request: String) {
        console.append(ConsoleLine(kind: .input, text: "✦ " + request))
        let system = "You write JavaScript for the DevTools console of a page the user is inspecting in their own browser. "
            + "Reply with one or two short sentences, then exactly one ```js code block that does what they asked. "
            + "The code runs as a console expression (top-level await is fine) and its final value is shown, so end with the value worth seeing. "
            + "Don't use DevTools-only helpers like $0, $$ or inspect(). If it can't be done from page JavaScript, say so and give no code."
        runConsoleAI(system: system, user: consoleContext(lines: 20) + "\nRequest: \(request)")
    }

    /// Asks the AI why the recent errors happen and how to fix them.
    func explainConsoleErrors() {
        let errors = console.filter { $0.kind == .error || $0.kind == .warning }.suffix(15)
        guard !errors.isEmpty else { console.append(ConsoleLine(kind: .info, text: "No errors or warnings to explain.")); return }
        console.append(ConsoleLine(kind: .input, text: "✦ Explain the errors"))
        let system = "You are a web developer reading the console of a page the user is inspecting. Explain briefly what each distinct error or warning means and the likely cause, "
            + "and how to fix it. If some JavaScript run in the console would help investigate, include it in one ```js code block."
        runConsoleAI(system: system, user: consoleContext(lines: 40))
    }

    private func runConsoleAI(system: String, user: String) {
        consoleAIBusy = true
        InspectorAI.ask(provider: aiProvider, system: system, user: user) { [weak self] result in
            guard let self = self else { return }
            self.consoleAIBusy = false
            switch result {
            case .success(let text):
                let code = InspectorAI.firstCodeBlock(in: text)
                // Show the explanation; the code gets its own block with a Run button.
                var prose = text
                if let open = text.range(of: "```"), let close = text.range(of: "```", range: open.upperBound..<text.endIndex) {
                    prose.removeSubrange(open.lowerBound..<close.upperBound)
                }
                self.console.append(ConsoleLine(kind: .ai, text: prose.trimmed, code: code))
            case .failure(let error):
                self.console.append(ConsoleLine(kind: .error, text: "AI: " + error.localizedDescription))
            }
        }
    }

    // MARK: Godot

    func scanForGodot() {
        guard let connection = connection else { return }
        godotReport = "Scanning…"
        // Detect a Godot web export and enumerate its engine entry points and exported wasm symbols.
        let probe = #"""
        (function () {
          var out = { present: false, markers: [], canvases: [], engineFns: [], moduleExports: [], globals: [] };
          try {
            // Godot 4 declares these with const, so they aren't properties of window.
            var E = (typeof Engine !== "undefined") ? Engine : null;
            if (E) { out.present = true; out.markers.push("Engine"); }
            if (typeof Godot !== "undefined") { out.present = true; out.markers.push("Godot"); }
            var cfg = (typeof GODOT_CONFIG !== "undefined") ? GODOT_CONFIG : null;
            if (cfg) {
              out.present = true; out.markers.push("GODOT_CONFIG");
              var pack = cfg.mainPack || ((cfg.executable || "index") + ".pck");
              try { out.pack = new URL(pack, location.href).href; } catch (e) { out.pack = String(pack); }
            }
            var inst = (typeof engine !== "undefined") ? engine : null;
            var mod = (inst && inst.rtenv) || window.Module || null;
            if (mod) { out.markers.push(inst && inst.rtenv ? "engine.rtenv" : "Module"); }
            document.querySelectorAll("canvas").forEach(function (c) {
              out.canvases.push((c.id || "canvas") + " " + c.width + "x" + c.height);
              if (c.id && c.id.toLowerCase().indexOf("godot") >= 0) out.present = true;
            });
            if (E && typeof E === "function") {
              var proto = E.prototype || {};
              Object.getOwnPropertyNames(proto).forEach(function (k) {
                if (typeof proto[k] === "function") out.engineFns.push(k);
              });
            }
            if (mod) {
              var count = 0;
              for (var key in mod) {
                if (count > 400) break;
                try {
                  if (typeof mod[key] === "function" && (key[0] === "_" || key.indexOf("godot") >= 0 || key.indexOf("gdscript") >= 0)) {
                    out.moduleExports.push(key); count++;
                  }
                } catch (e) {}
              }
            }
            var gl = Object.getOwnPropertyNames(window).filter(function (k) {
              return typeof window[k] === "function" && (k.indexOf("godot") >= 0 || k.indexOf("Godot") >= 0 || k.indexOf("gd_") >= 0);
            });
            out.globals = gl.slice(0, 100);
          } catch (e) { out.error = String(e); }
          return JSON.stringify(out);
        })()
        """#
        connection.send("Runtime.evaluate", ["expression": probe, "returnByValue": true, "awaitPromise": true]) { [weak self] result in
            guard let self = self else { return }
            guard case .success(let value) = result,
                  let object = value["result"] as? [String: Any],
                  let json = object["value"] as? String,
                  let data = json.data(using: .utf8),
                  let report = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                self.godotReport = "Couldn't read the page. Is a tab connected?"
                return
            }
            self.godotReport = Self.formatGodot(report)
        }
    }

    static func formatGodot(_ report: [String: Any]) -> String {
        var lines: [String] = []
        let present = (report["present"] as? Bool) ?? false
        let markers = (report["markers"] as? [String]) ?? []
        lines.append(present ? "✅ This looks like a Godot web export." : "No Godot engine markers found on this page.")
        if !markers.isEmpty { lines.append("Markers: " + markers.joined(separator: ", ")) }
        if let pack = report["pack"] as? String, !pack.isEmpty {
            lines.append("")
            lines.append("Game pack: \(pack)")
            lines.append("Download that file and open it in Godot Pack Inspector to read the game's scripts and functions.")
        }
        if let canvases = report["canvases"] as? [String], !canvases.isEmpty {
            lines.append("")
            lines.append("Canvases:")
            canvases.forEach { lines.append("  • \($0)") }
        }
        if let fns = report["engineFns"] as? [String], !fns.isEmpty {
            lines.append("")
            lines.append("Engine methods (\(fns.count)):")
            lines.append("  " + fns.joined(separator: ", "))
        }
        if let exports = report["moduleExports"] as? [String], !exports.isEmpty {
            lines.append("")
            lines.append("Module / wasm functions (\(exports.count), filtered):")
            exports.prefix(120).forEach { lines.append("  • \($0)") }
        }
        if let globals = report["globals"] as? [String], !globals.isEmpty {
            lines.append("")
            lines.append("Global Godot functions:")
            globals.forEach { lines.append("  • \($0)") }
        }
        if let error = report["error"] as? String { lines.append("\nPage error: \(error)") }
        if present && (report["moduleExports"] as? [String])?.isEmpty != false {
            lines.append("\nTip: GDScript functions live inside the game's .pck file. Open it in the Godot Pack Inspector to read the actual func definitions.")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Events

    private func handleEvent(_ method: String, _ params: [String: Any]) {
        switch method {
        case "Runtime.consoleAPICalled":
            let type = (params["type"] as? String) ?? "log"
            let args = (params["args"] as? [[String: Any]]) ?? []
            // Like DevTools, logged strings print without quotes.
            let text = args.map { ($0["type"] as? String) == "string" ? (($0["value"] as? String) ?? "") : RemoteObjectRender.describe($0) }
                .joined(separator: " ")
            let kind: ConsoleLine.Kind = (type == "error") ? .error : (type == "warning" || type == "warn") ? .warning : .log
            console.append(ConsoleLine(kind: kind, text: text.isEmpty ? type : text))
        case "Runtime.exceptionThrown":
            if let details = params["exceptionDetails"] as? [String: Any] {
                console.append(ConsoleLine(kind: .error, text: RemoteObjectRender.describeException(details)))
            }
        case "Log.entryAdded":
            if let entry = params["entry"] as? [String: Any] {
                let level = (entry["level"] as? String) ?? "info"
                let text = (entry["text"] as? String) ?? ""
                let kind: ConsoleLine.Kind = (level == "error") ? .error : (level == "warning") ? .warning : .log
                console.append(ConsoleLine(kind: kind, text: text))
            }
        case "Overlay.inspectNodeRequested":
            if let backendId = params["backendNodeId"] as? Int { pickResolved(backendId) }
        case "DOM.documentUpdated":
            loadDocument()
        case "DOM.attributeModified":
            if let nodeId = params["nodeId"] as? Int, let root = root, let node = DOMParse.find(nodeId, in: root),
               let name = params["name"] as? String, let value = params["value"] as? String {
                if let index = node.attributes.firstIndex(where: { $0.name == name }) { node.attributes[index].value = value }
                else { node.attributes.append((name, value)) }
                objectWillChange.send()
            }
        case "DOM.attributeRemoved":
            if let nodeId = params["nodeId"] as? Int, let root = root, let node = DOMParse.find(nodeId, in: root),
               let name = params["name"] as? String {
                node.attributes.removeAll { $0.name == name }
                objectWillChange.send()
            }
        default:
            break
        }
    }

    private func pickResolved(_ backendNodeId: Int) {
        // Turn off inspect mode and select the picked node.
        picking = false
        status = ""
        connection?.send("Overlay.setInspectMode", ["mode": "none", "highlightConfig": [:]])
        if let root = root, let node = DOMParse.find(backendNodeId: backendNodeId, in: root) {
            select(node)
            return
        }
        // The page changed since the tree was read; reload it and look again.
        loadDocument { [weak self] in
            guard let self = self else { return }
            if let root = self.root, let node = DOMParse.find(backendNodeId: backendNodeId, in: root) {
                self.select(node)
            } else {
                self.status = "Couldn't find the picked element in the page's DOM."
            }
        }
    }

    deinit { connection?.close() }
}

// MARK: - AI assistant (non-streaming, reuses the School To-Do API keys from the Keychain)

enum InspectorAIError: LocalizedError {
    case noKey(AIProvider)
    case keychainRefused(AIProvider)
    case badKey(AIProvider)
    case declined(String)
    case http(AIProvider, Int, String)
    case network(String)
    case unreadable

    var errorDescription: String? {
        switch self {
        case .noKey(let p): return "No \(p.shortName) API key is saved yet. Add one above."
        case .keychainRefused(let p): return "MacTools couldn't read your saved \(p.shortName) key from the Keychain. If macOS asks for permission, click Always Allow, then try again."
        case .badKey(let p): return "\(p.companyName) didn't accept the API key. Use Change to enter it again."
        case .declined(let why): return "The model declined to answer" + (why.isEmpty ? "." : ": \(why)")
        case let .http(p, status, message):
            switch status {
            case 429: return "\(p.companyName) is rate-limiting requests (or the account is out of credit). Try again shortly." + (message.isEmpty ? "" : " (\(message))")
            case 404: return "\(p.companyName) doesn't recognise the model name. Pick another model under School To-Do ▸ Setup." + (message.isEmpty ? "" : " (\(message))")
            default: return "\(p.companyName) API error \(status)" + (message.isEmpty ? "." : ": \(message)")
            }
        case .network(let message): return "Couldn't reach the AI service: \(message)"
        case .unreadable: return "The AI's answer couldn't be read. Try again."
        }
    }
}

/// The AI helper used by Element Inspector and Godot Pack Inspector. It reuses the Claude and ChatGPT
/// keys School To-Do keeps in the Keychain (cached there, so views never read the Keychain directly).
enum InspectorAI {
    static func hasKey(_ provider: AIProvider) -> Bool { SchoolPlanner.shared.hasKey(provider) }

    /// The provider School To-Do uses, unless only the other one has a key.
    static var defaultProvider: AIProvider {
        let chosen = SchoolPlanner.shared.settings.provider
        if hasKey(chosen) { return chosen }
        return AIProvider.allCases.first(where: { hasKey($0) }) ?? chosen
    }

    /// The model chosen under School To-Do ▸ Setup for this provider.
    static func model(for provider: AIProvider) -> String {
        let settings = SchoolPlanner.shared.settings
        let id = (provider == .claude ? settings.claudeModel : settings.openAIModel).trimmed
        if !id.isEmpty { return id }
        return provider == .claude ? SchoolModels.claudeDefault : SchoolModels.openAIDefault
    }

    private static func supportsServerFallback(_ model: String) -> Bool {
        model.hasPrefix("claude-opus-5") || model.hasPrefix("claude-sonnet-5-5") || model.hasPrefix("claude-fable-5")
    }

    /// Sends a one-shot prompt and returns the model's text answer on the main thread.
    static func ask(provider: AIProvider, system: String, user: String,
                    completion: @escaping (Result<String, Error>) -> Void) {
        guard let key = SchoolPlanner.shared.apiKey(provider), !key.isEmpty else {
            completion(.failure(hasKey(provider) ? InspectorAIError.keychainRefused(provider) : InspectorAIError.noKey(provider)))
            return
        }
        let chosenModel = Self.model(for: provider)
        var request: URLRequest
        var body: [String: Any]
        switch provider {
        case .claude:
            request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
            body = [
                "model": chosenModel,
                // Thinking counts toward max_tokens, so leave room for the answer itself.
                "max_tokens": 16000,
                "system": system,
                "output_config": ["effort": "medium"],
                "messages": [["role": "user", "content": user]],
            ]
            if supportsServerFallback(chosenModel) {
                // If a safety check declines the request, the API retries it on a fallback model by itself.
                request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
                body["fallbacks"] = "default"
            }
        case .openAI:
            request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            body = [
                "model": chosenModel,
                "messages": [
                    ["role": "system", "content": system],
                    ["role": "user", "content": user],
                ],
            ]
        }
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        // Non-streaming: nothing arrives until the whole answer is ready.
        request.timeoutInterval = 300
        guard let data = try? JSONSerialization.data(withJSONObject: body) else {
            completion(.failure(InspectorAIError.unreadable)); return
        }
        request.httpBody = data
        send(request, provider: provider, retriesLeft: 1, completion: completion)
    }

    private static func send(_ request: URLRequest, provider: AIProvider, retriesLeft: Int,
                             completion: @escaping (Result<String, Error>) -> Void) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 300
        let session = URLSession(configuration: config)
        session.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                let transient = error != nil || [408, 409, 429, 500, 502, 503, 504, 529].contains(status)
                if transient && retriesLeft > 0 && (error as NSError?)?.code != NSURLErrorCancelled {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        send(request, provider: provider, retriesLeft: retriesLeft - 1, completion: completion)
                    }
                    return
                }
                if let error = error { completion(.failure(InspectorAIError.network(error.localizedDescription))); return }
                guard let data = data else { completion(.failure(InspectorAIError.unreadable)); return }
                guard status == 200 else {
                    let message = errorMessage(data)
                    completion(.failure(status == 401 ? InspectorAIError.badKey(provider) : InspectorAIError.http(provider, status, message)))
                    return
                }
                completion(answer(provider: provider, data: data))
            }
        }.resume()
        // Release the session once its one task finishes.
        session.finishTasksAndInvalidate()
    }

    /// Reads the answer text, turning refusals and cut-off answers into clear results.
    static func answer(provider: AIProvider, data: Data) -> Result<String, Error> {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .failure(InspectorAIError.unreadable)
        }
        var text = ""
        var cutOff = false
        switch provider {
        case .claude:
            let stop = object["stop_reason"] as? String
            if stop == "refusal" {
                let details = object["stop_details"] as? [String: Any]
                return .failure(InspectorAIError.declined((details?["explanation"] as? String) ?? ""))
            }
            let content = (object["content"] as? [[String: Any]]) ?? []
            text = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
            cutOff = stop == "max_tokens"
        case .openAI:
            guard let choice = (object["choices"] as? [[String: Any]])?.first,
                  let message = choice["message"] as? [String: Any] else { return .failure(InspectorAIError.unreadable) }
            if let refusal = message["refusal"] as? String, !refusal.isEmpty { return .failure(InspectorAIError.declined(refusal)) }
            text = (message["content"] as? String) ?? ""
            cutOff = choice["finish_reason"] as? String == "length"
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure(InspectorAIError.unreadable) }
        return .success(cutOff ? text + "\n\n(The answer was cut off because it got too long.)" : text)
    }

    private static func errorMessage(_ data: Data) -> String {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let error = object["error"] as? [String: Any] else {
            return String(decoding: data.prefix(200), as: UTF8.self).trimmed
        }
        return (error["message"] as? String) ?? ""
    }

    /// Renders the model's inline markdown (`code`, **bold**) while keeping its line breaks.
    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    /// Pulls the first fenced code block out of a model answer, for an "Apply HTML" button.
    static func firstCodeBlock(in text: String) -> String? {
        guard let open = text.range(of: "```") else { return nil }
        let afterOpen = text[open.upperBound...]
        // Skip an optional language tag on the same line.
        let bodyStart: String.Index
        if let newline = afterOpen.firstIndex(of: "\n") {
            bodyStart = afterOpen.index(after: newline)
        } else {
            bodyStart = afterOpen.startIndex
        }
        let rest = text[bodyStart...]
        guard let close = rest.range(of: "```") else { return nil }
        let code = rest[rest.startIndex..<close.lowerBound]
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Floating window

/// Owns an always-on-top panel that hosts the same inspector session as the main view.
final class FloatingInspectorController: NSObject, ObservableObject {
    @Published var isOpen = false
    private var window: NSWindow?

    func toggle(session: InspectorSession) {
        if window != nil { closeWindow(); return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 620),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.title = "Inspector"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView:
            InspectorContent(session: session)
                .frame(minWidth: 520, minHeight: 420)
                .themedRoot()
        )
        panel.delegate = self
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        window = panel
        isOpen = true
    }

    func closeWindow() {
        window?.close()
        window = nil
        isOpen = false
    }
}

extension FloatingInspectorController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        window = nil
        isOpen = false
    }
}

// MARK: - Main tool view

struct ChromeInspectorView: View {
    @StateObject private var session = InspectorSession()
    @StateObject private var floating = FloatingInspectorController()

    var body: some View {
        ToolPage(tool: .chromeInspector, scrolls: false) {
            if !session.connected {
                connectPanel
            } else {
                HStack(spacing: 8) {
                    Text(session.connectedTarget?.displayTitle ?? "Connected")
                        .font(.subheadline.bold()).lineLimit(1)
                    Spacer()
                    Button(floating.isOpen ? "Close Floating Window" : "Pop Out ⤢") { floating.toggle(session: session) }
                    Button("Disconnect") { session.disconnect() }
                }
                if floating.isOpen {
                    Text("The inspector is in a floating window that stays on top of other apps. Close it to bring the panels back here.")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    InspectorContent(session: session)
                }
            }
            if !session.status.isEmpty {
                Text(session.status).font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { if session.browsers.isEmpty { session.refreshBrowsers(); session.discover() } }
        .onDisappear { floating.closeWindow() }
    }

    private var connectPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Card(title: "Connect to a tab", icon: "dot.radiowaves.left.and.right") {
                Text("This opens a DevTools-style inspector for a page in your own Chrome-family browser, using Chrome's built-in remote debugging. Edit the DOM, read the console, run JavaScript — all from here.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text("Debug port")
                    TextField("9222", value: $session.port, format: .number.grouping(.never))
                        .frame(width: 80).textFieldStyle(.roundedBorder)
                    Button("Find Tabs") { session.discover() }
                    if session.busy { ProgressView().controlSize(.small) }
                    Spacer()
                }
                if !session.targets.isEmpty {
                    Divider()
                    Text("Tabs found").font(.caption.bold()).foregroundStyle(.secondary)
                    ForEach(session.targets) { target in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(target.displayTitle).lineLimit(1)
                                Text(target.url).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Button("Inspect") { session.connect(to: target) }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            Card(title: "Launch a browser with debugging", icon: "arrow.clockwise") {
                Text("If no tab was found, the browser isn't running with remote debugging. Pick a browser and profile and launch it here.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Picker("Browser", selection: Binding(
                        get: { session.selectedBrowser },
                        set: { session.selectedBrowser = $0; session.refreshProfiles() })) {
                        ForEach(session.browsers) { browser in Text(browser.name).tag(Optional(browser)) }
                    }
                    .frame(maxWidth: 220)
                    if !session.profiles.isEmpty && !session.useFreshProfile {
                        Picker("Profile", selection: $session.selectedProfile) {
                            ForEach(session.profiles, id: \.self) { Text(session.profileLabel($0)).tag($0) }
                        }
                        .frame(maxWidth: 280)
                    }
                }
                if !session.useFreshProfile {
                    Toggle("Open a debug copy of the profile (needed on Chrome 136+)", isOn: $session.useDebugCopy)
                        .font(.caption)
                    Text(session.useDebugCopy
                         ? "Copies the profile's bookmarks, sign-ins and extensions into a separate MacTools folder and opens it as a second Chrome, so your normal Chrome keeps running. The copy is refreshed each launch; changes made in it aren't saved back, and some sites (like Google) may ask you to sign in again."
                         : "Quits the browser and reopens your real profile with debugging. Works on Edge, Brave and older Chrome; Chrome 136+ ignores it.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Toggle("My profile has developer tools turned off (school / work account)", isOn: $session.useFreshProfile)
                    .font(.caption)
                if session.useFreshProfile {
                    Text("Opens a fresh, empty Chrome with no account attached, so the policy that disables developer tools doesn't apply. Sign into the sites you need inside it (your logins stay for next time). Important: if Chrome asks to “manage this profile”, click Cancel — accepting it re-applies the block.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Launch & Connect") { session.launchAndDiscover() }
                        .buttonStyle(.borderedProminent)
                    if (session.selectedBrowser?.isRunning ?? false) && !session.useDebugCopy && !session.useFreshProfile {
                        Label("This quits and reopens the browser.", systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundColor(.orange)
                    }
                    Spacer()
                }
            }
        }
    }
}

// MARK: - Inspector content (shared by the embedded view and the floating window)

struct InspectorContent: View {
    @ObservedObject var session: InspectorSession
    // Watched so the AI buttons update as soon as a key is saved.
    @ObservedObject private var planner = SchoolPlanner.shared
    @State private var rightTab = 0

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button(session.picking ? "Picking… (click page)" : "Pick Element ⌖") { session.togglePick() }
                    .foregroundColor(session.picking ? .orange : nil)
                Button("Reload DOM") { session.loadDocument() }
                Spacer()
                Button { rightTab = 2 } label: { Label("AI Assistant", systemImage: "sparkles") }
                    .help("Ask Claude or ChatGPT about the selected element")
            }
            HSplitView {
                domTree.frame(minWidth: 220)
                // Drag the divider to give the console more or less room.
                VSplitView {
                    VStack(spacing: 6) {
                        breadcrumb
                        detailTabs
                    }
                    .frame(minHeight: 160)
                    consolePane.frame(minHeight: 140)
                }
                .frame(minWidth: 320)
            }
        }
    }

    // DOM tree
    private var domTree: some View {
        Group {
            if let root = session.root {
                List {
                    OutlineGroup(root.children, id: \.id, children: \.outlineChildren) { node in
                        DOMRow(session: session, node: node)
                    }
                }
                .listStyle(.sidebar)
            } else {
                Text("No document loaded.").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var breadcrumb: some View {
        Group {
            if let node = session.selectedNode {
                Text(breadcrumbPath(node))
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func breadcrumbPath(_ node: DOMNode) -> String {
        var parts: [String] = []
        var current: DOMNode? = node
        while let n = current, n.nodeType != 9 {
            parts.insert(n.summary, at: 0)
            current = n.parent
        }
        return parts.joined(separator: " › ")
    }

    private var detailTabs: some View {
        TabView(selection: $rightTab) {
            attributesPane.tabItem { Text("Element") }.tag(0)
            stylesPane.tabItem { Text("Styles") }.tag(1)
            aiPane.tabItem { Text("AI") }.tag(2)
            godotPane.tabItem { Text("Godot") }.tag(3)
        }
    }

    // Element / attributes / HTML
    private var attributesPane: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let node = session.selectedNode {
                if node.isElement {
                    AttributesEditor(session: session, node: node)
                        .id(node.id) // fresh drafts for each element
                    Divider()
                }
                Text("Outer HTML").font(.caption.bold()).foregroundStyle(.secondary)
                TextEditor(text: $session.outerHTML)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(minHeight: 90)
                HStack {
                    Button("Apply to Page") { session.applyOuterHTML() }
                        .disabled(!session.outerHTMLDirty)
                    Button(role: .destructive) { session.deleteSelectedNode() } label: { Text("Delete Element") }
                    Spacer()
                }
            } else {
                Text("Select an element in the tree, or use Pick Element.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(8)
    }

    // Computed styles
    private var stylesPane: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Filter styles…", text: $session.styleFilter)
                .textFieldStyle(.roundedBorder)
            if session.computedStyles.isEmpty {
                Text("No computed styles. Select an element.").foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(filteredStyles, id: \.name) { style in
                            HStack(alignment: .top) {
                                Text(style.name).font(.system(size: 11, design: .monospaced)).foregroundColor(.accentColor)
                                Text(style.value).font(.system(size: 11, design: .monospaced)).foregroundStyle(.primary)
                                Spacer()
                            }
                        }
                    }
                }
            }
        }
        .padding(8)
    }

    private var filteredStyles: [(name: String, value: String)] {
        let f = session.styleFilter.trimmed.lowercased()
        guard !f.isEmpty else { return session.computedStyles }
        return session.computedStyles.filter { $0.name.contains(f) || $0.value.lowercased().contains(f) }
    }

    // AI assistant
    private var aiPane: some View {
        VStack(alignment: .leading, spacing: 6) {
            AIProviderBar(provider: $session.aiProvider)
            TextField("Edit to make, e.g. “make the heading blue and centred” (optional)", text: $session.aiInstruction)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if canAsk { session.askAI(editMode: true) } }
            HStack {
                Button("Explain Element") { session.askAI(editMode: false) }
                Button("Suggest an Edit") { session.askAI(editMode: true) }
                if session.aiBusy { ProgressView().controlSize(.small) }
                Spacer()
            }
            .disabled(!canAsk)
            ScrollView {
                Text(session.aiOutput.isEmpty ? AttributedString("Ask the model to explain or rewrite the selected element.") : InspectorAI.markdown(session.aiOutput))
                    .font(.system(size: 12))
                    .foregroundStyle(session.aiOutput.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !session.aiSuggestedHTML.isEmpty {
                Button("Apply Suggested HTML to Page") { session.applySuggestedHTML() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(8)
    }

    private var canAsk: Bool { session.selectedNode != nil && !session.aiBusy && planner.hasKey(session.aiProvider) }

    // Godot
    private var godotPane: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button("Scan Page for Godot") { session.scanForGodot() }
                Spacer()
            }
            Text("Detects a Godot web export in the connected tab and lists its engine methods and exported functions. For the actual GDScript functions, open a game's .pck file in the Godot Pack Inspector.")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                Text(session.godotReport.isEmpty ? "No scan yet." : session.godotReport)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(8)
    }

    // Console
    private var consolePane: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Text("Console").font(.caption.bold()).foregroundStyle(.secondary)
                Picker("Show", selection: $session.consoleFilter) {
                    ForEach(InspectorSession.ConsoleFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().controlSize(.small).fixedSize()
                Spacer()
                if session.consoleAIBusy { ProgressView().controlSize(.small) }
                Button { session.explainConsoleErrors() } label: { Label("Explain Errors", systemImage: "sparkles") }
                    .controlSize(.small)
                    .disabled(!canAskConsoleAI)
                    .help("Ask the AI what the errors and warnings mean")
                Button("Clear") { session.clearConsole() }.controlSize(.small)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(session.visibleConsole) { line in
                            consoleRow(line).id(line.id)
                        }
                    }
                }
                // Watch the last line, not the count: the count stops changing once the 1000-line cap is hit.
                .onChange(of: session.console.last?.id) { _ in
                    if let last = session.visibleConsole.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            HStack(spacing: 6) {
                Picker("Input", selection: $session.consoleAIMode) {
                    Text("JS").tag(false)
                    Label("Ask AI", systemImage: "sparkles").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .help("JS runs JavaScript in the page. Ask AI turns a plain-English request into JavaScript you can run.")
                ConsoleInputField(
                    text: $session.evalInput,
                    history: session.evalHistory,
                    placeholder: session.consoleAIMode
                        ? "Describe what to do, e.g. “list every link on the page” (Return to ask)"
                        : "Run JavaScript in the page… (↑/↓ for history)",
                    onSubmit: { session.submitConsoleInput() })
                Button(session.consoleAIMode ? "Ask" : "Run") { session.submitConsoleInput() }
                    .disabled(session.consoleAIMode && !canAskConsoleAI)
            }
            if session.consoleAIMode && !planner.hasKey(session.aiProvider) {
                AIProviderBar(provider: $session.aiProvider)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
    }

    private var canAskConsoleAI: Bool { !session.consoleAIBusy && planner.hasKey(session.aiProvider) }

    @ViewBuilder
    private func consoleRow(_ line: ConsoleLine) -> some View {
        if line.kind == .ai {
            VStack(alignment: .leading, spacing: 4) {
                if !line.text.isEmpty {
                    Text(InspectorAI.markdown("✦ " + line.text))
                        .font(.system(size: 11.5))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let code = line.code {
                    Text(code)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.07)))
                    HStack {
                        Button { session.runEval(code) } label: { Label("Run in Page", systemImage: "play.fill") }
                            .controlSize(.small)
                        Button("Edit") { session.consoleAIMode = false; session.evalInput = code }
                            .controlSize(.small)
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(code, forType: .string)
                        }
                        .controlSize(.small)
                    }
                }
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.purple.opacity(0.10)))
            .padding(.vertical, 2)
        } else {
            Text(consolePrefix(line.kind) + line.text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(consoleColor(line.kind))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, line.kind == .error || line.kind == .warning ? 1 : 0)
                .background(consoleBackground(line.kind))
        }
    }

    private func consoleBackground(_ kind: ConsoleLine.Kind) -> Color {
        switch kind {
        case .error: return Color.red.opacity(0.08)
        case .warning: return Color.orange.opacity(0.08)
        default: return .clear
        }
    }

    private func consolePrefix(_ kind: ConsoleLine.Kind) -> String {
        switch kind {
        case .input: return "› "
        case .result: return "‹ "
        case .error: return "✖︎ "
        case .warning: return "⚠︎ "
        default: return ""
        }
    }

    private func consoleColor(_ kind: ConsoleLine.Kind) -> Color {
        switch kind {
        case .error: return .red
        case .warning: return .orange
        case .input: return .accentColor
        case .result: return .green
        case .info: return .secondary
        default: return .primary
        }
    }
}

/// One row in the DOM tree.
struct DOMRow: View {
    @ObservedObject var session: InspectorSession
    let node: DOMNode

    var body: some View {
        let selected = session.selectedNode === node
        // A Button (not onTapGesture) so the row can be selected with VoiceOver and the keyboard.
        Button { session.select(node) } label: {
            Text(node.summary)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(node.isElement ? (selected ? .white : .primary) : .secondary)
                .lineLimit(1)
                .padding(.vertical, 1).padding(.horizontal, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 4).fill(selected ? Color.accentColor : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in if hovering && session.connected { session.highlight(node) } }
    }
}

/// Editable list of an element's attributes, plus an add row.
struct AttributesEditor: View {
    @ObservedObject var session: InspectorSession
    @ObservedObject var node: DOMNode
    @State private var newName = ""
    @State private var newValue = ""
    @State private var drafts: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Attributes").font(.caption.bold()).foregroundStyle(.secondary)
            ForEach(Array(node.attributes.enumerated()), id: \.offset) { _, attribute in
                HStack(spacing: 4) {
                    Text(attribute.name).font(.system(size: 11, design: .monospaced)).foregroundColor(.accentColor)
                    // Edits are local until Return, so typing doesn't send one CDP command per keystroke.
                    TextField("value", text: Binding(
                        get: { drafts[attribute.name] ?? attribute.value },
                        set: { drafts[attribute.name] = $0 }
                    ))
                    .onSubmit {
                        if let value = drafts.removeValue(forKey: attribute.name), value != attribute.value {
                            session.setAttribute(attribute.name, value)
                        }
                    }
                    .help("Press Return to apply")
                    .font(.system(size: 11, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    Button { session.removeAttribute(attribute.name) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                }
            }
            HStack(spacing: 4) {
                TextField("name", text: $newName).frame(width: 90).textFieldStyle(.roundedBorder)
                TextField("value", text: $newValue).textFieldStyle(.roundedBorder)
                Button {
                    let name = newName.trimmed
                    guard !name.isEmpty else { return }
                    session.setAttribute(name, newValue)
                    newName = ""; newValue = ""
                } label: { Image(systemName: "plus.circle") }
                    .buttonStyle(.borderless)
            }
            .font(.system(size: 11, design: .monospaced))
        }
    }
}

/// Single-line console input: Return submits, ↑/↓ walk the command history like a terminal.
struct ConsoleInputField: NSViewRepresentable {
    @Binding var text: String
    let history: [String]
    let placeholder: String
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        field.bezelStyle = .roundedBezel
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.delegate = context.coordinator
        field.setAccessibilityLabel("Console input")
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        field.placeholderString = placeholder
    }

    final class Coordinator: NSObject {
        var parent: ConsoleInputField
        /// Position while browsing history; nil when editing a fresh line.
        var index: Int?
        var draft = ""

        init(_ parent: ConsoleInputField) { self.parent = parent }

        func show(_ value: String, in textView: NSTextView) {
            parent.text = value
            textView.string = value
            textView.setSelectedRange(NSRange(location: (value as NSString).length, length: 0))
        }
    }
}

extension ConsoleInputField.Coordinator: NSTextFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        parent.text = field.stringValue
        index = nil
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        let history = parent.history
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            parent.text = textView.string
            index = nil
            parent.onSubmit()
            return true
        case #selector(NSResponder.moveUp(_:)):
            guard !history.isEmpty else { return true }
            if index == nil { draft = textView.string }
            let next = max((index ?? history.count) - 1, 0)
            index = next
            show(history[next], in: textView)
            return true
        case #selector(NSResponder.moveDown(_:)):
            guard let current = index else { return true }
            if current + 1 < history.count {
                index = current + 1
                show(history[current + 1], in: textView)
            } else {
                index = nil
                show(draft, in: textView)
            }
            return true
        default:
            return false
        }
    }
}
