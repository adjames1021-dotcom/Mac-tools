import SwiftUI
import AppKit
import WebKit
import UniformTypeIdentifiers

// MARK: - Serving downloaded games

/// Serves a downloaded game's folder at `mtgame://<id>/…`, so the game loads its data files the way it would from a
/// website (plain `file://` pages can't load most of them) and keeps one stable origin – and so one set of saves –
/// per game folder. Only files inside the folder are served.
final class GameSchemeHandler: NSObject {
    static let shared = GameSchemeHandler()
    static let scheme = "mtgame"

    private var roots: [String: URL] = [:]
    private var active = Set<ObjectIdentifier>()

    /// Registers a game folder and returns its host name (stable for the same folder, so saves persist).
    func register(_ folder: URL) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in folder.standardizedFileURL.path.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        let id = "g" + String(hash, radix: 16)
        roots[id] = folder.standardizedFileURL
        return id
    }

    private static let mimeTypes: [String: String] = [
        "html": "text/html", "htm": "text/html", "js": "text/javascript", "mjs": "text/javascript",
        "css": "text/css", "json": "application/json", "map": "application/json", "txt": "text/plain",
        "xml": "application/xml", "svg": "image/svg+xml", "png": "image/png", "jpg": "image/jpeg",
        "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp", "ico": "image/x-icon", "bmp": "image/bmp",
        "ogg": "audio/ogg", "oga": "audio/ogg", "mp3": "audio/mpeg", "m4a": "audio/mp4", "wav": "audio/wav",
        "mp4": "video/mp4", "webm": "video/webm", "ogv": "video/ogg", "wasm": "application/wasm",
        "woff": "font/woff", "woff2": "font/woff2", "ttf": "font/ttf", "otf": "font/otf",
    ]

    fileprivate func start(_ task: WKURLSchemeTask) {
        let key = ObjectIdentifier(task as AnyObject)
        active.insert(key)
        guard let url = task.request.url, let host = url.host?.lowercased(), let root = roots[host] else {
            finish(task, key, url: task.request.url, status: 404, data: Data(), type: "text/plain")
            return
        }
        var relative = url.path
        if relative.isEmpty || relative == "/" { relative = "/index.html" }
        var file = root.appendingPathComponent(String(relative.dropFirst())).standardizedFileURL
        guard file.path == root.path || file.path.hasPrefix(root.path + "/") else {
            finish(task, key, url: url, status: 403, data: Data(), type: "text/plain")
            return
        }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory), isDirectory.boolValue {
            file.appendPathComponent("index.html")
        }
        let range = task.request.value(forHTTPHeaderField: "Range")
        let type = Self.mimeTypes[file.pathExtension.lowercased()] ?? "application/octet-stream"
        DispatchQueue.global(qos: .userInitiated).async {
            let data = try? Data(contentsOf: file, options: .mappedIfSafe)
            DispatchQueue.main.async {
                guard let data = data else {
                    self.finish(task, key, url: url, status: 404, data: Data(), type: "text/plain")
                    return
                }
                // Audio and video ask for byte ranges.
                if let range = range, let span = Self.byteRange(range, size: data.count) {
                    self.finish(task, key, url: url, status: 206, data: data.subdata(in: span.0..<(span.1 + 1)), type: type,
                                extra: ["Content-Range": "bytes \(span.0)-\(span.1)/\(data.count)"])
                } else {
                    self.finish(task, key, url: url, status: 200, data: data, type: type)
                }
            }
        }
    }

    fileprivate func stop(_ task: WKURLSchemeTask) {
        active.remove(ObjectIdentifier(task as AnyObject))
    }

    private static func byteRange(_ header: String, size: Int) -> (Int, Int)? {
        guard size > 0, header.hasPrefix("bytes=") else { return nil }
        let parts = header.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        if parts[0].isEmpty, let suffix = Int(parts[1]) { return (max(0, size - suffix), size - 1) }
        guard let start = Int(parts[0]), start < size else { return nil }
        let end = Int(parts[1]).map { min($0, size - 1) } ?? size - 1
        return start <= end ? (start, end) : nil
    }

    private func finish(_ task: WKURLSchemeTask, _ key: ObjectIdentifier, url: URL?, status: Int, data: Data, type: String,
                        extra: [String: String] = [:]) {
        // Calling a task after WebKit stopped it throws, so only answer tasks that are still running.
        guard active.contains(key) else { return }
        active.remove(key)
        var headers = ["Content-Type": type, "Content-Length": String(data.count), "Accept-Ranges": "bytes",
                       "Cache-Control": "no-cache", "Access-Control-Allow-Origin": "*"]
        headers.merge(extra) { _, new in new }
        let response = HTTPURLResponse(url: url ?? URL(string: "\(Self.scheme)://x/")!, statusCode: status,
                                       httpVersion: "HTTP/1.1", headerFields: headers)
        if let response = response { task.didReceive(response) }
        task.didReceive(data)
        task.didFinish()
    }
}

extension GameSchemeHandler: WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) { start(urlSchemeTask) }
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) { stop(urlSchemeTask) }
}

// MARK: - Game host

struct GameSource: Codable, Hashable, Identifiable {
    var name: String
    /// A downloaded game: its folder and the page inside it to open.
    var folder: String?
    var page: String?
    /// A game on a website.
    var website: String?
    var id: String { (folder ?? "") + "|" + (page ?? "") + "|" + (website ?? "") }
}

/// One stored value the game keeps.
struct GameStorageItem: Identifiable, Hashable {
    enum Area: String, CaseIterable, Identifiable {
        case local = "Local Storage"
        case session = "Session Storage"
        case indexedDB = "IndexedDB"
        var id: String { rawValue }
    }
    let area: Area
    /// For IndexedDB: database, store and the key as JSON.
    var database = ""
    var store = ""
    let key: String
    var value: String
    /// "string", "json" or "binary" (IndexedDB values that aren't text can't be edited here).
    var kind = "string"
    var id: String { area.rawValue + "|" + database + "|" + store + "|" + key }
    var label: String { area == .indexedDB ? "\(database) › \(store) › \(key)" : key }
    var editable: Bool { kind != "binary" }
}

/// A number (or numeric text) found in the running game's variables, e.g. `Game.cookies`.
struct LiveValue: Identifiable, Hashable {
    let path: [String]
    var value: String
    var isString: Bool
    var id: String { path.joined(separator: "\u{1}") }
    var label: String { HTMLGameHost.expression(path) }
}

/// Runs a game in MacTools' own browser and reads and writes its storage directly.
final class HTMLGameHost: NSObject, ObservableObject {
    static let shared = HTMLGameHost()
    private static let recentsKey = "htmlGameRecents"

    @Published private(set) var source: GameSource?
    @Published private(set) var items: [GameStorageItem] = []
    @Published private(set) var recents: [GameSource]
    @Published private(set) var origin = ""
    @Published private(set) var loading = false
    @Published var status = ""
    @Published var reloadAfterSave = true
    @Published private(set) var liveResults: [LiveValue] = []
    @Published private(set) var liveCount = 0
    @Published private(set) var liveStatus = ""
    @Published private(set) var liveScanning = false
    @Published private(set) var frozen: Set<String> = []

    private(set) lazy var webView: WKWebView = {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore.default()
        configuration.setURLSchemeHandler(GameSchemeHandler.shared, forURLScheme: GameSchemeHandler.scheme)
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 960, height: 640), configuration: configuration)
        view.customUserAgent = SchoolWeb.userAgent
        view.navigationDelegate = self
        view.uiDelegate = self
        return view
    }()

    override init() {
        recents = Prefs.load(Self.recentsKey, default: [GameSource]())
        super.init()
    }

    // MARK: Opening

    /// Opens a downloaded game: a folder (finds its index.html, also inside `www/`), or one .html file.
    func openLocal(_ url: URL) {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        let folder: URL
        let page: String
        if isDirectory.boolValue {
            folder = url
            let candidates = ["index.html", "www/index.html", "game/index.html", "html5game/index.html", "web/index.html"]
            if let found = candidates.first(where: { FileManager.default.fileExists(atPath: url.appendingPathComponent($0).path) }) {
                page = found
            } else if let html = (try? FileManager.default.contentsOfDirectory(atPath: url.path))?
                        .filter({ $0.lowercased().hasSuffix(".html") || $0.lowercased().hasSuffix(".htm") }).sorted().first {
                page = html
            } else {
                status = "No .html file found in that folder. Pick the game's main .html file instead."
                return
            }
        } else {
            folder = url.deletingLastPathComponent()
            page = url.lastPathComponent
        }
        open(GameSource(name: folder.lastPathComponent, folder: folder.path, page: page, website: nil))
    }

    func openWebsite(_ text: String) {
        guard let url = SchoolWeb.normalizedURL(text), let host = url.host else {
            status = "That doesn't look like a web address."
            return
        }
        open(GameSource(name: host, folder: nil, page: nil, website: url.absoluteString))
    }

    func open(_ game: GameSource) {
        let url: URL?
        if let path = game.folder, let page = game.page {
            let folder = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: folder.path) else {
                status = "That game folder isn't there any more."
                return
            }
            let host = GameSchemeHandler.shared.register(folder)
            let encoded = page.split(separator: "/").map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            url = URL(string: "\(GameSchemeHandler.scheme)://\(host)/" + encoded.joined(separator: "/"))
        } else {
            url = game.website.flatMap { URL(string: $0) }
        }
        guard let target = url else { return }
        source = game
        items = []
        status = ""
        loading = true
        webView.load(URLRequest(url: target))
        recents.removeAll { $0.id == game.id }
        recents.insert(game, at: 0)
        recents = Array(recents.prefix(12))
        Prefs.save(Self.recentsKey, recents)
    }

    func reloadGame() { webView.reload() }

    func stop() {
        webView.loadHTMLString("", baseURL: nil)
        source = nil
        items = []
        origin = ""
    }

    // MARK: Storage

    private static let readStorage = """
    const out = [];
    const dump = (area, store) => {
      try { for (let i = 0; i < store.length; i++) { const k = store.key(i); out.push({ area, key: k, value: store.getItem(k) || '', kind: 'string' }); } } catch (e) {}
    };
    dump('local', window.localStorage);
    dump('session', window.sessionStorage);
    const req = (r) => new Promise((resolve, reject) => { r.onsuccess = () => resolve(r.result); r.onerror = () => reject(r.error); });
    try {
      const dbs = indexedDB.databases ? await indexedDB.databases() : [];
      for (const info of dbs) {
        if (!info.name) continue;
        const db = await req(indexedDB.open(info.name));
        for (const storeName of Array.from(db.objectStoreNames)) {
          const tx = db.transaction(storeName, 'readonly');
          const store = tx.objectStore(storeName);
          const keys = await req(store.getAllKeys());
          const values = await req(store.getAll());
          keys.slice(0, 400).forEach((k, i) => {
            const v = values[i];
            let kind = 'string', text = '';
            if (typeof v === 'string') { text = v; }
            else if (v instanceof ArrayBuffer || ArrayBuffer.isView(v) || (typeof Blob !== 'undefined' && v instanceof Blob)) {
              kind = 'binary'; text = '(binary data' + (v.byteLength ? ', ' + v.byteLength + ' bytes' : '') + ')';
            } else {
              try { text = JSON.stringify(v); kind = 'json'; } catch (e) { text = String(v); kind = 'binary'; }
            }
            out.push({ area: 'indexedDB', database: info.name, store: storeName, key: JSON.stringify(k), value: text, kind });
          });
        }
        db.close();
      }
    } catch (e) {}
    return JSON.stringify({ origin: location.origin, items: out });
    """

    private struct Dump: Decodable {
        struct Row: Decodable {
            let area: String
            let database: String?
            let store: String?
            let key: String
            let value: String
            let kind: String
        }
        let origin: String
        let items: [Row]
    }

    /// Reads everything the page has stored.
    func refresh() {
        guard source != nil else { return }
        webView.callAsyncJavaScript(Self.readStorage, arguments: [:], in: nil, in: .page) { [weak self] result in
            guard let self = self else { return }
            guard case .success(let value) = result, let json = value as? String,
                  let dump = try? JSONDecoder().decode(Dump.self, from: Data(json.utf8)) else {
                self.status = "Couldn't read the game's storage yet – wait for it to load, then Refresh."
                return
            }
            self.origin = dump.origin
            self.items = dump.items.map { row in
                let area: GameStorageItem.Area = row.area == "local" ? .local : row.area == "session" ? .session : .indexedDB
                return GameStorageItem(area: area, database: row.database ?? "", store: row.store ?? "",
                                       key: row.key, value: row.value, kind: row.kind)
            }
        }
    }

    private static let writeStorage = """
    if (area === 'local') { if (remove) localStorage.removeItem(key); else localStorage.setItem(key, value); return true; }
    if (area === 'session') { if (remove) sessionStorage.removeItem(key); else sessionStorage.setItem(key, value); return true; }
    const req = (r) => new Promise((resolve, reject) => { r.onsuccess = () => resolve(r.result); r.onerror = () => reject(r.error); });
    const db = await req(indexedDB.open(database));
    const tx = db.transaction(store, 'readwrite');
    const os = tx.objectStore(store);
    const k = JSON.parse(key);
    if (remove) { await req(os.delete(k)); }
    else {
      const v = kind === 'json' ? JSON.parse(value) : value;
      if (os.keyPath) { await req(os.put(v)); } else { await req(os.put(v, k)); }
    }
    await new Promise((resolve) => { tx.oncomplete = resolve; tx.onerror = resolve; tx.onabort = resolve; });
    db.close();
    return true;
    """

    /// Writes (or removes) one value, then re-reads storage – and reloads the game so it picks the change up.
    func write(_ item: GameStorageItem, value: String?, reload: Bool? = nil) {
        let arguments: [String: Any] = [
            "area": item.area == .local ? "local" : item.area == .session ? "session" : "indexedDB",
            "database": item.database, "store": item.store, "key": item.key,
            "value": value ?? "", "kind": item.kind, "remove": value == nil,
        ]
        webView.callAsyncJavaScript(Self.writeStorage, arguments: arguments, in: nil, in: .page) { [weak self] result in
            guard let self = self else { return }
            if case .failure(let error) = result {
                self.status = "Couldn't save that: \(error.localizedDescription)"
                return
            }
            self.status = value == nil ? "Removed \(item.label)." : "Saved \(item.label)."
            if reload ?? self.reloadAfterSave {
                self.webView.reload()
            } else {
                self.refresh()
            }
        }
    }

    func add(key: String, value: String, area: GameStorageItem.Area) {
        write(GameStorageItem(area: area, key: key, value: value), value: value)
    }

    /// Everything in Local and Session Storage as JSON (a backup you can restore later).
    func exportJSON() -> String {
        var local: [String: String] = [:]
        var session: [String: String] = [:]
        for item in items {
            if item.area == .local { local[item.key] = item.value }
            if item.area == .session { session[item.key] = item.value }
        }
        let object: [String: Any] = ["origin": origin, "localStorage": local, "sessionStorage": session]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    func importJSON(_ text: String) {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else {
            status = "That backup file isn't valid."
            return
        }
        let local = object["localStorage"] as? [String: String] ?? [:]
        let session = object["sessionStorage"] as? [String: String] ?? [:]
        let total = local.count + session.count
        guard total > 0 else {
            status = "That backup is empty."
            return
        }
        // One script writes everything, so the game only restarts once it's all in.
        let script = """
        for (const [k, v] of Object.entries(local)) localStorage.setItem(k, v);
        for (const [k, v] of Object.entries(session)) sessionStorage.setItem(k, v);
        return true;
        """
        webView.callAsyncJavaScript(script, arguments: ["local": local, "session": session], in: nil, in: .page) { [weak self] result in
            guard let self = self else { return }
            if case .failure(let error) = result {
                self.status = "Couldn't restore: \(error.localizedDescription)"
                return
            }
            self.status = "Restored \(total) value\(total == 1 ? "" : "s")."
            if self.reloadAfterSave { self.webView.reload() } else { self.refresh() }
        }
    }

    // MARK: Live values

    /// How a search for an unknown value narrows: by the typed value, or by how the value moved since the last check.
    enum LiveCompare: String { case equal, increased, decreased, changed, unchanged }

    /// Finds and changes a game's top-level variables: properties of `window`, and also `let`/`const`/`class`
    /// declarations in its scripts, which never appear on `window` but can be reached by name with a global eval.
    private static let liveResolver = """
    const __mtRoot = (k) => {
      if (k in window) return window[k];
      if (!/^[A-Za-z_$][\\w$]*$/.test(k)) return undefined;
      try { return (0, eval)(k); } catch (e) { return undefined; }
    };
    const get = (path) => { let o = __mtRoot(path[0]); for (let i = 1; i < path.length; i++) { if (o === null || o === undefined) return undefined; try { o = o[path[i]]; } catch (e) { return undefined; } } return o; };
    const put = (path, value) => {
      if (path.length === 1 && !(path[0] in window)) { window.__mtValue = value; (0, eval)(path[0] + ' = window.__mtValue'); return; }
      const o = path.length === 1 ? window : get(path.slice(0, -1));
      o[path[path.length - 1]] = value;
    };
    const pack = (path) => { const v = get(path); return { path, value: typeof v === 'string' ? v : String(v), isString: typeof v === 'string' }; };

    """

    /// Searches the running game's own variables (everything it put on `window` or declared at the top of its
    /// scripts, followed down into objects and arrays) for a number. The matches stay in the page, so Narrow Down
    /// re-checks them: by the new value, or – for an unknown value – by whether it went up, down or stayed.
    private static let liveScanScript = liveResolver + """
    const unknown = mode === 'unknown';
    const num = (v) => {
      if (typeof v === 'number') return isFinite(v) ? v : null;
      if (unknown || typeof v !== 'string' || v.length > 40 || v.trim() === '') return null;
      const n = Number(v);
      return isFinite(n) ? n : null;
    };
    const hits = (n) => n === target || (close && (Math.floor(n) === Math.floor(target) || Math.abs(n - target) <= Math.max(1, Math.abs(target) * 0.01)));
    const finish = (paths, values, visited) => {
      window.__mtLive = { paths, values };
      return JSON.stringify({ results: paths.slice(0, maxResults).map(pack), total: paths.length, visited });
    };
    if (narrow) {
      const prev = window.__mtLive;
      if (!prev) return JSON.stringify({ lost: true, results: [], total: 0, visited: 0 });
      const paths = [], values = [];
      prev.paths.forEach((p, i) => {
        const n = num(get(p));
        if (n === null) return;
        const old = prev.values[i];
        const ok = compare === 'equal' ? hits(n) : compare === 'increased' ? n > old : compare === 'decreased' ? n < old
          : compare === 'changed' ? n !== old : n === old;
        if (ok) { paths.push(p); values.push(n); }
      });
      return finish(paths, values, prev.paths.length);
    }
    const limit = unknown ? 300000 : 5000;
    const builtins = new Set();
    try {
      const f = document.createElement('iframe');
      f.style.display = 'none';
      document.documentElement.appendChild(f);
      for (const k of Object.getOwnPropertyNames(f.contentWindow)) builtins.add(k);
      f.remove();
    } catch (e) {}
    const skip = new Set(['window', 'self', 'top', 'parent', 'frames', 'globalThis', 'document', 'location', 'navigator']);
    const isNode = (v) => typeof Node !== 'undefined' && v instanceof Node;
    const seen = new WeakSet();
    const queue = [];
    const paths = [], values = [];
    let head = 0, visited = 0;
    const consider = (path, v) => { const n = num(v); if (n !== null && (unknown || hits(n))) { paths.push(path); values.push(n); } };
    const push = (holder, key, path, depth) => {
      let d;
      try { d = Object.getOwnPropertyDescriptor(holder, key); } catch (e) { return; }
      if (!d || d.get || d.set) return;   // never run getters: they can have side effects
      const v = d.value;
      if (typeof v === 'number' || typeof v === 'string') { consider(path, v); return; }
      if (v && (typeof v === 'object' || (typeof v === 'function' && depth === 1))) queue.push([v, path, depth]);
    };
    for (const key of Object.getOwnPropertyNames(window)) {
      if (builtins.has(key) || skip.has(key) || key.startsWith('__mt') || key.startsWith('webkit')) continue;
      push(window, key, [key], 1);
    }
    // Top-level let/const/class names, read from the page's classic scripts.
    // shortcut: misses `let a = 1, b = 2` (only `a`) and destructuring, and module scripts can't be reached at all.
    const declared = new Set();
    const declRe = /(?:^|[^.\\w$])(?:let|const|var|class)\\s+([A-Za-z_$][\\w$]*)/g;
    const collect = (text) => { if (text.length > 30e6) return; let m; while ((m = declRe.exec(text)) && declared.size < 20000) declared.add(m[1]); };
    for (const s of Array.from(document.scripts)) {
      if (s.type === 'module') continue;
      if (s.src) { try { const r = await fetch(s.src); if (r.ok) collect(await r.text()); } catch (e) {} }
      else collect(s.textContent || '');
    }
    for (const name of declared) {
      if (name in window || builtins.has(name) || skip.has(name)) continue;
      let v;
      try { v = (0, eval)(name); } catch (e) { continue; }   // function-scoped names throw here: not global
      if (typeof v === 'number' || typeof v === 'string') consider([name], v);
      else if (v && (typeof v === 'object' || typeof v === 'function')) queue.push([v, [name], 1]);
    }
    while (head < queue.length && visited < 300000 && paths.length < limit) {
      const [v, path, depth] = queue[head++];
      visited++;
      if (seen.has(v)) continue;
      seen.add(v);
      if (depth >= 8 || isNode(v) || v === window || ArrayBuffer.isView(v) || v instanceof ArrayBuffer) continue;
      let keys;
      try { keys = Array.isArray(v) ? (v.length > 20000 ? [] : Object.keys(v)) : Object.getOwnPropertyNames(v); } catch (e) { continue; }
      if (keys.length > 20000) continue;
      for (const k of keys) {
        if (typeof v === 'function' && (k === 'prototype' || k === 'length' || k === 'name')) continue;
        push(v, k, path.concat(k), depth + 1);
      }
    }
    return finish(paths, values, visited);
    """

    private static let liveSetScript = liveResolver + """
    put(path, isString ? String(value) : Number(value));
    return String(get(path));
    """

    private static let liveFreezeScript = liveResolver + """
    window.__mtFrozen = window.__mtFrozen || {};
    if (on) { window.__mtFrozen[id] = { path, value: isString ? String(value) : Number(value) }; }
    else { delete window.__mtFrozen[id]; }
    if (!window.__mtFreezeTimer) {
      window.__mtFreezeTimer = setInterval(() => {
        for (const k in window.__mtFrozen) { const f = window.__mtFrozen[k]; try { put(f.path, f.value); } catch (e) {} }
      }, 100);
    }
    return Object.keys(window.__mtFrozen).length;
    """

    private static let liveReadScript = liveResolver + """
    return JSON.stringify(paths.map(pack));
    """

    private struct LiveRow: Decodable {
        let path: [String]
        let value: String
        let isString: Bool
    }

    private struct LiveScan: Decodable {
        let results: [LiveRow]
        let total: Int
        let visited: Int
        /// The page reloaded since the last search, so its matches are gone.
        let lost: Bool?
    }

    /// A JavaScript expression for a variable, e.g. `Game.cookies` or `Game.Objects["Cursor"].amount`.
    static func expression(_ path: [String]) -> String {
        var out = ""
        for (index, key) in path.enumerated() {
            let identifier = key.first.map { $0.isLetter || $0 == "_" || $0 == "$" } == true
                && key.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "$" }
            if index > 0 && Int(key) != nil {
                out += "[\(key)]"
            } else if identifier {
                out += index == 0 ? key : "." + key
            } else {
                let quoted = (try? JSONSerialization.data(withJSONObject: [key]))
                    .map { String(String(decoding: $0, as: UTF8.self).dropFirst().dropLast()) } ?? "\"\""
                out += (index == 0 ? "window" : "") + "[\(quoted)]"
            }
        }
        return out
    }

    /// A line to paste into Chrome's (or any browser's) DevTools Console to make the same change there.
    static func consoleLine(_ value: LiveValue, newValue: String) -> String {
        let literal: String
        if value.isString {
            literal = (try? JSONSerialization.data(withJSONObject: [newValue])).map { String(String(decoding: $0, as: UTF8.self).dropFirst().dropLast()) } ?? "\"\""
        } else {
            literal = newValue.trimmed
        }
        return "\(expression(value.path)) = \(literal);"
    }

    /// `unknown` starts from every number in the game; `compare` narrows the earlier matches.
    func liveScan(_ query: String, close: Bool, unknown: Bool = false, narrow: Bool, compare: LiveCompare = .equal) {
        let needsValue = narrow ? compare == .equal : !unknown
        let target = Double(query.trimmed)
        if needsValue && target == nil {
            liveStatus = "Type the number you see in the game."
            return
        }
        guard source != nil else { return }
        liveScanning = true
        liveStatus = narrow ? "Checking the \(liveCount) earlier matches…" : "Searching the game's variables…"
        let arguments: [String: Any] = ["mode": unknown ? "unknown" : "exact", "target": target ?? 0, "close": close,
                                        "narrow": narrow, "compare": compare.rawValue, "maxResults": 300]
        webView.callAsyncJavaScript(Self.liveScanScript, arguments: arguments, in: nil, in: .page) { [weak self] result in
            guard let self = self else { return }
            self.liveScanning = false
            guard case .success(let value) = result, let json = value as? String,
                  let scan = try? JSONDecoder().decode(LiveScan.self, from: Data(json.utf8)) else {
                self.liveStatus = "Couldn't search this page. Wait for the game to finish loading and try again."
                return
            }
            self.liveCount = scan.total
            self.liveResults = scan.results.map { LiveValue(path: $0.path, value: $0.value, isString: $0.isString) }
            if scan.lost == true {
                self.liveStatus = "The game restarted, so the earlier matches are gone. Start a New Search."
                return
            }
            let next = unknown || compare != .equal
                ? " Change it in the game (take damage, spend some…), then say how it changed."
                : " Change the number in the game, type the new one and press Narrow Down."
            switch scan.total {
            case 0: self.liveStatus = narrow ? "None of the earlier matches fits. Start a New Search." : "Nothing found. Try “Close to”, or the exact number from a stats screen."
            case 1: self.liveStatus = "Found it – 1 match."
            default:
                self.liveStatus = "\(scan.total) matches" + (narrow ? "." : " (checked \(scan.visited) values).") + next
            }
        }
    }

    func liveSet(_ value: LiveValue, to text: String) {
        guard value.isString || Double(text.trimmed) != nil else {
            status = "Type a number for \(value.label)."
            return
        }
        let arguments: [String: Any] = ["path": value.path, "value": value.isString ? text : (Double(text.trimmed) ?? 0), "isString": value.isString]
        webView.callAsyncJavaScript(Self.liveSetScript, arguments: arguments, in: nil, in: .page) { [weak self] result in
            guard let self = self else { return }
            if case .success(let written) = result, let shown = written as? String {
                self.status = "Set \(value.label) to \(shown). The game saves it itself next time it saves."
                self.liveRefresh()
            } else {
                self.status = "Couldn't set \(value.label)."
            }
        }
    }

    /// Keeps a value pinned (rewritten 10 times a second) until it's unfrozen or the game reloads.
    func liveFreeze(_ value: LiveValue, on: Bool, text: String) {
        let arguments: [String: Any] = ["id": value.id, "path": value.path, "on": on, "isString": value.isString,
                                        "value": value.isString ? text : (Double(text.trimmed) ?? Double(value.value) ?? 0)]
        webView.callAsyncJavaScript(Self.liveFreezeScript, arguments: arguments, in: nil, in: .page) { [weak self] result in
            guard let self = self, case .success = result else { return }
            if on { self.frozen.insert(value.id) } else { self.frozen.remove(value.id) }
            self.status = on ? "Froze \(value.label) at \(text)." : "Unfroze \(value.label)."
        }
    }

    /// Re-reads the shown matches' current values.
    func liveRefresh() {
        guard !liveResults.isEmpty else { return }
        webView.callAsyncJavaScript(Self.liveReadScript, arguments: ["paths": liveResults.map(\.path)], in: nil, in: .page) { [weak self] result in
            guard let self = self, case .success(let value) = result, let json = value as? String,
                  let rows = try? JSONDecoder().decode([LiveRow].self, from: Data(json.utf8)) else { return }
            self.liveResults = rows.map { LiveValue(path: $0.path, value: $0.value, isString: $0.isString) }
        }
    }

    fileprivate func pageLoaded() {
        loading = false
        frozen = []   // a reload clears the page's freeze timer
        // Games set up their saves after starting, so read storage a moment later.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.refresh() }
    }
}

extension HTMLGameHost: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { pageLoaded() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { loading = false }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loading = false
        status = "Couldn't open the game: \(error.localizedDescription)"
    }
}

extension HTMLGameHost: WKUIDelegate {
    /// Games that open a new window (credits, links) open it in the same view.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            NSWorkspace.shared.open(url)
        }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.runModal()
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = prompt
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        completionHandler(alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil)
    }
}

// MARK: - View

struct HTMLGameEditorView: View {
    @ObservedObject private var host = HTMLGameHost.shared
    @State private var website = ""
    @State private var area = GameStorageItem.Area.local
    @State private var find = ""
    @State private var editing: GameStorageItem?
    @State private var showStorage = true
    @State private var newKey = ""
    @State private var panel = Panel.live
    @State private var liveQuery = ""
    @State private var liveClose = false
    @State private var liveUnknown = false
    @State private var liveSelected: LiveValue?
    @State private var liveNew = ""

    enum Panel: String, CaseIterable, Identifiable {
        case live = "Live Values"
        case saves = "Saves & Storage"
        var id: String { rawValue }
    }

    var body: some View {
        ToolPage(tool: .htmlGames, scrolls: false) {
            toolbar
            HStack(alignment: .top, spacing: 12) {
                gameArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if showStorage {
                    storagePanel
                        .frame(width: 400)
                }
            }
            .frame(maxHeight: .infinity)
            if !host.status.isEmpty {
                Label(host.status, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
            }
        }
        .sheet(item: $editing) { item in
            GameDataEditorView(title: item.label, original: item.value, onSave: { packed in
                host.write(item, value: packed)
                editing = nil
            }, onCancel: { editing = nil })
            .padding(20)
            .frame(width: 720, height: 600)
            .themedRoot()
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button {
                if let url = Panels.chooseFiles(multiple: false, directories: true,
                                                message: "Choose a downloaded HTML game: its folder or its main .html file").first {
                    host.openLocal(url)
                }
            } label: {
                Label("Open Game…", systemImage: "folder")
            }
            TextField("…or a website with an HTML game", text: $website)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 300)
                .onSubmit { host.openWebsite(website) }
            Button("Play") { host.openWebsite(website) }
                .disabled(website.trimmed.isEmpty)
            if !host.recents.isEmpty {
                Menu("Recent") {
                    ForEach(host.recents) { game in
                        Button(game.name) { host.open(game) }
                    }
                }
                .fixedSize()
            }
            Spacer()
            if host.source != nil {
                if host.loading { ProgressView().controlSize(.small) }
                Button { host.reloadGame() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Restart the game")
                Button { host.stop() } label: { Image(systemName: "stop.fill") }
                    .help("Close the game")
            }
            Toggle("Saves panel", isOn: $showStorage)
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }

    @ViewBuilder
    private var gameArea: some View {
        if host.source != nil {
            HostedNSView(view: host.webView)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.12)))
        } else {
            VStack(spacing: 12) {
                Image(systemName: "gamecontroller").font(.system(size: 44)).foregroundStyle(.secondary)
                Text("Play an HTML game here and edit its saves").font(.title3.bold())
                Text("Open a downloaded game's folder (RPG Maker MV/MZ, Construct, GameMaker, Twine, Phaser and most other HTML5 games), or type the address of a website game. Then change values like gold, lives or level in the saves panel – they're written straight into the game.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 520)
                Text("Downloaded RPG Maker games that keep saves as files (www/save/*.rpgsave) can also be opened in the Save Editor.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
        }
    }

    private var areaItems: [GameStorageItem] { host.items.filter { $0.area == area } }

    /// Values across every stored save that match the search, by unpacking each one.
    private var found: [(item: GameStorageItem, leaf: JSONLeaf)] {
        let query = find.trimmed
        guard !query.isEmpty else { return [] }
        var out: [(GameStorageItem, JSONLeaf)] = []
        for item in host.items where item.editable {
            if let decoded = GameDataCodec.decode(item.value) {
                for leaf in JSONTree.matches(JSONTree.leaves(decoded.json), query).prefix(50) { out.append((item, leaf)) }
            }
            if out.count > 300 { break }
        }
        return out
    }

    private var storagePanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: $panel) {
                ForEach(Panel.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            switch panel {
            case .live: liveView
            case .saves: savesView
            }
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
    }

    // MARK: Live values

    private var liveView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: $liveUnknown) {
                Text("Exact value").tag(false)
                Text("Unknown value").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if liveUnknown {
                Text("For values the game doesn't show as a number, like a health bar. Press New Search, change the value in the game, then say how it changed. Repeat until one or two are left.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Change a number in a running single-player game – cookies, coins, lives, score. Type the number the game shows right now:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    TextField("e.g. 1500", text: $liveQuery)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { host.liveScan(liveQuery, close: liveClose, narrow: false) }
                    Toggle("Close to", isOn: $liveClose)
                        .help("Also match numbers within 1% – for games that show rounded numbers like “1.2 million”")
                }
            }
            HStack {
                Button("New Search") {
                    liveSelected = nil
                    host.liveScan(liveQuery, close: liveClose, unknown: liveUnknown, narrow: false)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!liveUnknown && Double(liveQuery.trimmed) == nil)
                if !liveUnknown {
                    Button("Narrow Down") { host.liveScan(liveQuery, close: liveClose, narrow: true) }
                        .disabled(host.liveCount == 0 || Double(liveQuery.trimmed) == nil)
                        .help("Keep only the earlier matches that now have this value")
                }
                if host.liveScanning { ProgressView().controlSize(.small) }
                Spacer()
                Button { host.liveRefresh() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Show the current values")
                    .disabled(host.liveResults.isEmpty)
            }
            .disabled(host.source == nil || host.liveScanning)
            if liveUnknown {
                HStack {
                    ForEach([HTMLGameHost.LiveCompare.increased, .decreased, .changed, .unchanged], id: \.self) { compare in
                        Button(compare.rawValue.capitalized) {
                            host.liveScan(liveQuery, close: liveClose, narrow: true, compare: compare)
                        }
                    }
                }
                .controlSize(.small)
                .disabled(host.source == nil || host.liveScanning || host.liveCount == 0)
            }
            if !host.liveStatus.isEmpty {
                Text(host.liveStatus).font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(host.liveResults) { value in
                        Button {
                            liveSelected = value
                            liveNew = value.value
                        } label: {
                            HStack {
                                if host.frozen.contains(value.id) {
                                    Image(systemName: "snowflake").foregroundColor(.blue).font(.caption)
                                }
                                Text(value.label).font(.system(.caption, design: .monospaced)).lineLimit(1).truncationMode(.head)
                                Spacer()
                                Text(value.value).font(.system(.callout, design: .monospaced)).lineLimit(1)
                            }
                            .padding(.vertical, 3).padding(.horizontal, 6)
                            .background(RoundedRectangle(cornerRadius: 5).fill(liveSelected?.id == value.id ? Color.accentColor.opacity(0.18) : .clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if let value = liveSelected {
                VStack(alignment: .leading, spacing: 6) {
                    Text(value.label).font(.system(.caption, design: .monospaced)).lineLimit(2)
                    HStack {
                        TextField("New value", text: $liveNew)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { host.liveSet(value, to: liveNew) }
                        Button("Set") { host.liveSet(value, to: liveNew) }
                            .disabled(!value.isString && Double(liveNew.trimmed) == nil)
                    }
                    HStack {
                        Toggle("Freeze", isOn: Binding(
                            get: { host.frozen.contains(value.id) },
                            set: { host.liveFreeze(value, on: $0, text: liveNew) }
                        ))
                        .help("Keep it at this value, even when the game changes it")
                        Spacer()
                        Button("Copy for Chrome") {
                            ClipboardHelper.copy(HTMLGameHost.consoleLine(value, newValue: liveNew))
                            host.status = "Copied. In Chrome, open the game, press ⌥⌘J for the Console, paste and press Return."
                        }
                        .help("A one-line script that makes the same change in the game in Chrome or any browser")
                    }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            }
            Text("Tip: lots of matches? Change the number in the game (earn or spend some), type the new number and press Narrow Down. Repeat until one or two are left. Finds variables on window and top-level let/const ones in the game's scripts. The game saves your change itself.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: Saves

    private var savesView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Saves & Storage").font(.headline)
                Spacer()
                Button { host.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Read the storage again")
                    .disabled(host.source == nil)
                Menu {
                    Button("Back Up to a File…") { backUp() }
                    Button("Restore from a File…") { restore() }
                    Divider()
                    Button("Copy Everything as JSON") { ClipboardHelper.copy(host.exportJSON()) }
                } label: {
                    Image(systemName: "externaldrive")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(host.source == nil)
            }
            if !host.origin.isEmpty {
                Text(host.origin).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find a value in all saves (e.g. 1500 or “gold”)", text: $find)
                    .textFieldStyle(.plain)
            }
            .padding(7)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
            if !find.trimmed.isEmpty {
                foundList
            } else {
                Picker("", selection: $area) {
                    ForEach(GameStorageItem.Area.allCases) { area in
                        Text("\(area.rawValue.replacingOccurrences(of: " Storage", with: "")) (\(host.items.filter { $0.area == area }.count))").tag(area)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                itemList
                if area != .indexedDB && host.source != nil {
                    HStack {
                        TextField("New key", text: $newKey).textFieldStyle(.roundedBorder)
                        Button("Add") {
                            host.add(key: newKey.trimmed, value: "", area: area)
                            newKey = ""
                        }
                        .disabled(newKey.trimmed.isEmpty)
                    }
                }
            }
            Toggle("Restart the game after saving a change", isOn: $host.reloadAfterSave)
                .font(.caption)
            Text("Changes go straight into this game's storage in MacTools. A game that's running may save over them, so the game restarts after each change by default. For games that keep saving from memory (like Cookie Clicker), Live Values is the surer way.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var itemList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                if areaItems.isEmpty {
                    Text(host.source == nil ? "Open a game to see its saves." : "Nothing stored here yet. Play until the game saves, then Refresh.")
                        .font(.caption).foregroundStyle(.secondary).padding(.vertical, 20)
                }
                ForEach(areaItems) { item in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.label).font(.system(.callout, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                            Text(item.value.prefix(120)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer()
                        if item.editable {
                            Button("Edit") { editing = item }
                        } else {
                            Text("binary").font(.caption).foregroundStyle(.secondary)
                        }
                        Button { host.write(item, value: nil) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .help("Delete this value")
                    }
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
                }
            }
        }
    }

    private var foundList: some View {
        let results = found
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                if results.isEmpty {
                    Text("No matching values. Saves are searched after they're unpacked – try the exact number shown in the game.")
                        .font(.caption).foregroundStyle(.secondary).padding(.vertical, 20)
                }
                ForEach(Array(results.enumerated()), id: \.offset) { _, hit in
                    Button {
                        editing = hit.item
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(hit.item.label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            HStack {
                                Text(hit.leaf.id).font(.system(.callout, design: .monospaced)).lineLimit(1).truncationMode(.head)
                                Spacer()
                                Text(hit.leaf.text).font(.system(.callout, design: .monospaced))
                            }
                        }
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func backUp() {
        guard let url = Panels.saveFile(name: "\(host.source?.name ?? "game") saves.json", types: [.json]) else { return }
        do {
            try host.exportJSON().write(to: url, atomically: true, encoding: .utf8)
            host.status = "Backed up to \(url.lastPathComponent)."
        } catch {
            host.status = "Couldn't write the backup: \(error.localizedDescription)"
        }
    }

    private func restore() {
        guard let url = Panels.chooseFiles(multiple: false, types: [.json]).first,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        host.importJSON(text)
    }
}
