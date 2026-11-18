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

    /// Profile folders (Default, Profile 1…) found on disk for this browser.
    func profiles() -> [String] {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let base = support.appendingPathComponent(supportPath)
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

    /// Quits the browser (if running), then relaunches it for the chosen profile with the debug port open.
    /// `dedicatedDataDir` uses a separate MacTools profile folder, which recent Chrome requires for
    /// remote debugging and which keeps the user's everyday browsing untouched.
    static func relaunch(_ browser: DebugBrowser, profile: String, port: Int, dedicatedDataDir: Bool,
                         completion: @escaping (String?) -> Void) {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.bundleID) else {
            completion("\(browser.name) isn't installed."); return
        }
        var arguments = ["--remote-debugging-port=\(port)", "--remote-debugging-address=127.0.0.1"]
        if dedicatedDataDir {
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("MacTools/InspectorProfiles/\(browser.bundleID)")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            arguments.append("--user-data-dir=\(dir.path)")
        } else if !profile.isEmpty {
            arguments.append("--profile-directory=\(profile)")
        }

        func launch() {
            let config = NSWorkspace.OpenConfiguration()
            config.arguments = arguments
            config.createsNewApplicationInstance = false
            NSWorkspace.shared.openApplication(at: appURL, configuration: config) { _, error in
                DispatchQueue.main.async { completion(error?.localizedDescription) }
            }
        }

        if browser.isRunning && !dedicatedDataDir {
            // Relaunching the real profile means fully quitting first; the flags are ignored otherwise.
            Shell.appleScript("tell application id \"\(browser.bundleID)\" to quit") { _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: launch)
            }
        } else {
            launch()
        }
    }
}

// MARK: - Console

/// One line in the console pane: a log, an evaluated result, an error, or an echoed command.
struct ConsoleLine: Identifiable {
    enum Kind { case log, warning, error, input, result, info }
    let id = UUID()
    let kind: Kind
    let text: String
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
    @Published var useDedicatedProfile = false
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
    @Published var console: [ConsoleLine] = []
    @Published var evalInput = ""

    // Picker
    @Published var picking = false

    // Godot
    @Published var godotReport = ""

    // AI
    @Published var aiProvider: AIProvider = InspectorAI.defaultProvider
    @Published var aiOutput = ""
    @Published var aiBusy = false
    @Published var aiSuggestedHTML = ""

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
        if editMode { user += "\nEdit requested. Return the full new outer HTML for this element." }
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
        status = "Launching \(browser.name)…"
        CDPLauncher.relaunch(browser, profile: selectedProfile, port: port, dedicatedDataDir: useDedicatedProfile) { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                self.busy = false
                self.status = "Couldn't launch \(browser.name): \(error)"
                return
            }
            // Give the browser a moment to open its debug port, then retry discovery a few times.
            self.pollForTargets(attemptsLeft: 8)
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
            if attemptsLeft <= 1 {
                self.busy = false
                self.status = "The browser started but didn't expose a debug tab. Recent Chrome needs the separate profile option."
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
        connection.onClose = { [weak self] in
            self?.connected = false
            self?.status = "The tab closed or navigated away. Reconnect to continue."
        }
        connection.connect()
        self.connection = connection
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
    }

    // MARK: DOM

    func loadDocument() {
        connection?.send("DOM.getDocument", ["depth": -1, "pierce": true]) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let value):
                if let rootDict = value["root"] as? [String: Any] {
                    self.root = DOMParse.node(from: rootDict)
                    self.status = "Document loaded."
                }
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
        connection.send("DOM.setAttributeValue", ["nodeId": node.nodeId, "name": name, "value": value]) { [weak self] result in
            if case .success = result {
                if let index = node.attributes.firstIndex(where: { $0.name == name }) {
                    node.attributes[index].value = value
                } else {
                    node.attributes.append((name, value))
                }
                self?.objectWillChange.send()
                self?.status = "Set \(name)=\"\(value)\"."
                self?.refreshOuterHTML()
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

    func runEval() {
        let expression = evalInput.trimmed
        guard !expression.isEmpty, let connection = connection else { return }
        console.append(ConsoleLine(kind: .input, text: expression))
        evalInput = ""
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
            let text = args.map { RemoteObjectRender.describe($0) }.joined(separator: " ")
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
        connection?.send("DOM.pushNodesByBackendIdsToFrontend", ["backendNodeIds": [backendNodeId]]) { [weak self] result in
            guard let self = self, case .success(let value) = result,
                  let ids = value["nodeIds"] as? [Int], let nodeId = ids.first else { return }
            // Turn off inspect mode and select the picked node.
            self.picking = false
            self.connection?.send("Overlay.setInspectMode", ["mode": "none", "highlightConfig": [:]])
            if let root = self.root, let node = DOMParse.find(nodeId, in: root) {
                self.select(node)
            } else {
                self.loadDocument()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    if let root = self.root, let node = DOMParse.find(nodeId, in: root) { self.select(node) }
                }
            }
        }
    }

    deinit { connection?.close() }
}

// MARK: - AI assistant (non-streaming, reuses the School To-Do API keys from the Keychain)

enum InspectorAIError: LocalizedError {
    case noKey(AIProvider)
    case badKey(AIProvider)
    case declined(String)
    case http(AIProvider, Int, String)
    case network(String)
    case unreadable

    var errorDescription: String? {
        switch self {
        case .noKey(let p): return "No \(p.shortName) API key is saved yet. Add one above."
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
            completion(.failure(InspectorAIError.noKey(provider)))
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
                    TextField("9222", value: $session.port, format: .number)
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
                Text("If no tab was found, the browser isn't running with remote debugging. Launch it below. Recent Chrome only exposes debugging on a separate profile, so turn that on if the normal relaunch finds nothing.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Picker("Browser", selection: Binding(
                        get: { session.selectedBrowser },
                        set: { session.selectedBrowser = $0; session.refreshProfiles() })) {
                        ForEach(session.browsers) { browser in Text(browser.name).tag(Optional(browser)) }
                    }
                    .frame(maxWidth: 220)
                    if !session.useDedicatedProfile && !session.profiles.isEmpty {
                        Picker("Profile", selection: $session.selectedProfile) {
                            ForEach(session.profiles, id: \.self) { Text($0).tag($0) }
                        }
                        .frame(maxWidth: 180)
                    }
                }
                Toggle("Use a separate MacTools profile (needed on recent Chrome; keeps your main browsing separate)", isOn: $session.useDedicatedProfile)
                    .font(.caption)
                HStack {
                    Button("Launch & Connect") { session.launchAndDiscover() }
                        .buttonStyle(.borderedProminent)
                    if (session.selectedBrowser?.isRunning ?? false) && !session.useDedicatedProfile {
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
                VStack(spacing: 6) {
                    breadcrumb
                    detailTabs
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
            HStack {
                Button("Explain Element") { session.askAI(editMode: false) }
                Button("Suggest an Edit") { session.askAI(editMode: true) }
                if session.aiBusy { ProgressView().controlSize(.small) }
                Spacer()
            }
            .disabled(session.selectedNode == nil || session.aiBusy || !planner.hasKey(session.aiProvider))
            ScrollView {
                Text(session.aiOutput.isEmpty ? "Ask the model to explain or rewrite the selected element." : session.aiOutput)
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
            HStack {
                Text("Console").font(.caption.bold()).foregroundStyle(.secondary)
                Spacer()
                Button("Clear") { session.clearConsole() }.controlSize(.small)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(session.console) { line in
                            Text(consolePrefix(line.kind) + line.text)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(consoleColor(line.kind))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(line.id)
                        }
                    }
                }
                .onChange(of: session.console.count) { _ in
                    if let last = session.console.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            HStack {
                TextField("Run JavaScript in the page…", text: $session.evalInput)
                    .font(.system(size: 11, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { session.runEval() }
                Button("Run") { session.runEval() }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
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
        HStack(spacing: 4) {
            Text(node.summary)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(node.isElement ? (selected ? .white : .primary) : .secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 1).padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 4).fill(selected ? Color.accentColor : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture { session.select(node) }
        .onHover { hovering in if hovering && session.connected { session.highlight(node) } }
    }
}

/// Editable list of an element's attributes, plus an add row.
struct AttributesEditor: View {
    @ObservedObject var session: InspectorSession
    @ObservedObject var node: DOMNode
    @State private var newName = ""
    @State private var newValue = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Attributes").font(.caption.bold()).foregroundStyle(.secondary)
            ForEach(Array(node.attributes.enumerated()), id: \.offset) { _, attribute in
                HStack(spacing: 4) {
                    Text(attribute.name).font(.system(size: 11, design: .monospaced)).foregroundColor(.accentColor)
                    TextField("value", text: Binding(
                        get: { attribute.value },
                        set: { session.setAttribute(attribute.name, $0) }
                    ))
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
