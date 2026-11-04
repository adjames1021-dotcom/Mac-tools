import SwiftUI
import AppKit
import Darwin

enum SystemStats {
    static func sysctlString(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "" }
        return buffer.withUnsafeBufferPointer { ptr -> String in
            guard let base = ptr.baseAddress else { return "" }
            return String(cString: base)
        }
    }

    struct Memory {
        var total: UInt64
        var used: UInt64
        var wired: UInt64
        var compressed: UInt64
        var free: UInt64
    }

    static func memory() -> Memory {
        let total = ProcessInfo.processInfo.physicalMemory
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, reboundPointer, &count)
            }
        }
        guard result == KERN_SUCCESS else { return Memory(total: total, used: 0, wired: 0, compressed: 0, free: 0) }
        let page = UInt64(getpagesize())
        let active = UInt64(stats.active_count) * page
        let wired = UInt64(stats.wire_count) * page
        let compressed = UInt64(stats.compressor_page_count) * page
        let free = UInt64(stats.free_count) * page
        return Memory(total: total, used: active + wired + compressed, wired: wired, compressed: compressed, free: free)
    }

    static func loadAverage() -> [Double] {
        var loads = [Double](repeating: 0, count: 3)
        let n = getloadavg(&loads, 3)
        return n == 3 ? loads : []
    }

    static func uptime() -> String {
        let seconds = Int(ProcessInfo.processInfo.systemUptime)
        let days = seconds / 86400
        let hours = (seconds % 86400) / 3600
        let minutes = (seconds % 3600) / 60
        return days > 0 ? "\(days)d \(hours)h \(minutes)m" : "\(hours)h \(minutes)m"
    }

    static func thermal() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "Normal"
        case .fair: return "Fair"
        case .serious: return "Serious (throttling)"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }
}

struct SystemInfoView: View {
    @State private var memory = SystemStats.memory()
    @State private var load = SystemStats.loadAverage()
    @State private var battery = ""
    @State private var serial = ""
    @State private var gpu = ""
    @State private var disk: (total: Int64, free: Int64) = (0, 0)
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private var rows: [(String, String)] {
        let info = ProcessInfo.processInfo
        let v = info.operatingSystemVersion
        return [
            ("Computer name", Host.current().localizedName ?? ""),
            ("macOS", "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion) (\(SystemStats.sysctlString("kern.osversion")))"),
            ("Model", SystemStats.sysctlString("hw.model")),
            ("Chip / CPU", SystemStats.sysctlString("machdep.cpu.brand_string")),
            ("CPU cores", "\(info.processorCount) (\(info.activeProcessorCount) active)"),
            ("Architecture", SystemStats.sysctlString("hw.machine")),
            ("Graphics", gpu),
            ("Serial number", serial),
            ("User", NSUserName() + " (" + NSFullUserName() + ")"),
            ("Home folder", NSHomeDirectory()),
            ("Uptime", SystemStats.uptime()),
            ("Thermal state", SystemStats.thermal()),
            ("Low Power Mode", info.isLowPowerModeEnabled ? "On" : "Off"),
            ("Battery", battery)
        ]
    }

    var body: some View {
        ToolPage(tool: .systemInfo) {
            HStack(alignment: .top, spacing: 16) {
                gauge(title: "Memory", used: Double(memory.used), total: Double(memory.total),
                      detail: "\(Format.bytes(Int64(memory.used))) of \(Format.bytes(Int64(memory.total)))")
                gauge(title: "Disk", used: Double(disk.total - disk.free), total: Double(max(disk.total, 1)),
                      detail: "\(Format.bytes(disk.free)) free of \(Format.bytes(disk.total))")
                VStack(alignment: .leading, spacing: 6) {
                    Text("Load average").font(.headline)
                    Text(load.map { String(format: "%.2f", $0) }.joined(separator: "  "))
                        .font(.system(.title3, design: .monospaced))
                    Text("1, 5 and 15 minutes · \(ProcessInfo.processInfo.activeProcessorCount) cores")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.045)))
            }

            Card(title: "Overview", icon: "desktopcomputer") {
                ForEach(rows, id: \.0) { row in
                    InfoRow(label: row.0, value: row.1)
                }
            }

            Card(title: "Memory Details", icon: "memorychip") {
                InfoRow(label: "Wired", value: Format.bytes(Int64(memory.wired)))
                InfoRow(label: "Compressed", value: Format.bytes(Int64(memory.compressed)))
                InfoRow(label: "Free", value: Format.bytes(Int64(memory.free)))
            }

            HStack {
                Button("Open System Information") { Shell.run("open -a 'System Information'") }
                Button("Open Activity Monitor") { Shell.run("open -a 'Activity Monitor'") }
                Button("Copy All") {
                    ClipboardHelper.copy(rows.map { "\($0.0): \($0.1)" }.joined(separator: "\n"))
                }
            }
        }
        .onAppear(perform: loadSlow)
        .onReceive(timer) { _ in
            memory = SystemStats.memory()
            load = SystemStats.loadAverage()
        }
    }

    private func gauge(title: String, used: Double, total: Double, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            ProgressView(value: min(used, total), total: max(total, 1))
            Text(String(format: "%.0f%%", total > 0 ? used / total * 100 : 0)).font(.title3.bold())
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.045)))
    }

    private func loadSlow() {
        if let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]) {
            disk = (Int64(values.volumeTotalCapacity ?? 0), values.volumeAvailableCapacityForImportantUsage ?? 0)
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let batt = Shell.sh("pmset -g batt | tail -n +2 | sed 's/^[[:space:]]*-InternalBattery-[0-9]*[[:space:]]*//; s/(id=[0-9]*)//'").output.trimmed
            let serialNumber = Shell.sh("ioreg -c IOPlatformExpertDevice -d 2 | awk -F\\\" '/IOPlatformSerialNumber/{print $(NF-1)}'").output.trimmed
            let gpuName = Shell.sh("system_profiler SPDisplaysDataType 2>/dev/null | awk -F': ' '/Chipset Model/{print $2}' | paste -sd ',' -").output.trimmed
            DispatchQueue.main.async {
                battery = batt.isEmpty ? "No battery" : batt
                serial = serialNumber
                gpu = gpuName
            }
        }
    }
}
