#if !LITE
import SwiftUI
import AppKit

/// Keeps MacTools Lite sticks current: when a drive with MacToolsLite.app on it is plugged in, it builds Lite
/// from this app's source folder and, if the stick's copy differs, re-lays the stick out with Scripts/make-usb.sh.
/// The stick's "MacToolsLite Data" and "Reports" folders and everything else on it are left alone.
final class LiteUSBUpdater: ObservableObject {
    static let shared = LiteUSBUpdater()

    @Published var enabled: Bool { didSet { UserDefaults.standard.set(enabled, forKey: "liteUSBAutoUpdate") } }
    @Published private(set) var sticks: [URL] = []
    @Published private(set) var busy = false
    @Published private(set) var status = ""

    private var observers: [NSObjectProtocol] = []

    private init() {
        enabled = UserDefaults.standard.object(forKey: "liteUSBAutoUpdate") as? Bool ?? true
    }

    /// The folder that has build.sh, Lite/ and Scripts/make-usb.sh (the source this MacTools was built from).
    var sourceDir: URL? {
        let dir = UpdateManager.shared.build.sourceDir
        guard !dir.isEmpty, FileManager.default.fileExists(atPath: dir + "/Scripts/make-usb.sh") else { return nil }
        return URL(fileURLWithPath: dir)
    }

    static func isLiteStick(_ volume: URL) -> Bool {
        FileManager.default.fileExists(atPath: volume.appendingPathComponent("MacToolsLite.app/Contents/Info.plist").path)
    }

    /// Files make-usb.sh puts on the stick, as (file in the source folder, file on the stick).
    static func managedFiles(source: URL, stick: URL) -> [(URL, URL)] {
        [("build.noindex/MacToolsLite.app/Contents/MacOS/MacToolsLite", "MacToolsLite.app/Contents/MacOS/MacToolsLite"),
         ("build.noindex/MacToolsLite.app/Contents/Resources/mac-report.sh", "MacToolsLite.app/Contents/Resources/mac-report.sh"),
         ("Lite/Tools/mac-report.sh", "Tools/mac-report.sh"),
         ("Lite/Tools/WinTools.ps1", "Tools/WinTools.ps1"),
         ("Lite/Windows Tools.bat", "Windows Tools.bat"),
         ("Lite/README.txt", "README.txt")]
            .map { (source.appendingPathComponent($0.0), stick.appendingPathComponent($0.1)) }
    }

    static func isUpToDate(source: URL, stick: URL) -> Bool {
        managedFiles(source: source, stick: stick).allSatisfy { FileManager.default.contentsEqual(atPath: $0.0.path, andPath: $0.1.path) }
    }

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] note in
            self?.refresh()
            guard let self, self.enabled, let volume = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL,
                  Self.isLiteStick(volume) else { return }
            self.update(volume, automatic: true)
        })
        observers.append(center.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        })
        refresh()
        // A stick that was already plugged in when MacTools started.
        if enabled, let stick = sticks.first {
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in self?.update(stick, automatic: true) }
        }
    }

    func refresh() {
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []
        sticks = volumes.filter { $0.path.hasPrefix("/Volumes/") && Self.isLiteStick($0) }
    }

    func update(_ stick: URL, automatic: Bool = false) {
        guard !busy else { return }
        guard let source = sourceDir else {
            status = "Can't update \(stick.lastPathComponent): this MacTools's source folder has no Scripts/make-usb.sh. Update MacTools first."
            return
        }
        let name = stick.lastPathComponent
        busy = true
        status = "Checking \(name)… (building MacTools Lite can take a few minutes the first time)"
        DispatchQueue.global(qos: .utility).async {
            let message: String
            let build = Shell.runSync("/bin/bash", ["build.sh", "--lite"], directory: source)
            if !build.succeeded {
                message = "Couldn't build MacTools Lite for \(name): " + String(build.combined.suffix(300))
            } else if Self.isUpToDate(source: source, stick: stick) {
                message = "\(name) already has the latest MacTools Lite."
            } else {
                let copy = Shell.runSync("/bin/bash", ["Scripts/make-usb.sh", stick.path], directory: source)
                message = copy.succeeded ? "Updated MacTools Lite on \(name)."
                                         : "Couldn't update \(name): " + String(copy.combined.suffix(300))
            }
            DispatchQueue.main.async {
                self.busy = false
                self.status = message
                // Stay quiet when nothing changed on an automatic check.
                if !automatic || !message.contains("already has") { Shell.notify(message) }
            }
        }
    }
}

struct LiteUSBCard: View {
    @ObservedObject private var usb = LiteUSBUpdater.shared

    var body: some View {
        Card(title: "MacTools Lite USB Sticks", icon: "externaldrive.badge.checkmark") {
            Toggle("Update MacTools Lite on a USB stick automatically when it's plugged in", isOn: $usb.enabled)
            if usb.sticks.isEmpty {
                Text("No MacTools Lite stick is plugged in.").foregroundStyle(.secondary)
            }
            ForEach(usb.sticks, id: \.self) { stick in
                HStack {
                    Image(systemName: "externaldrive")
                    Text(stick.lastPathComponent).bold()
                    Spacer()
                    Button("Update Now") { usb.update(stick) }.disabled(usb.busy)
                }
            }
            HStack {
                if usb.busy { ProgressView().controlSize(.small) }
                if !usb.status.isEmpty { Text(usb.status).font(.caption).foregroundStyle(.secondary) }
            }
            Text("Builds MacTools Lite from this MacTools's source and replaces the app, the Mac and Windows report scripts and the README on the stick. Lite's settings, reports and your other files on the stick are kept.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { usb.refresh() }
    }
}
#endif
