import SwiftUI
import AppKit

enum NetworkCommand: String, CaseIterable, Identifiable {
    case ping, traceroute, dns, port, whois, headers, speed, interfaces, connections, routes, arp, wifiScan

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ping: return "Ping"
        case .traceroute: return "Traceroute"
        case .dns: return "DNS Lookup"
        case .port: return "Port Check"
        case .whois: return "Whois"
        case .headers: return "HTTP Headers"
        case .speed: return "Speed Test"
        case .interfaces: return "Interfaces"
        case .connections: return "Open Connections"
        case .routes: return "Routing Table"
        case .arp: return "Devices on LAN (ARP)"
        case .wifiScan: return "Wi-Fi Info"
        }
    }

    var needsHost: Bool {
        switch self {
        case .ping, .traceroute, .dns, .port, .whois, .headers: return true
        default: return false
        }
    }

    func command(host: String, port: Int, count: Int) -> String {
        let h = host.trimmed.shellQuoted
        switch self {
        case .ping: return "ping -c \(max(1, count)) \(h)"
        case .traceroute: return "traceroute -m 20 -w 2 \(h)"
        case .dns: return "echo '— A / AAAA —'; host \(h); echo; echo '— MX —'; host -t MX \(h); echo; echo '— TXT —'; host -t TXT \(h)"
        case .port: return "nc -vz -G 3 \(h) \(port) 2>&1"
        case .whois: return "whois \(h) | head -120"
        case .headers:
            let url = host.contains("://") ? host.trimmed : "https://" + host.trimmed
            return "curl -sSIL --max-time 15 \(url.shellQuoted)"
        case .speed: return "networkQuality -v"
        case .interfaces: return "ifconfig | grep -E '^[a-z]|inet '"
        case .connections: return "lsof -i -n -P | head -150"
        case .routes: return "netstat -rn | head -80"
        case .arp: return "arp -a"
        case .wifiScan:
            return "dev=$(networksetup -listallhardwareports | awk '/Wi-Fi|AirPort/{getline; print $2; exit}'); networksetup -getairportnetwork \"$dev\"; echo; system_profiler SPAirPortDataType 2>/dev/null | sed -n '1,60p'"
        }
    }
}

struct NetworkToolsView: View {
    @StateObject private var runner = CommandRunner()
    @State private var command: NetworkCommand = .ping
    @AppStorage("networkHost") private var host = "apple.com"
    @State private var port = 443
    @State private var count = 5
    @State private var localIPs: [(String, String)] = []
    @State private var publicIP = "…"
    @State private var hostName = ""
    @State private var dnsServers = ""

    var body: some View {
        ToolPage(tool: .networkTools) {
            Card(title: "My Connection", icon: "wifi") {
                InfoRow(label: "Public IP", value: publicIP)
                ForEach(localIPs, id: \.0) { ip in
                    InfoRow(label: "Local IP (\(ip.0))", value: ip.1)
                }
                InfoRow(label: "Hostname", value: hostName)
                InfoRow(label: "DNS servers", value: dnsServers)
                Button("Refresh") { loadInfo() }
            }

            Card(title: "Diagnostics", icon: "stethoscope") {
                Picker("Tool", selection: $command) {
                    ForEach(NetworkCommand.allCases) { Text($0.title).tag($0) }
                }
                .frame(maxWidth: 320)
                HStack {
                    if command.needsHost {
                        TextField("Host or domain, e.g. google.com", text: $host)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(run)
                    }
                    if command == .port {
                        IntField(title: "Port", value: $port, width: 70)
                    }
                    if command == .ping {
                        Stepper("\(count) pings", value: $count, in: 1...100)
                    }
                    Button {
                        run()
                    } label: {
                        Label("Run", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(command.needsHost && host.trimmed.isEmpty)
                    Button("Stop") { runner.stop() }
                        .disabled(!runner.running)
                }
                if command == .speed {
                    Text("Uses Apple's built-in networkQuality test (takes about 20 seconds).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    StatusBadge(active: runner.running, activeText: "Running…", idleText: "Idle")
                    Spacer()
                    CopyButton(text: runner.output)
                }
                OutputBox(text: runner.output, minHeight: 220, maxHeight: 480)
            }
        }
        .onAppear(perform: loadInfo)
    }

    private func run() {
        runner.runShell(command.command(host: host, port: port, count: count))
    }

    private func loadInfo() {
        publicIP = "…"
        DispatchQueue.global(qos: .userInitiated).async {
            var ips: [(String, String)] = []
            let list = Shell.sh("networksetup -listallhardwareports | awk '/Hardware Port/{sub(/Hardware Port: /,\"\"); port=$0} /Device/{print port\"|\"$2}'").output
            for line in list.split(separator: "\n") {
                let parts = line.split(separator: "|")
                guard parts.count == 2 else { continue }
                let ip = Shell.runSync("/usr/sbin/ipconfig", ["getifaddr", String(parts[1])]).output.trimmed
                if !ip.isEmpty { ips.append(("\(parts[0]), \(parts[1])", ip)) }
            }
            let name = Shell.sh("scutil --get LocalHostName 2>/dev/null").output.trimmed
            let dns = Shell.sh("scutil --dns | awk '/nameserver/{print $3}' | sort -u | paste -sd ',' -").output.trimmed
            let finalIPs = ips
            DispatchQueue.main.async {
                localIPs = finalIPs
                hostName = name.isEmpty ? (Host.current().localizedName ?? "") : name + ".local"
                dnsServers = dns
            }
        }
        if let url = URL(string: "https://api.ipify.org") {
            URLSession.shared.dataTask(with: url) { data, _, error in
                let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? (error?.localizedDescription ?? "Unavailable")
                DispatchQueue.main.async { publicIP = text.trimmed }
            }.resume()
        }
    }
}
