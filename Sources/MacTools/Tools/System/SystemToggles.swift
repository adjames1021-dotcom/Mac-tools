import SwiftUI
import AppKit

struct SystemToggle: Identifiable {
    let id: String
    let title: String
    let detail: String
    let icon: String
    let read: String
    let isOn: (String) -> Bool
    let on: String
    let off: String
}

private func truthy(_ s: String) -> Bool {
    ["1", "true", "yes"].contains(s.trimmed.lowercased())
}

private func falsy(_ s: String) -> Bool {
    ["0", "false", "no"].contains(s.trimmed.lowercased())
}

private let wifiDevice = "dev=$(networksetup -listallhardwareports | awk '/Wi-Fi|AirPort/{getline; print $2; exit}'); "

let systemToggles: [SystemToggle] = [
    SystemToggle(id: "darkMode", title: "Dark Mode", detail: "Switch the whole system between light and dark.", icon: "moon.fill",
                 read: "defaults read -g AppleInterfaceStyle 2>/dev/null", isOn: { $0.trimmed == "Dark" },
                 on: "osascript -e 'tell application \"System Events\" to tell appearance preferences to set dark mode to true'",
                 off: "osascript -e 'tell application \"System Events\" to tell appearance preferences to set dark mode to false'"),
    SystemToggle(id: "hiddenFiles", title: "Show Hidden Files", detail: "Show dot-files in Finder (⇧⌘. also toggles).", icon: "eye",
                 read: "defaults read com.apple.finder AppleShowAllFiles 2>/dev/null", isOn: truthy,
                 on: "defaults write com.apple.finder AppleShowAllFiles -bool true && killall Finder",
                 off: "defaults write com.apple.finder AppleShowAllFiles -bool false && killall Finder"),
    SystemToggle(id: "extensions", title: "Show All File Extensions", detail: "Always show .jpg, .pdf, etc. in Finder.", icon: "doc.text",
                 read: "defaults read NSGlobalDomain AppleShowAllExtensions 2>/dev/null", isOn: truthy,
                 on: "defaults write NSGlobalDomain AppleShowAllExtensions -bool true && killall Finder",
                 off: "defaults write NSGlobalDomain AppleShowAllExtensions -bool false && killall Finder"),
    SystemToggle(id: "desktopIcons", title: "Desktop Icons", detail: "Hide everything on the desktop for a clean screen.", icon: "menubar.dock.rectangle",
                 read: "defaults read com.apple.finder CreateDesktop 2>/dev/null", isOn: { !falsy($0) },
                 on: "defaults write com.apple.finder CreateDesktop -bool true && killall Finder",
                 off: "defaults write com.apple.finder CreateDesktop -bool false && killall Finder"),
    SystemToggle(id: "pathBar", title: "Finder Path Bar", detail: "Show the folder path at the bottom of Finder windows.", icon: "folder",
                 read: "defaults read com.apple.finder ShowPathbar 2>/dev/null", isOn: truthy,
                 on: "defaults write com.apple.finder ShowPathbar -bool true && killall Finder",
                 off: "defaults write com.apple.finder ShowPathbar -bool false && killall Finder"),
    SystemToggle(id: "statusBar", title: "Finder Status Bar", detail: "Show item count and free space in Finder.", icon: "info.square",
                 read: "defaults read com.apple.finder ShowStatusBar 2>/dev/null", isOn: truthy,
                 on: "defaults write com.apple.finder ShowStatusBar -bool true && killall Finder",
                 off: "defaults write com.apple.finder ShowStatusBar -bool false && killall Finder"),
    SystemToggle(id: "dockAutohide", title: "Auto-hide the Dock", detail: "Dock slides away until you move the mouse there.", icon: "dock.rectangle",
                 read: "defaults read com.apple.dock autohide 2>/dev/null", isOn: truthy,
                 on: "defaults write com.apple.dock autohide -bool true && killall Dock",
                 off: "defaults write com.apple.dock autohide -bool false && killall Dock"),
    SystemToggle(id: "dockInstant", title: "Instant Dock Reveal", detail: "Remove the delay before a hidden Dock appears.", icon: "bolt",
                 read: "defaults read com.apple.dock autohide-delay 2>/dev/null", isOn: { $0.trimmed == "0" },
                 on: "defaults write com.apple.dock autohide-delay -float 0 && defaults write com.apple.dock autohide-time-modifier -float 0.25 && killall Dock",
                 off: "defaults delete com.apple.dock autohide-delay; defaults delete com.apple.dock autohide-time-modifier; killall Dock"),
    SystemToggle(id: "dockRecents", title: "Recent Apps in Dock", detail: "Show recently used apps in the Dock.", icon: "clock.arrow.circlepath",
                 read: "defaults read com.apple.dock show-recents 2>/dev/null", isOn: { !falsy($0) },
                 on: "defaults write com.apple.dock show-recents -bool true && killall Dock",
                 off: "defaults write com.apple.dock show-recents -bool false && killall Dock"),
    SystemToggle(id: "screenshotShadow", title: "Shadows in Window Screenshots", detail: "Include the drop shadow when capturing windows.", icon: "shadow",
                 read: "defaults read com.apple.screencapture disable-shadow 2>/dev/null", isOn: { !truthy($0) },
                 on: "defaults delete com.apple.screencapture disable-shadow; killall SystemUIServer",
                 off: "defaults write com.apple.screencapture disable-shadow -bool true && killall SystemUIServer"),
    SystemToggle(id: "keyRepeat", title: "Key Repeat (no accent popup)", detail: "Holding a key repeats it instead of showing accents. Restart apps to apply.", icon: "repeat",
                 read: "defaults read -g ApplePressAndHoldEnabled 2>/dev/null", isOn: falsy,
                 on: "defaults write -g ApplePressAndHoldEnabled -bool false",
                 off: "defaults write -g ApplePressAndHoldEnabled -bool true"),
    SystemToggle(id: "dsStore", title: "No .DS_Store on Network Drives", detail: "Stop Finder littering shared folders.", icon: "network.badge.shield.half.filled",
                 read: "defaults read com.apple.desktopservices DSDontWriteNetworkStores 2>/dev/null", isOn: truthy,
                 on: "defaults write com.apple.desktopservices DSDontWriteNetworkStores -bool true",
                 off: "defaults write com.apple.desktopservices DSDontWriteNetworkStores -bool false"),
    SystemToggle(id: "wifi", title: "Wi-Fi", detail: "Turn Wi-Fi on or off.", icon: "wifi",
                 read: wifiDevice + "networksetup -getairportpower \"$dev\"", isOn: { $0.contains(": On") },
                 on: wifiDevice + "networksetup -setairportpower \"$dev\" on",
                 off: wifiDevice + "networksetup -setairportpower \"$dev\" off"),
    SystemToggle(id: "mute", title: "Mute Sound", detail: "Mute or unmute the speakers.", icon: "speaker.slash",
                 read: "osascript -e 'output muted of (get volume settings)'", isOn: { $0.trimmed == "true" },
                 on: "osascript -e 'set volume output muted true'",
                 off: "osascript -e 'set volume output muted false'")
]

struct QuickAction: Identifiable {
    let id: String
    let title: String
    let icon: String
    let destructive: Bool
    let run: () -> Void
}

struct SystemTogglesView: View {
    @State private var states: [String: Bool] = [:]
    @State private var busy: Set<String> = []
    @State private var volume: Double = 50
    @State private var pending: QuickAction?
    @State private var lastMessage = ""

    private var actions: [QuickAction] {
        [
            QuickAction(id: "lock", title: "Lock Screen", icon: "lock", destructive: false) { ActionRunner.lockScreen() },
            QuickAction(id: "displaySleep", title: "Sleep Display", icon: "display", destructive: false) { Shell.run("pmset displaysleepnow") },
            QuickAction(id: "sleep", title: "Sleep Mac", icon: "moon.zzz", destructive: false) { Shell.run("pmset sleepnow") },
            QuickAction(id: "finder", title: "Restart Finder", icon: "face.smiling", destructive: false) { Shell.run("killall Finder") },
            QuickAction(id: "dock", title: "Restart Dock", icon: "dock.rectangle", destructive: false) { Shell.run("killall Dock") },
            QuickAction(id: "menubar", title: "Restart Menu Bar", icon: "menubar.rectangle", destructive: false) { Shell.run("killall SystemUIServer") },
            QuickAction(id: "trash", title: "Empty Trash", icon: "trash", destructive: true) {
                Shell.appleScript("tell application \"Finder\" to empty trash")
            },
            QuickAction(id: "eject", title: "Eject All Disks", icon: "eject", destructive: false) {
                Shell.appleScript("tell application \"Finder\" to eject (every disk whose ejectable is true)")
            },
            QuickAction(id: "dns", title: "Flush DNS Cache", icon: "network", destructive: false) {
                Shell.runAsAdmin("dscacheutil -flushcache; killall -HUP mDNSResponder")
            },
            QuickAction(id: "purge", title: "Free Up Memory", icon: "memorychip", destructive: false) {
                Shell.runAsAdmin("purge")
            },
            QuickAction(id: "spotlight", title: "Rebuild Spotlight Index", icon: "magnifyingglass", destructive: true) {
                Shell.runAsAdmin("mdutil -E /")
            },
            QuickAction(id: "quicklook", title: "Reset Quick Look", icon: "eye", destructive: false) {
                Shell.run("qlmanage -r && qlmanage -r cache")
            },
            QuickAction(id: "logout", title: "Log Out", icon: "rectangle.portrait.and.arrow.right", destructive: true) {
                Shell.appleScript("tell application \"System Events\" to log out")
            },
            QuickAction(id: "restart", title: "Restart", icon: "restart", destructive: true) {
                Shell.appleScript("tell application \"System Events\" to restart")
            },
            QuickAction(id: "shutdown", title: "Shut Down", icon: "power", destructive: true) {
                Shell.appleScript("tell application \"System Events\" to shut down")
            }
        ]
    }

    var body: some View {
        ToolPage(tool: .systemToggles) {
            Card(title: "Volume", icon: "speaker.wave.2") {
                HStack {
                    Image(systemName: "speaker.fill")
                    Slider(value: $volume, in: 0...100, step: 1, onEditingChanged: { editing in
                        if !editing { Shell.run("osascript -e 'set volume output volume \(Int(volume))'") }
                    })
                    Image(systemName: "speaker.wave.3.fill")
                    Text("\(Int(volume))%").monospacedDigit().frame(width: 44)
                }
            }

            Card(title: "Toggles", icon: "switch.2") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                    ForEach(systemToggles) { toggle in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: toggle.icon)
                                .frame(width: 22)
                                .foregroundColor(.accentColor)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(toggle.title).bold()
                                Text(toggle.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if busy.contains(toggle.id) {
                                ProgressView().controlSize(.small)
                            } else {
                                Toggle("", isOn: Binding(
                                    get: { states[toggle.id] ?? false },
                                    set: { set(toggle, $0) }))
                                    .toggleStyle(.switch)
                                    .labelsHidden()
                            }
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
                    }
                }
                Text("Some toggles restart Finder or the Dock to apply. Dark Mode and Mute may ask to let MacTools control System Events.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Card(title: "Quick Actions", icon: "bolt") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                    ForEach(actions) { action in
                        Button {
                            if action.destructive { pending = action } else { action.run(); lastMessage = "\(action.title) ✓" }
                        } label: {
                            VStack(spacing: 6) {
                                Image(systemName: action.icon)
                                    .font(.title2)
                                    .foregroundColor(action.destructive ? Color.red : Color.accentColor)
                                Text(action.title)
                                    .font(.caption)
                                    .multilineTextAlignment(.center)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, minHeight: 58)
                        }
                        .buttonStyle(TileButtonStyle())
                    }
                }
                if !lastMessage.isEmpty {
                    Text(lastMessage).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear(perform: refreshAll)
        .confirmationDialog(pending?.title ?? "", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            Button(pending?.title ?? "Continue", role: .destructive) {
                pending?.run()
                lastMessage = "\(pending?.title ?? "") ✓"
                pending = nil
            }
        } message: {
            Text("Are you sure?")
        }
    }

    private func refreshAll() {
        DispatchQueue.global(qos: .userInitiated).async {
            var result: [String: Bool] = [:]
            for toggle in systemToggles {
                result[toggle.id] = toggle.isOn(Shell.sh(toggle.read).output)
            }
            let vol = Double(Shell.sh("osascript -e 'output volume of (get volume settings)'").output.trimmed) ?? 50
            let finalResult = result
            DispatchQueue.main.async {
                states = finalResult
                volume = vol
            }
        }
    }

    private func set(_ toggle: SystemToggle, _ value: Bool) {
        busy.insert(toggle.id)
        states[toggle.id] = value
        Shell.run(value ? toggle.on : toggle.off) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                Shell.run(toggle.read) { result in
                    states[toggle.id] = toggle.isOn(result.output)
                    busy.remove(toggle.id)
                }
            }
        }
    }
}
