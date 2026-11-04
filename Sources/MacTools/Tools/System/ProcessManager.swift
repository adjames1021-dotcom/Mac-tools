import SwiftUI
import AppKit
import Darwin

struct ProcessRow: Identifiable {
    let pid: Int32
    let cpu: Double
    let mem: Double
    let name: String
    let path: String
    var id: Int32 { pid }
}

struct ProcessManagerView: View {
    @State private var apps: [NSRunningApplication] = []
    @State private var processes: [ProcessRow] = []
    @State private var tab = 0
    @State private var search = ""
    @State private var sortByMemory = false
    @State private var confirmQuitAll = false
    private let timer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var body: some View {
        ToolPage(tool: .processManager) {
            HStack {
                Picker("", selection: $tab) {
                    Text("Apps").tag(0)
                    Text("All Processes").tag(1)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 240)
                TextField("Filter", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                Spacer()
                if tab == 0 {
                    Button("Hide Others") { NSWorkspace.shared.hideOtherApplications() }
                    Button("Quit All Apps…") { confirmQuitAll = true }
                } else {
                    Toggle("Sort by memory", isOn: $sortByMemory)
                }
                Button {
                    refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }

            if tab == 0 { appList } else { processList }
        }
        .onAppear(perform: refresh)
        .onReceive(timer) { _ in refresh() }
        .onChange(of: sortByMemory) { _ in refresh() }
        .confirmationDialog("Quit all apps?", isPresented: $confirmQuitAll) {
            Button("Quit All Except Finder & MacTools", role: .destructive) { quitAll() }
        } message: {
            Text("Each app will be asked to quit normally, so you can still save your work.")
        }
    }

    private var filteredApps: [NSRunningApplication] {
        apps.filter { search.isEmpty || ($0.localizedName ?? "").localizedCaseInsensitiveContains(search) }
    }

    private var appList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(filteredApps, id: \.processIdentifier) { app in
                HStack(spacing: 10) {
                    if let icon = app.icon {
                        Image(nsImage: icon).resizable().frame(width: 24, height: 24)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(app.localizedName ?? "Unknown").bold()
                        Text("PID \(app.processIdentifier)" + (app.isHidden ? " · hidden" : "") + (app.isActive ? " · active" : ""))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Switch To") { app.activate(options: [.activateAllWindows]) }
                    Button(app.isHidden ? "Unhide" : "Hide") {
                        if app.isHidden { app.unhide() } else { app.hide() }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { refresh() }
                    }
                    Button("Quit") {
                        app.terminate()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { refresh() }
                    }
                    Button("Force Quit") {
                        app.forceTerminate()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { refresh() }
                    }
                    .foregroundColor(.red)
                }
                .padding(.vertical, 4)
                Divider()
            }
        }
    }

    private var processList: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("PID").frame(width: 60, alignment: .leading)
                Text("CPU %").frame(width: 60, alignment: .trailing)
                Text("Mem %").frame(width: 60, alignment: .trailing)
                Text("Name").padding(.leading, 10)
                Spacer()
            }
            .font(.caption.bold())
            .foregroundStyle(.secondary)
            ForEach(processes.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }) { p in
                HStack {
                    Text("\(p.pid)").frame(width: 60, alignment: .leading)
                    Text(String(format: "%.1f", p.cpu)).frame(width: 60, alignment: .trailing)
                    Text(String(format: "%.1f", p.mem)).frame(width: 60, alignment: .trailing)
                    Text(p.name).lineLimit(1).padding(.leading, 10).help(p.path)
                    Spacer()
                    Button("End") { send(SIGTERM, to: p.pid) }
                        .buttonStyle(.borderless)
                    Button("Kill") { send(SIGKILL, to: p.pid) }
                        .buttonStyle(.borderless)
                        .foregroundColor(.red)
                }
                .font(.system(.callout, design: .monospaced))
            }
        }
    }

    private func refresh() {
        apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .sorted { ($0.localizedName ?? "").localizedCaseInsensitiveCompare($1.localizedName ?? "") == .orderedAscending }
        if tab == 1 {
            let byMemory = sortByMemory
            DispatchQueue.global(qos: .userInitiated).async {
                let output = Shell.runSync("/bin/ps", ["-Ao", "pid=,pcpu=,pmem=,comm=", byMemory ? "-m" : "-r"]).output
                var rows: [ProcessRow] = []
                for line in output.split(separator: "\n").prefix(150) {
                    let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
                    guard parts.count == 4, let pid = Int32(parts[0]) else { continue }
                    let path = String(parts[3])
                    rows.append(ProcessRow(pid: pid, cpu: Double(parts[1]) ?? 0, mem: Double(parts[2]) ?? 0,
                                           name: (path as NSString).lastPathComponent, path: path))
                }
                DispatchQueue.main.async { processes = rows }
            }
        }
    }

    private func send(_ signal: Int32, to pid: Int32) {
        if kill(pid, signal) != 0 {
            // Not our process – ask for admin rights.
            Shell.runAsAdmin("kill -\(signal) \(pid)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { refresh() }
    }

    private func quitAll() {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        for app in apps where app.processIdentifier != ownPID && app.bundleIdentifier != "com.apple.finder" {
            app.terminate()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { refresh() }
    }
}
