import SwiftUI

/// Hiddify-style proxy client: runs the open-source sing-box core as a child process
/// with a local HTTP/SOCKS ("mixed") port, optionally set as the macOS system proxy.
final class ProxyClient: ObservableObject {
    static let shared = ProxyClient()

    struct Saved: Codable {
        var subscriptionURL = ""
        var servers: [ProxyServer] = []
        var selected: UUID?
        var port = 2080
        var systemProxy = true
    }

    @Published var saved: Saved { didSet { DataStore.save(saved, to: "proxy-client.json") } }
    @Published var latency: [UUID: Int] = [:]  // ms, -1 = failed
    @Published var testing = false
    @Published var message = ""
    let runner = CommandRunner()
    private var connectedServer: UUID?

    private init() {
        saved = DataStore.load(Saved.self, from: "proxy-client.json") ?? Saved()
    }

    static func locate() -> String? {
        ["/opt/homebrew/bin/sing-box", "/usr/local/bin/sing-box"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    var connected: Bool { runner.running }
    var selectedIndex: Int? { saved.servers.firstIndex { $0.id == saved.selected } }

    // MARK: Import

    func importText(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: t), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), !t.contains("\n") {
            saved.subscriptionURL = t
            updateSubscription()
        } else {
            apply(ProxyLinks.parse(t), replace: false)
        }
    }

    func updateSubscription() {
        guard let url = URL(string: saved.subscriptionURL) else { return }
        message = "Downloading subscription…"
        URLSession.shared.dataTask(with: url) { data, response, error in
            DispatchQueue.main.async {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard let data = data, error == nil, (200..<300).contains(status) else {
                    self.message = "Couldn’t download the subscription: \(error?.localizedDescription ?? "HTTP \(status)")"
                    return
                }
                self.apply(ProxyLinks.parse(String(decoding: data, as: UTF8.self)), replace: true)
            }
        }.resume()
    }

    private func apply(_ result: (servers: [ProxyServer], skipped: Int), replace: Bool) {
        if result.servers.isEmpty {
            message = "No servers found. Paste vless://, vmess://, trojan://, ss://, hysteria2:// or tuic:// links, a subscription URL or a sing-box config."
            return
        }
        // Keep the selected server across subscription updates when it's still there.
        let oldSelected = saved.servers.first { $0.id == saved.selected }
        saved.servers = replace ? result.servers : saved.servers + result.servers
        latency = [:]
        saved.selected = saved.servers.first { $0.outbound == oldSelected?.outbound }?.id ?? saved.selected
        if selectedIndex == nil { saved.selected = saved.servers.first?.id }
        message = "Imported \(result.servers.count) server\(result.servers.count == 1 ? "" : "s")"
            + (result.skipped > 0 ? " (\(result.skipped) unsupported line\(result.skipped == 1 ? "" : "s") skipped)" : "") + "."
    }

    func removeAll() {
        disconnect()
        saved.servers = []
        saved.selected = nil
        latency = [:]
    }

    // MARK: Connect

    func select(_ id: UUID) {
        saved.selected = id
        if connected && connectedServer != id { connect() }  // switch server: restart the core
    }

    func connect() {
        guard let singBox = Self.locate(), let i = selectedIndex else { return }
        let server = saved.servers[i]
        // Only the chosen server goes into the config, so one bad entry elsewhere can't stop the connection.
        let config = ProxyLinks.config(servers: [server], selected: 0, mixedPort: saved.port,
                                       systemProxy: saved.systemProxy, apiPort: nil)
        let url = DataStore.url("proxy-client-config.json")
        try? config.write(to: url, options: .atomic)
        runner.stop(wait: true)
        connectedServer = server.id
        message = ""
        runner.run(executable: singBox, args: ["run", "--disable-color", "-c", url.path],
                   header: "▶︎ sing-box: \(server.name) on 127.0.0.1:\(saved.port)")
    }

    /// sing-box clears the system proxy itself when it gets SIGTERM.
    func disconnect() {
        runner.stop(wait: true)
        connectedServer = nil
    }

    // MARK: Latency test

    /// Starts a separate sing-box with every server (no inbound) and asks its Clash API for each server's delay.
    func testLatency() {
        guard let singBox = Self.locate(), !saved.servers.isEmpty, !testing else { return }
        testing = true
        latency = [:]
        let servers = saved.servers
        let apiPort = Int.random(in: 30000...60000)  // shortcut: random port, may rarely collide; pick a free one if that bites
        let url = DataStore.url("proxy-client-test.json")
        try? ProxyLinks.config(servers: servers, selected: 0, mixedPort: nil, systemProxy: false, apiPort: apiPort)
            .write(to: url, options: .atomic)
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: singBox)
            process.arguments = ["run", "-c", url.path]
            let errPipe = Pipe()
            process.standardOutput = FileHandle.nullDevice
            process.standardError = errPipe
            var results: [UUID: Int] = [:]
            var failure: String?
            do {
                try process.run()
                let base = "http://127.0.0.1:\(apiPort)"
                var up = false
                for _ in 0..<30 where process.isRunning {
                    if Self.get("\(base)/version", timeout: 1) != nil { up = true; break }
                    Thread.sleep(forTimeInterval: 0.1)
                }
                if up {
                    let lock = NSLock()
                    DispatchQueue.concurrentPerform(iterations: servers.count) { i in
                        let json = Self.get("\(base)/proxies/s\(i)/delay?timeout=5000&url=https%3A%2F%2Fwww.gstatic.com%2Fgenerate_204", timeout: 7)
                        let delay = json?["delay"] as? Int ?? -1
                        lock.lock(); results[servers[i].id] = delay > 0 ? delay : -1; lock.unlock()
                    }
                } else {
                    process.terminate()
                    process.waitUntilExit()
                    failure = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                }
            } catch {
                failure = error.localizedDescription
            }
            if process.isRunning { process.terminate() }
            DispatchQueue.main.async {
                self.latency = results
                self.testing = false
                if let failure = failure {
                    self.message = "Latency test couldn’t start sing-box: "
                        + failure.trimmingCharacters(in: .whitespacesAndNewlines).suffix(400)
                }
            }
        }
    }

    private static func get(_ url: String, timeout: TimeInterval) -> [String: Any]? {
        guard let u = URL(string: url) else { return nil }
        var request = URLRequest(url: u, timeoutInterval: timeout)
        request.httpMethod = "GET"
        let done = DispatchSemaphore(value: 0)
        var result: [String: Any]?
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if (response as? HTTPURLResponse)?.statusCode == 200, let data = data {
                result = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            }
            done.signal()
        }.resume()
        done.wait()
        return result
    }
}

struct ProxyClientView: View {
    @ObservedObject private var client = ProxyClient.shared
    @ObservedObject private var runner = ProxyClient.shared.runner
    @State private var installed = ProxyClient.locate() != nil
    @State private var installing = false
    @State private var installLog = ""
    @State private var input = ""

    var body: some View {
        ToolPage(tool: .proxyClient) {
            if installed {
                connectionCard
                serversCard
                importCard
                Card(title: "Log", icon: "text.alignleft") {
                    OutputBox(text: runner.output.isEmpty ? "Not connected." : runner.output, minHeight: 120, maxHeight: 300)
                }
            } else {
                installCard
            }
        }
    }

    private var installCard: some View {
        Card(title: "sing-box isn’t installed", icon: "shippingbox") {
            Text("This client runs sing-box, the free, open-source proxy core that Hiddify is built on. Install it once with Homebrew (which checks the download’s checksum) and this tool will use it.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                if NmapRunner.brew != nil {
                    Button(installing ? "Installing…" : "Install sing-box with Homebrew") { install() }
                        .buttonStyle(.borderedProminent)
                        .disabled(installing)
                    if installing { ProgressView().controlSize(.small) }
                } else {
                    Text("Homebrew isn’t installed either – get it from brew.sh, then run “brew install sing-box”.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("Re-check") { installed = ProxyClient.locate() != nil }
                Spacer()
            }
            if !installLog.isEmpty { OutputBox(text: installLog, minHeight: 80, maxHeight: 220) }
        }
    }

    private func install() {
        guard let brew = NmapRunner.brew else { return }
        installing = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Shell.runSync(brew, ["install", "sing-box"])
            DispatchQueue.main.async {
                installLog = result.combined
                installing = false
                installed = ProxyClient.locate() != nil
            }
        }
    }

    private var connectionCard: some View {
        Card(title: "Connection", icon: "lock.shield") {
            HStack {
                StatusBadge(active: runner.running, activeText: "Connected", idleText: "Disconnected")
                if let i = client.selectedIndex {
                    Text(client.saved.servers[i].name).font(.callout).lineLimit(1)
                }
                Spacer()
                if runner.running {
                    Button("Disconnect") { client.disconnect() }
                } else {
                    Button("Connect") { client.connect() }
                        .buttonStyle(.borderedProminent)
                        .disabled(client.selectedIndex == nil)
                }
            }
            HStack(spacing: 16) {
                IntField(title: "Local port", value: $client.saved.port)
                Toggle("Set as macOS system proxy", isOn: $client.saved.systemProxy)
                Spacer()
            }
            .disabled(runner.running)
            Text("Apps reach the server through the HTTP and SOCKS5 proxy at 127.0.0.1:\(String(client.saved.port)). With the system proxy on, Safari, Chrome and most apps use it automatically; it’s turned off again when you disconnect or quit MacTools. Apps that ignore proxy settings (and most games) are not covered.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var serversCard: some View {
        Card(title: "Servers", icon: "server.rack") {
            if client.saved.servers.isEmpty {
                Text("No servers yet – import a subscription or links below.").font(.caption).foregroundStyle(.secondary)
            } else {
                HStack {
                    Button(client.testing ? "Testing…" : "Test latency") { client.testLatency() }
                        .disabled(client.testing)
                    if client.testing { ProgressView().controlSize(.small) }
                    if !client.saved.subscriptionURL.isEmpty {
                        Button("Update subscription") { client.updateSubscription() }
                    }
                    Spacer()
                    Button("Remove all", role: .destructive) { client.removeAll() }
                }
                VStack(spacing: 2) {
                    ForEach(client.saved.servers) { server in
                        serverRow(server)
                    }
                }
            }
        }
    }

    private func serverRow(_ server: ProxyServer) -> some View {
        let selected = server.id == client.saved.selected
        return Button { client.select(server.id) } label: {
            HStack {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(server.name).lineLimit(1)
                    Text("\(server.type) · \(server.address)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if let ms = client.latency[server.id] {
                    Text(ms < 0 ? "timeout" : "\(ms) ms")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(ms < 0 ? Color.red : ms < 300 ? Color.green : Color.orange)
                }
            }
            .padding(.vertical, 4).padding(.horizontal, 6)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor.opacity(0.1) : .clear))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(server.name), \(server.type)\(selected ? ", selected" : "")")
    }

    private var importCard: some View {
        Card(title: "Import", icon: "square.and.arrow.down") {
            Text("Paste a subscription URL, share links (one per line: vless://, vmess://, trojan://, ss://, hysteria2://, tuic://) or a sing-box JSON config.")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $input)
                .font(.system(.caption, design: .monospaced))
                .frame(minHeight: 70, maxHeight: 140)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            HStack {
                Button("Import") {
                    client.importText(input)
                    input = ""
                }
                .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Paste from clipboard") { input = NSPasteboard.general.string(forType: .string) ?? "" }
                Spacer()
            }
            if !client.message.isEmpty {
                Text(client.message).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
