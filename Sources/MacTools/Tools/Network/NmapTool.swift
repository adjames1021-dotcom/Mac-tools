import SwiftUI
import AppKit

// A front-end for Nmap, the standard open-source network scanner (nmap.org), much like its own
// Zenmap GUI: it builds the command from plain-English options, shows the exact command before it
// runs, runs it against the hosts you enter, and documents what every option does. Scanning is for
// networks you own or are authorised to test — the tool shows that reminder and never hides the
// command it will run.

// MARK: - Options model

enum NmapScan: String, CaseIterable, Identifiable {
    case connect, syn, ping, udp, version, fin, xmas, null, ack, list
    var id: String { rawValue }

    /// The nmap flag for this technique.
    var flag: String {
        switch self {
        case .connect: return "-sT"
        case .syn: return "-sS"
        case .ping: return "-sn"
        case .udp: return "-sU"
        case .version: return "-sV"
        case .fin: return "-sF"
        case .xmas: return "-sX"
        case .null: return "-sN"
        case .ack: return "-sA"
        case .list: return "-sL"
        }
    }

    var title: String {
        switch self {
        case .connect: return "TCP Connect scan"
        case .syn: return "SYN “stealth” scan"
        case .ping: return "Ping scan (no ports)"
        case .udp: return "UDP scan"
        case .version: return "Service / version scan"
        case .fin: return "FIN scan"
        case .xmas: return "Xmas scan"
        case .null: return "Null scan"
        case .ack: return "ACK scan"
        case .list: return "List scan (no packets)"
        }
    }

    var explanation: String {
        switch self {
        case .connect: return "Completes a normal connection to each port. Works without special privileges and is the reliable default."
        case .syn: return "Sends a half-open connection to each port – fast and quiet. Needs administrator rights for raw packets."
        case .ping: return "Only checks which hosts are online, without scanning any ports. Good for mapping a network first."
        case .udp: return "Scans UDP services such as DNS, DHCP and SNMP. Slower, and needs administrator rights."
        case .version: return "Connects to open ports and asks each service what it is and which version it runs."
        case .fin: return "Sends a lone FIN packet to slip past simple firewalls. Needs administrator rights."
        case .xmas: return "Sends FIN, PSH and URG flags together to probe how a host reacts. Needs administrator rights."
        case .null: return "Sends a packet with no flags set, another firewall-probing technique. Needs administrator rights."
        case .ack: return "Maps which ports a firewall filters rather than whether they are open. Needs administrator rights."
        case .list: return "Just lists the addresses and names it would scan, sending no packets at all."
        }
    }

    /// True when the technique has to send raw packets, which requires administrator rights.
    var needsRoot: Bool {
        switch self {
        case .connect, .ping, .version, .list: return false
        case .syn, .udp, .fin, .xmas, .null, .ack: return true
        }
    }
}

enum NmapPorts: String, CaseIterable, Identifiable {
    case `default`, fast, all, custom
    var id: String { rawValue }

    var title: String {
        switch self {
        case .default: return "Top 1000 ports (default)"
        case .fast: return "Fast – top 100 ports (-F)"
        case .all: return "All 65,535 ports"
        case .custom: return "Specific ports…"
        }
    }

    /// The flags this choice adds (custom is handled with the text field).
    func flags(custom: String) -> [String] {
        switch self {
        case .default: return []
        case .fast: return ["-F"]
        case .all: return ["-p-"]
        case .custom:
            let spec = custom.trimmed
            return spec.isEmpty ? [] : ["-p", spec]
        }
    }
}

/// Everything the user chose; turned into a command by `NmapCommand`.
struct NmapOptions: Equatable {
    var target = ""
    var scan: NmapScan = .connect
    var ports: NmapPorts = .default
    var customPorts = ""
    var noPing = false
    var serviceVersion = false
    var defaultScripts = false
    var osDetection = false
    var aggressive = false
    var traceroute = false
    var reason = false
    var verbose = true
    var timing = 3
    var extraFlags = ""
}

enum NmapCommand {
    /// Splits the hosts/targets field into tokens (space or comma separated).
    static func targets(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\n" || $0 == "\t" })
            .map { String($0) }
            .filter { !$0.isEmpty }
    }

    /// Splits a free-form flags string into tokens, honouring simple quotes.
    static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        for char in text {
            if let q = quote {
                if char == q { quote = nil } else { current.append(char) }
            } else if char == "\"" || char == "'" {
                quote = char
            } else if char == " " || char == "\t" || char == "\n" {
                if !current.isEmpty { tokens.append(current); current = "" }
            } else {
                current.append(char)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    /// Builds the argument list (without the nmap path) from the options.
    static func arguments(_ options: NmapOptions) -> [String] {
        var args: [String] = [options.scan.flag]
        // A ping or list scan ignores port and service options.
        let scansPorts = options.scan != .ping && options.scan != .list
        if scansPorts {
            args += options.ports.flags(custom: options.customPorts)
            if options.serviceVersion && options.scan != .version { args.append("-sV") }
            if options.defaultScripts { args.append("-sC") }
            if options.osDetection { args.append("-O") }
            if options.aggressive { args.append("-A") }
        }
        // A list scan sends no packets, so host discovery and traceroute don't apply.
        if options.scan != .list {
            if options.noPing { args.append("-Pn") }
            if options.traceroute { args.append("--traceroute") }
        }
        if options.reason { args.append("--reason") }
        if options.verbose { args.append("-v") }
        args.append("-T\(min(max(options.timing, 0), 5))")
        args += tokenize(options.extraFlags)
        args += targets(options.target)
        return args
    }

    /// Whether the chosen options require administrator rights (raw packets, OS detection, traceroute).
    static func needsRoot(_ options: NmapOptions) -> Bool {
        if options.scan.needsRoot { return true }
        let scansPorts = options.scan != .ping && options.scan != .list
        if scansPorts && (options.osDetection || options.aggressive) { return true }
        if options.traceroute && options.scan != .list { return true }
        return tokenize(options.extraFlags).contains(where: isRawPacketFlag)
    }

    /// Options typed into the extra field that make nmap send raw packets (and so need root).
    static func isRawPacketFlag(_ token: String) -> Bool {
        let exact: Set<String> = ["-O", "-A", "-f", "--mtu", "-D", "-S", "--spoof-mac", "--data-length", "--badsum",
                                  "--traceroute", "--send-eth", "--send-ip", "--ttl", "--ip-options", "-PE", "-PP", "-PM"]
        let name = token.split(separator: "=", maxSplits: 1).first.map(String.init) ?? token
        if exact.contains(name) { return true }
        // -PO / -PY host-discovery probes (with or without a protocol or port list).
        if token.hasPrefix("-PO") || token.hasPrefix("-PY") { return true }
        // Scan types, alone or combined (-sS, -sU, -sSU…). -sT, -sV, -sC, -sn and -sL don't need root.
        if token.hasPrefix("-s"), token.count > 2 {
            let letters = token.dropFirst(2)
            if letters.allSatisfy({ $0.isLetter }) && letters.contains(where: { "SUAFNXOMWYZI".contains($0) }) { return true }
        }
        return false
    }

    /// Why the targets can't be scanned as typed, if they can't.
    static func targetProblem(_ options: NmapOptions) -> String? {
        let list = targets(options.target)
        if list.isEmpty { return "Enter at least one target above to run a scan." }
        if let bad = list.first(where: { $0.hasPrefix("-") }) {
            return "“\(bad)” looks like an option, not a target. Put options under Extra options."
        }
        if options.scan != .ping && options.scan != .list && options.ports == .custom && options.customPorts.trimmed.isEmpty {
            return "Enter the ports to scan, or pick another port option."
        }
        return nil
    }

    /// Quotes one token for display or for a shell command line.
    static func quote(_ token: String) -> String {
        if token.isEmpty { return "''" }
        let safe = token.allSatisfy { $0.isLetter || $0.isNumber || "-_./:=,@%+".contains($0) }
        if safe { return token }
        return "'" + token.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The command as the user would type it, for the read-only preview.
    static func display(_ options: NmapOptions) -> String {
        (["nmap"] + arguments(options).map(quote)).joined(separator: " ")
    }

    /// A single shell command line (used when a scan needs administrator rights).
    /// `do shell script` only returns output when it finishes and keeps running if osascript is killed,
    /// so the root shell appends to `log` (tailed by the app) and stops nmap when `stopFile` appears.
    static func shellLine(nmapPath: String, options: NmapOptions, log: String, stopFile: String) -> String {
        let command = (([nmapPath] + arguments(options)).map(quote)).joined(separator: " ")
        return "\(command) >> \(quote(log)) 2>&1 & p=$!; "
            + "while kill -0 $p 2>/dev/null; do [ -e \(quote(stopFile)) ] && kill -INT $p; sleep 0.3; done; wait $p"
    }
}

// MARK: - Reference (the annotated list of options)

struct NmapRefItem: Identifiable {
    let flag: String
    let detail: String
    var id: String { flag }
}

struct NmapRefSection: Identifiable {
    let title: String
    let items: [NmapRefItem]
    var id: String { title }
}

enum NmapReference {
    static let sections: [NmapRefSection] = [
        NmapRefSection(title: "Targets", items: [
            .init(flag: "nmap 192.168.1.10", detail: "Scan a single host by IP address."),
            .init(flag: "nmap example.com", detail: "Scan a host by name; nmap looks up its address first."),
            .init(flag: "nmap 192.168.1.0/24", detail: "Scan a whole subnet using CIDR notation (here 256 addresses)."),
            .init(flag: "nmap 192.168.1.1-50", detail: "Scan a range of addresses."),
            .init(flag: "-iL hosts.txt", detail: "Read the list of targets from a file, one per line."),
            .init(flag: "--exclude host1,host2", detail: "Leave the named hosts out of the scan."),
        ]),
        NmapRefSection(title: "Finding live hosts", items: [
            .init(flag: "-sn", detail: "Ping scan: find which hosts are up without scanning their ports."),
            .init(flag: "-Pn", detail: "Skip the “is it up?” check and treat every host as online (useful when hosts block pings)."),
            .init(flag: "-PS<ports>", detail: "Check if a host is up by sending a TCP SYN to the given ports."),
            .init(flag: "-PA<ports>", detail: "Check if a host is up by sending a TCP ACK to the given ports."),
            .init(flag: "-PU<ports>", detail: "Check if a host is up with UDP packets."),
            .init(flag: "-PE", detail: "Use a standard ICMP echo (ping) request for host discovery."),
            .init(flag: "-n", detail: "Never do reverse-DNS lookups – makes a scan noticeably faster."),
            .init(flag: "-R", detail: "Always do reverse-DNS lookups, even for hosts that look offline."),
        ]),
        NmapRefSection(title: "Scan techniques", items: [
            .init(flag: "-sT", detail: "TCP connect scan: the reliable default that needs no special privileges."),
            .init(flag: "-sS", detail: "SYN “stealth” scan: fast and quiet, but needs administrator rights."),
            .init(flag: "-sU", detail: "UDP scan for services like DNS and SNMP; slower, needs administrator rights."),
            .init(flag: "-sA", detail: "ACK scan: maps which ports a firewall filters."),
            .init(flag: "-sF / -sN / -sX", detail: "FIN, Null and Xmas scans: unusual flag combinations that can slip past simple firewalls."),
            .init(flag: "-sO", detail: "IP protocol scan: find which IP protocols a host supports."),
            .init(flag: "-sL", detail: "List scan: show what would be scanned without sending any packets."),
            .init(flag: "-b <host>", detail: "FTP bounce scan: route the scan through an FTP server (rarely useful today)."),
        ]),
        NmapRefSection(title: "Choosing ports", items: [
            .init(flag: "-p 80,443", detail: "Scan only the listed ports."),
            .init(flag: "-p 1-1000", detail: "Scan a range of ports."),
            .init(flag: "-p-", detail: "Scan all 65,535 ports."),
            .init(flag: "-F", detail: "Fast scan: only the 100 most common ports."),
            .init(flag: "--top-ports N", detail: "Scan the N most common ports."),
            .init(flag: "-p U:53,T:80", detail: "Mix UDP and TCP ports in one scan."),
        ]),
        NmapRefSection(title: "Identifying services and systems", items: [
            .init(flag: "-sV", detail: "Ask each open port which service and version it runs."),
            .init(flag: "--version-intensity 0-9", detail: "How hard to try when identifying a service (higher is more thorough, slower)."),
            .init(flag: "-O", detail: "Guess the operating system from how the host responds. Needs administrator rights."),
            .init(flag: "-A", detail: "Aggressive: version detection, OS detection, default scripts and traceroute together."),
            .init(flag: "--osscan-guess", detail: "Make nmap guess the OS even when it isn’t certain."),
        ]),
        NmapRefSection(title: "Scripts (NSE)", items: [
            .init(flag: "-sC", detail: "Run the default set of safe scripts to gather extra detail."),
            .init(flag: "--script=<name>", detail: "Run specific scripts, e.g. http-title or ssl-cert."),
            .init(flag: "--script=vuln", detail: "Run the scripts in a category, here checks for known vulnerabilities."),
            .init(flag: "--script-args=...", detail: "Pass settings to the scripts you run."),
            .init(flag: "--script-help=<name>", detail: "Show what a script does without running it."),
        ]),
        NmapRefSection(title: "Speed and timing", items: [
            .init(flag: "-T0 … -T5", detail: "Overall speed, from -T0 (very slow and stealthy) to -T5 (fastest). -T3 is normal, -T4 is a good default on a healthy network."),
            .init(flag: "--min-rate / --max-rate", detail: "Set a floor or ceiling on packets sent per second."),
            .init(flag: "--host-timeout <time>", detail: "Give up on a host that takes longer than this."),
            .init(flag: "--max-retries N", detail: "How many times to resend a probe before moving on."),
        ]),
        NmapRefSection(title: "Firewalls and evasion", items: [
            .init(flag: "-f", detail: "Split packets into tiny fragments to get past some packet filters."),
            .init(flag: "-D decoy1,decoy2", detail: "Mix in decoy source addresses so the real scanner is harder to spot."),
            .init(flag: "-S <address>", detail: "Spoof the source address the scan appears to come from."),
            .init(flag: "--spoof-mac <mac>", detail: "Use a different hardware (MAC) address."),
            .init(flag: "--data-length N", detail: "Add random data to each packet to change its size."),
        ]),
        NmapRefSection(title: "Saving results", items: [
            .init(flag: "-oN file", detail: "Save the normal, human-readable output to a file."),
            .init(flag: "-oX file", detail: "Save results as XML, for other programs to read."),
            .init(flag: "-oG file", detail: "Save “grepable” output that’s easy to search with grep."),
            .init(flag: "-oA name", detail: "Save all three formats at once using the same base name."),
            .init(flag: "--reason", detail: "Show why nmap marked each port the way it did."),
            .init(flag: "-v / -vv", detail: "More detail while the scan runs; add a second v for even more."),
            .init(flag: "--open", detail: "Show only the ports that are open."),
        ]),
    ]
}

// MARK: - Runner

/// Finds nmap, builds the command and runs it, streaming the output.
final class NmapRunner: ObservableObject {
    @Published var output = ""
    @Published private(set) var running = false
    private var process: Process?

    static func locate() -> String? {
        ["/opt/homebrew/bin/nmap", "/usr/local/bin/nmap", "/usr/bin/nmap"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var brew: String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private var stopFile: URL?

    func stop() {
        guard let process = process else { return }
        if let stopFile = stopFile {
            // The scan runs as root, so killing osascript alone would leave nmap running: its shell
            // stops nmap when this file appears. Killing osascript also closes a pending password prompt.
            FileManager.default.createFile(atPath: stopFile.path, contents: nil)
        }
        process.terminate()
        append("\n[stopped]\n")
        stopFile = nil
        self.process = nil
        running = false
    }

    func run(options: NmapOptions) {
        guard let nmap = Self.locate() else {
            output = "nmap isn’t installed. Install it with Homebrew first."
            return
        }
        stop()
        let asAdmin = NmapCommand.needsRoot(options)
        let executable: String
        let args: [String]
        var log: URL?
        if asAdmin {
            // osascript asks for the password and runs the scan with administrator rights.
            let base = FileManager.default.temporaryDirectory.appendingPathComponent("mactools-nmap-\(UUID().uuidString)")
            let logURL = base.appendingPathExtension("log")
            let stopURL = base.appendingPathExtension("stop")
            // Created by us so the app can read what root appends to it.
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            let line = NmapCommand.shellLine(nmapPath: nmap, options: options, log: logURL.path, stopFile: stopURL.path)
            let script = "do shell script \"\(line.appleScriptEscaped)\" with administrator privileges"
            executable = "/usr/bin/osascript"
            args = ["-e", script]
            output = NmapCommand.display(options) + "\n(asks for your administrator password…)\n\n"
            log = logURL
            stopFile = stopURL
        } else {
            executable = nmap
            args = NmapCommand.arguments(options)
            output = NmapCommand.display(options) + "\n\n"
        }
        launch(executable: executable, args: args, log: log)
    }

    private func launch(executable: String, args: [String], log: URL?) {
        // Live output of an admin scan comes from its log file.
        var logHandle = log.flatMap { try? FileHandle(forReadingFrom: $0) }
        let timer = logHandle == nil ? nil : Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            if let data = logHandle?.availableData, !data.isEmpty { self?.append(String(decoding: data, as: UTF8.self)) }
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil; return }
            let text = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async { self?.append(text) }
        }
        process.terminationHandler = { [weak self] p in
            let status = p.terminationStatus
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                handle.readabilityHandler = nil
                timer?.invalidate()
                let rest = logHandle?.readDataToEndOfFile() ?? Data()
                try? logHandle?.close()
                logHandle = nil
                if let log = log {
                    try? FileManager.default.removeItem(at: log)
                    // Kept a moment so the root shell (polling every 0.3 s) still sees a Stop.
                    let stop = log.deletingPathExtension().appendingPathExtension("stop")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { try? FileManager.default.removeItem(at: stop) }
                }
                guard let self = self, self.process === p else { return }
                if !rest.isEmpty { self.append(String(decoding: rest, as: UTF8.self)) }
                if status != 0 { self.append("\n[nmap exited with code \(status)]\n") }
                else { self.append("\n[done]\n") }
                self.running = false
                self.process = nil
                self.stopFile = nil
            }
        }
        do {
            try process.run()
            self.process = process
            running = true
        } catch {
            append("Couldn’t start nmap: \(error.localizedDescription)\n")
        }
    }

    private func append(_ text: String) {
        output += text
        if output.count > 400_000 { output = String(output.suffix(400_000)) }
    }

    func saveOutput() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "nmap-scan.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? output.data(using: .utf8)?.write(to: url)
    }
}

// MARK: - View

struct NmapToolView: View {
    @StateObject private var runner = NmapRunner()
    @State private var options = NmapOptions()
    @State private var installed = NmapRunner.locate() != nil
    @State private var refSearch = ""
    @State private var installing = false

    var body: some View {
        ToolPage(tool: .nmap) {
            authorizationBanner
            if installed {
                targetCard
                optionsCard
                commandCard
            } else {
                installCard
            }
            referenceCard
        }
    }

    // MARK: Banner

    private var authorizationBanner: some View {
        Label("Scan only systems you own or have written permission to test. Unauthorised scanning can be against the rules of a network or the law.",
              systemImage: "checkmark.shield")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }

    // MARK: Install

    private var installCard: some View {
        Card(title: "Nmap isn’t installed", icon: "shippingbox") {
            Text("Nmap is a free, open-source network scanner. Install it once with Homebrew and this tool will use it.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                if NmapRunner.brew != nil {
                    Button(installing ? "Installing…" : "Install nmap with Homebrew") { installNmap() }
                        .buttonStyle(.borderedProminent)
                        .disabled(installing)
                    if installing { ProgressView().controlSize(.small) }
                } else {
                    Text("Homebrew isn’t installed either – get it from brew.sh, then run “brew install nmap”.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("Re-check") { installed = NmapRunner.locate() != nil }
                Spacer()
            }
            if installing {
                OutputBox(text: runner.output, minHeight: 100, maxHeight: 260)
            }
        }
    }

    private func installNmap() {
        guard let brew = NmapRunner.brew else { return }
        installing = true
        runner.output = ""
        // Install in the background and re-check when it finishes.
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Shell.runSync(brew, ["install", "nmap"])
            DispatchQueue.main.async {
                runner.output = result.combined
                installing = false
                installed = NmapRunner.locate() != nil
            }
        }
    }

    // MARK: Target

    private var targetCard: some View {
        Card(title: "What to scan", icon: "target") {
            TextField("Host, name or range — e.g. 192.168.1.1, example.com, 192.168.1.0/24", text: $options.target)
                .textFieldStyle(.roundedBorder)
            Text("Separate several targets with spaces or commas.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Options

    private var optionsCard: some View {
        Card(title: "Scan options", icon: "slider.horizontal.3") {
            Picker("Scan type", selection: $options.scan) {
                ForEach(NmapScan.allCases) { Text($0.title).tag($0) }
            }
            Text(options.scan.explanation).font(.caption).foregroundStyle(.secondary)
            if options.scan.needsRoot {
                Label("Needs your administrator password.", systemImage: "key")
                    .font(.caption).foregroundColor(.orange)
            }

            if options.scan != .ping && options.scan != .list {
                Divider()
                Picker("Ports", selection: $options.ports) {
                    ForEach(NmapPorts.allCases) { Text($0.title).tag($0) }
                }
                if options.ports == .custom {
                    TextField("e.g. 22,80,443 or 1-1024", text: $options.customPorts)
                        .textFieldStyle(.roundedBorder)
                }
                Toggle("Identify service versions (-sV)", isOn: $options.serviceVersion)
                    .disabled(options.scan == .version)
                Toggle("Run default scripts for extra detail (-sC)", isOn: $options.defaultScripts)
                Toggle("Detect operating system (-O, needs password)", isOn: $options.osDetection)
                Toggle("Aggressive: versions, OS, scripts, traceroute (-A, needs password)", isOn: $options.aggressive)
            }

            Divider()
            Toggle("Skip host discovery – scan even if it looks offline (-Pn)", isOn: $options.noPing)
            Toggle("Trace the route to the host (--traceroute, needs password)", isOn: $options.traceroute)
            Toggle("Show the reason for each result (--reason)", isOn: $options.reason)
            Toggle("Show progress while scanning (-v)", isOn: $options.verbose)

            HStack {
                Text("Speed")
                Slider(value: Binding(get: { Double(options.timing) }, set: { options.timing = Int($0.rounded()) }),
                       in: 0...5, step: 1)
                Text("-T\(options.timing)").font(.system(.body, design: .monospaced)).frame(width: 40)
            }
            Text(timingHint).font(.caption).foregroundStyle(.secondary)

            Divider()
            Text("Extra options (anything from the reference below)").font(.caption).foregroundStyle(.secondary)
            TextField("e.g. --script http-title --open", text: $options.extraFlags)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var timingHint: String {
        switch options.timing {
        case 0, 1: return "Very slow and quiet – useful to avoid attention or on fragile networks."
        case 2: return "Polite – lighter on the network."
        case 3: return "Normal speed."
        case 4: return "Fast – a good default on a healthy, modern network."
        default: return "Fastest – only on a reliable local network; can overwhelm slow links."
        }
    }

    // MARK: Command + run

    private var commandCard: some View {
        Card(title: "Command", icon: "terminal") {
            Text(NmapCommand.display(options))
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
            HStack {
                if runner.running {
                    Button("Stop", role: .destructive) { runner.stop() }
                } else {
                    Button {
                        runner.run(options: options)
                    } label: {
                        Label(NmapCommand.needsRoot(options) ? "Run Scan (asks for password)" : "Run Scan",
                              systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(NmapCommand.targetProblem(options) != nil)
                }
                if runner.running { ProgressView().controlSize(.small) }
                Spacer()
                Button("Copy") { copyCommand() }
                Button("Save Output…") { runner.saveOutput() }
                    .disabled(runner.output.isEmpty)
            }
            if let problem = NmapCommand.targetProblem(options) {
                Text(problem).font(.caption).foregroundStyle(.secondary)
            }
            OutputBox(text: runner.output, minHeight: 200, maxHeight: 460)
        }
    }

    private func copyCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(NmapCommand.display(options), forType: .string)
    }

    // MARK: Reference

    private var referenceCard: some View {
        Card(title: "Nmap options explained", icon: "book") {
            TextField("Search options…", text: $refSearch).textFieldStyle(.roundedBorder)
            ForEach(filteredReference) { section in
                VStack(alignment: .leading, spacing: 4) {
                    Text(section.title).font(.subheadline.bold()).foregroundStyle(.secondary)
                    ForEach(section.items) { item in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(item.flag)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.accentColor)
                                .frame(width: 150, alignment: .leading)
                                .textSelection(.enabled)
                            Text(item.detail).font(.caption)
                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            Text("This is a plain-language summary. For every option and exact behaviour, see “man nmap” or nmap.org/book.")
                .font(.caption2).foregroundStyle(.secondary).padding(.top, 4)
        }
    }

    private var filteredReference: [NmapRefSection] {
        let query = refSearch.trimmed.lowercased()
        guard !query.isEmpty else { return NmapReference.sections }
        return NmapReference.sections.compactMap { section in
            if section.title.lowercased().contains(query) { return section }
            let items = section.items.filter {
                $0.flag.lowercased().contains(query) || $0.detail.lowercased().contains(query)
            }
            return items.isEmpty ? nil : NmapRefSection(title: section.title, items: items)
        }
    }
}
