import SwiftUI
import AppKit

@main
struct MacToolsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState.shared
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true

    #if LITE
    init() { Portable.loadDefaults() }

    // Lite: one window, no menu bar icon or automation menu, nothing left running on someone else's Mac.
    var body: some Scene {
        WindowGroup("MacTools Lite", id: "main") {
            ContentView()
                .environmentObject(appState)
                .themedRoot()
                .background(WindowChromeFix())
                .frame(minWidth: 1080, minHeight: 680)
        }
        .commands { CommandGroup(replacing: .newItem) { } }
    }
    #else
    var body: some Scene {
        WindowGroup("MacTools", id: "main") {
            ContentView()
                .environmentObject(appState)
                .themedRoot()
                .background(WindowChromeFix())
                .frame(minWidth: 1080, minHeight: 680)
        }
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandMenu("Automation") {
                Button("Stop All Automation") { Automation.stopAll() }
                    .keyboardShortcut(".", modifiers: [.command])
                Divider()
                Button("Toggle Auto Clicker") { AutoClicker.shared.toggle() }
                Button("Toggle Auto Typer") { AutoTyper.shared.toggle() }
                Button("Toggle Key Presser") { KeyPresser.shared.toggle() }
                Button("Toggle Macro Recording") { MacroEngine.shared.toggleRecording() }
                Button("Toggle Macro Playback") { MacroEngine.shared.togglePlayback() }
            }
        }

        MenuBarExtra(isInserted: $showMenuBarIcon) {
            MenuBarContent()
                .environmentObject(appState)
        } label: {
            MenuBarLabel()
        }
    }
    #endif
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        #if LITE
        ThemeManager.shared.start()  // Lite starts no background services, for a fast launch
        #else
        _ = Permissions.shared
        HotKeyCenter.shared.registerAll()
        ClipboardManager.shared.start()
        TextExpander.shared.startIfEnabled()
        TaskScheduler.shared.start()
        WindowManager.shared.startTracking()
        UpdateManager.shared.start()
        LiteUSBUpdater.shared.start()
        ThemeManager.shared.start()
        SchoolPlanner.shared.start()
        #endif
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        #if LITE
        true
        #else
        // Keep running in the menu bar so hotkeys, clipboard history and schedules keep working.
        false
        #endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        Automation.stopAll()
        KeyboardLock.shared.unlock()
        #if LITE
        Portable.saveDefaults()
        #else
        ProxyClient.shared.disconnect()  // sing-box turns the system proxy back off as it exits
        #endif
    }
}

/// Global UI state (currently selected tool).
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var selection: ToolID? {
        didSet {
            if let s = selection {
                UserDefaults.standard.set(s.rawValue, forKey: "selectedTool")
                NewToolTags.shared.markSeen(s)
            }
        }
    }

    private init() {
        let raw = UserDefaults.standard.string(forKey: "selectedTool") ?? ""
        selection = ToolID(rawValue: raw).flatMap { ToolID.visible.contains($0) ? $0 : nil } ?? .home
        // The tool reopened at launch counts as opened. Done right after launch, not while the window is being built.
        if let s = selection { DispatchQueue.main.async { NewToolTags.shared.markSeen(s) } }
    }

    /// Brings the main window to the front (opening one if needed).
    static func showMainWindow(openWindow: (() -> Void)? = nil) {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.canBecomeMain && ($0.isVisible || $0.isMiniaturized) }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow?()
        }
    }
}

/// Central helpers that touch several automation engines at once.
enum Automation {
    static func stopAll() {
        AutoClicker.shared.stop()
        AutoTyper.shared.stop()
        KeyPresser.shared.stop()
        MacroEngine.shared.stopEverything()
        KeepAwake.shared.stopJiggle()
    }
}

struct MenuBarContent: View {
    @ObservedObject private var clicker = AutoClicker.shared
    @ObservedObject private var typer = AutoTyper.shared
    @ObservedObject private var presser = KeyPresser.shared
    @ObservedObject private var macro = MacroEngine.shared
    @ObservedObject private var awake = KeepAwake.shared
    @ObservedObject private var lock = KeyboardLock.shared
    @EnvironmentObject private var appState: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open MacTools") { show(nil) }
        Button("Check for Updates…") {
            show(.updates)
            UpdateManager.shared.check()
        }
        Divider()
        Group {
            Button(clicker.running ? "Stop Auto Clicker" : "Start Auto Clicker") { clicker.toggle() }
            Button(typer.running ? "Stop Auto Typer" : "Start Auto Typer") { typer.toggle() }
            Button(presser.running ? "Stop Key Presser" : "Start Key Presser") { presser.toggle() }
            Button(macro.state == .recording ? "Stop Recording Macro" : "Record Macro") { macro.toggleRecording() }
            Button(macro.state == .playing ? "Stop Macro Playback" : "Play Macro") { macro.togglePlayback() }
        }
        Divider()
        Group {
            Button(awake.isActive ? "Allow Mac to Sleep" : "Keep Mac Awake") { awake.toggle() }
            Button(awake.jiggling ? "Stop Mouse Jiggler" : "Start Mouse Jiggler") { awake.toggleJiggle() }
            if lock.locked {
                Button("Unlock Keyboard") { lock.unlock() }
            }
            Button("Stop All Automation") { Automation.stopAll() }
        }
        Divider()
        Menu("Tools") {
            ForEach(ToolID.allCases.filter { $0 != .home }) { tool in
                Button(tool.title) { show(tool) }
            }
        }
        Divider()
        Button("Quit MacTools") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func show(_ tool: ToolID?) {
        if let tool = tool { appState.selection = tool }
        AppState.showMainWindow { openWindow(id: "main") }
    }
}
