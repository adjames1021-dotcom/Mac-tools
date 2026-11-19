import SwiftUI
import AppKit
import ServiceManagement

struct SettingsToolView: View {
    @ObservedObject private var permissions = Permissions.shared
    @ObservedObject private var hotkeys = HotKeyCenter.shared
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError = ""
    @State private var confirmReset = false

    var body: some View {
        ToolPage(tool: .settings) {
            Card(title: "Permissions", icon: "lock.shield") {
                Text("macOS asks you to approve these once. MacTools only uses them for the tools you start.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(PermissionKind.allCases) { kind in
                    HStack(spacing: 10) {
                        Image(systemName: permissions.isGranted(kind) ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundColor(permissions.isGranted(kind) ? Color.green : Color.red)
                            .font(.title3)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(kind.title).bold()
                            Text(kind.explanation).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !permissions.isGranted(kind) {
                            Button("Grant…") { permissions.request(kind) }
                        }
                        Button("Open Settings") { permissions.openSettings(kind) }
                    }
                    .padding(.vertical, 2)
                }
                Divider()
                HStack {
                    Button("Re-check") { permissions.refresh() }
                    Button("Reset Permissions…") { confirmReset = true }
                    Text("Use this if a permission shows as on in System Settings but MacTools still can't use it (common after rebuilding).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Card(title: "Global Hotkeys", icon: "keyboard") {
                Text("Click a shortcut and press a new key combination. On most Mac keyboards hold fn to press F-keys. Shortcuts work even when MacTools is in the background.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(HotKeyAction.allCases.filter { $0.windowAction == nil }) { action in
                    hotkeyRow(action)
                }
                DisclosureGroup("Window manager shortcuts") {
                    Toggle("Enable window hotkeys", isOn: $hotkeys.windowHotkeysEnabled)
                    ForEach(HotKeyAction.allCases.filter { $0.windowAction != nil }) { action in
                        hotkeyRow(action)
                    }
                }
                Button("Restore Default Hotkeys") { hotkeys.restoreDefaults() }
            }

            Card(title: "General", icon: "gearshape") {
                Toggle("Show MacTools in the menu bar", isOn: $showMenuBarIcon)
                Toggle("Open MacTools when I log in", isOn: Binding(
                    get: { launchAtLogin },
                    set: { setLaunchAtLogin($0) }))
                if !loginError.isEmpty {
                    Text(loginError).font(.caption).foregroundColor(.red)
                }
                HStack {
                    Button("Open Data Folder") { NSWorkspace.shared.open(DataStore.directory) }
                    Text("Macros, snippets, notes and other saved data live in ~/Library/Application Support/MacTools.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Card(title: "About", icon: "info.circle") {
                let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
                Text("MacTools \(version) (\(UpdateManager.shared.build.shortCommit)) · \(ToolID.allCases.filter { $0.category != .general }.count) tools in one app")
                Text("Built locally from source on this Mac. Closing the window keeps MacTools running in the menu bar; use Quit from the menu bar icon to exit completely.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .confirmationDialog("Reset MacTools permissions?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) { permissions.resetAll() }
        } message: {
            Text("This removes MacTools from the Accessibility, Input Monitoring and Screen Recording lists. You'll be asked to grant them again.")
        }
    }

    private func hotkeyRow(_ action: HotKeyAction) -> some View {
        HStack {
            Text(action.title)
            if hotkeys.failed.contains(action.rawValue) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .help("This shortcut is already used by another app or macOS.")
            }
            Spacer()
            KeyComboRecorder(combo: Binding(
                get: { hotkeys.combo(for: action) },
                set: { hotkeys.set($0, for: action) }), placeholder: "Not set")
            Button {
                hotkeys.set(nil, for: action)
            } label: {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove shortcut")
            .disabled(hotkeys.combo(for: action) == nil)
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginError = ""
        } catch {
            loginError = "Couldn't change login item: \(error.localizedDescription). You can add MacTools in System Settings ▸ General ▸ Login Items."
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

struct CreditsView: View {
    private let people = [
        (name: "lilbean_uwu", role: "Main Developer", icon: "hammer.fill"),
        (name: "frankycat8", role: "Head Bug Tester", icon: "ladybug.fill"),
    ]

    var body: some View {
        ToolPage(tool: .credits) {
            Card(title: "Credits", icon: "person.2") {
                ForEach(people, id: \.name) { person in
                    HStack(spacing: 12) {
                        Image(systemName: person.icon)
                            .font(.title2)
                            .foregroundColor(.accentColor)
                            .frame(width: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(person.name).font(.title3.bold())
                            Text(person.role).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}
