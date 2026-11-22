import SwiftUI

enum ToolCategory: String, CaseIterable, Identifiable, Hashable {
    case general = "General"
    case automation = "Automation"
    case productivity = "Productivity"
    case fun = "Fun"
    case developer = "Developer"
    case text = "Text & Data"
    case files = "Files & Media"
    case system = "System"
    case network = "Network"
    case calculators = "Calculators & Converters"

    var id: String { rawValue }
}

enum ToolID: String, CaseIterable, Identifiable, Hashable {
    // General
    case home, themes, settings, updates, credits
    // Automation
    case macroRecorder, autoClicker, autoTyper, keyPresser, textExpander, keepAwake, scheduler, shellRunner, launcher, keyboardLock
    // Productivity
    case schoolPlanner, clipboard, notes, timers, windowManager, screenshot, colorPicker, mouseInspector, speech
    // Fun
    case christmas, htmlGames
    // Developer
    case httpClient, gitHelper, portMonitor, devEnvironment, homebrew, sshKeys, jwtDecoder, urlParser, csvJson, cronHelper, markdownPreview, snippets, gitignoreGen, hexViewer, chromeExtensionViewer, chromeInspector, godotInspector, encryption, keyCodeViewer, devCleaner, localStorage
    // Text & data
    case textTools, jsonFormatter, regexTester, diffChecker, passwordGenerator, hashTool, qrCode, randomGenerator
    // Files & media
    case pdfEditor, batchRenamer, imageTools, mp3ToFlac, diskUsage, duplicateFinder, saveInspector
    // System
    case systemInfo, processManager, appUninstaller, startupItems, systemToggles, managementInspector
    // Network
    case networkTools, nmap, proxyClient
    // Calculators
    case calculator, unitConverter, baseConverter, timestampConverter

    var id: String { rawValue }

    #if LITE
    /// MacTools Lite: the diagnostic core only.
    static let visible: [ToolID] = [.home, .systemInfo, .managementInspector, .processManager, .startupItems, .appUninstaller,
                                    .diskUsage, .duplicateFinder, .networkTools, .nmap, .portMonitor,
                                    .hashTool, .shellRunner, .textTools]
    #else
    static let visible = allCases
    #endif

    var category: ToolCategory {
        switch self {
        case .home, .themes, .settings, .updates, .credits: return .general
        case .christmas, .htmlGames: return .fun
        case .httpClient, .gitHelper, .portMonitor, .devEnvironment, .homebrew, .sshKeys, .jwtDecoder, .urlParser, .csvJson, .cronHelper, .markdownPreview, .snippets, .gitignoreGen, .hexViewer, .chromeExtensionViewer, .chromeInspector, .godotInspector, .encryption, .keyCodeViewer, .devCleaner, .localStorage:
            return .developer
        case .macroRecorder, .autoClicker, .autoTyper, .keyPresser, .textExpander, .keepAwake, .scheduler, .shellRunner, .launcher, .keyboardLock:
            return .automation
        case .schoolPlanner, .clipboard, .notes, .timers, .windowManager, .screenshot, .colorPicker, .mouseInspector, .speech:
            return .productivity
        case .textTools, .jsonFormatter, .regexTester, .diffChecker, .passwordGenerator, .hashTool, .qrCode, .randomGenerator:
            return .text
        case .pdfEditor, .batchRenamer, .imageTools, .mp3ToFlac, .diskUsage, .duplicateFinder, .saveInspector:
            return .files
        case .systemInfo, .processManager, .appUninstaller, .startupItems, .systemToggles, .managementInspector:
            return .system
        case .networkTools, .nmap, .proxyClient:
            return .network
        case .calculator, .unitConverter, .baseConverter, .timestampConverter:
            return .calculators
        }
    }

    var title: String {
        switch self {
        case .home: return "Home"
        case .themes: return "Themes"
        case .christmas: return "Christmas"
        case .htmlGames: return "HTML Game Editor"
        case .settings: return "Permissions & Hotkeys"
        case .updates: return "Updates"
        case .credits: return "Credits"
        case .httpClient: return "HTTP / API Client"
        case .gitHelper: return "Git Helper"
        case .portMonitor: return "Ports & Web Server"
        case .devEnvironment: return "Dev Environment"
        case .homebrew: return "Homebrew Manager"
        case .sshKeys: return "SSH Keys"
        case .jwtDecoder: return "JWT Decoder"
        case .urlParser: return "URL Parser"
        case .csvJson: return "CSV ⇄ JSON"
        case .cronHelper: return "Cron Helper"
        case .markdownPreview: return "Markdown Editor"
        case .snippets: return "Code Snippets"
        case .gitignoreGen: return ".gitignore Generator"
        case .hexViewer: return "Hex Viewer"
        case .chromeExtensionViewer: return "Chrome Extension Viewer"
        case .chromeInspector: return "Element Inspector"
        case .godotInspector: return "Godot Pack Inspector"
        case .localStorage: return "Local Storage Editor"
        case .encryption: return "Encrypt & Decrypt"
        case .keyCodeViewer: return "Key Code Viewer"
        case .devCleaner: return "Developer Cleaner"
        case .appUninstaller: return "App Uninstaller"
        case .startupItems: return "Startup Items"
        case .macroRecorder: return "Macro Recorder"
        case .autoClicker: return "Auto Clicker"
        case .autoTyper: return "Auto Typer"
        case .keyPresser: return "Key Presser"
        case .textExpander: return "Text Expander"
        case .keepAwake: return "Keep Awake & Jiggler"
        case .scheduler: return "Task Scheduler"
        case .shellRunner: return "Command Runner"
        case .launcher: return "Workspace Launcher"
        case .keyboardLock: return "Keyboard Cleaner"
        case .schoolPlanner: return "School To-Do"
        case .clipboard: return "Clipboard History"
        case .notes: return "Quick Notes"
        case .timers: return "Timers & Pomodoro"
        case .windowManager: return "Window Manager"
        case .screenshot: return "Screenshot"
        case .colorPicker: return "Color Picker"
        case .mouseInspector: return "Mouse & Screen Ruler"
        case .speech: return "Text to Speech"
        case .textTools: return "Text Tools"
        case .jsonFormatter: return "JSON Formatter"
        case .regexTester: return "Regex Tester"
        case .diffChecker: return "Diff Checker"
        case .passwordGenerator: return "Password Generator"
        case .hashTool: return "Hash & Checksum"
        case .qrCode: return "QR Codes"
        case .randomGenerator: return "Random Generator"
        case .pdfEditor: return "PDF Editor"
        case .batchRenamer: return "Batch Renamer"
        case .imageTools: return "Image Converter"
        case .mp3ToFlac: return "MP3 to FLAC"
        case .diskUsage: return "Disk Usage"
        case .duplicateFinder: return "Duplicate Finder"
        case .saveInspector: return "Save Editor"
        case .systemInfo: return "System Info"
        case .processManager: return "App & Process Manager"
        case .systemToggles: return "System Toggles"
        case .managementInspector: return "Management Inspector"
        case .networkTools: return "Network Tools"
        case .nmap: return "Nmap Scanner"
        case .proxyClient: return "VPN / Proxy Client"
        case .calculator: return "Calculator"
        case .unitConverter: return "Unit Converter"
        case .baseConverter: return "Number Base Converter"
        case .timestampConverter: return "Date & Time Tools"
        }
    }

    var icon: String {
        switch self {
        case .home: return "square.grid.2x2"
        case .themes: return "paintpalette"
        case .christmas: return "snowflake"
        case .htmlGames: return "gamecontroller"
        case .settings: return "lock.shield"
        case .updates: return "arrow.down.circle"
        case .credits: return "person.2"
        case .httpClient: return "paperplane"
        case .gitHelper: return "arrow.triangle.branch"
        case .portMonitor: return "dot.radiowaves.left.and.right"
        case .devEnvironment: return "hammer"
        case .homebrew: return "mug"
        case .sshKeys: return "key.horizontal"
        case .jwtDecoder: return "person.badge.key"
        case .urlParser: return "link"
        case .csvJson: return "tablecells"
        case .cronHelper: return "calendar.badge.clock"
        case .markdownPreview: return "doc.plaintext"
        case .snippets: return "chevron.left.forwardslash.chevron.right"
        case .gitignoreGen: return "eye.slash"
        case .hexViewer: return "doc.viewfinder"
        case .chromeExtensionViewer: return "puzzlepiece.extension"
        case .chromeInspector: return "rectangle.and.text.magnifyingglass"
        case .godotInspector: return "shippingbox"
        case .localStorage: return "externaldrive.badge.person.crop"
        case .encryption: return "lock.doc"
        case .keyCodeViewer: return "keyboard.badge.eye"
        case .devCleaner: return "externaldrive.badge.minus"
        case .appUninstaller: return "trash.square"
        case .startupItems: return "power.circle"
        case .macroRecorder: return "record.circle"
        case .autoClicker: return "cursorarrow.click.2"
        case .autoTyper: return "keyboard"
        case .keyPresser: return "repeat.circle"
        case .textExpander: return "text.badge.plus"
        case .keepAwake: return "cup.and.saucer"
        case .scheduler: return "calendar.badge.clock"
        case .shellRunner: return "terminal"
        case .launcher: return "square.stack.3d.up"
        case .keyboardLock: return "lock"
        case .schoolPlanner: return "graduationcap"
        case .clipboard: return "doc.on.clipboard"
        case .notes: return "note.text"
        case .timers: return "timer"
        case .windowManager: return "rectangle.split.2x1"
        case .screenshot: return "camera.viewfinder"
        case .colorPicker: return "eyedropper"
        case .mouseInspector: return "scope"
        case .speech: return "speaker.wave.2"
        case .textTools: return "textformat"
        case .jsonFormatter: return "curlybraces"
        case .regexTester: return "asterisk.circle"
        case .diffChecker: return "arrow.left.arrow.right"
        case .passwordGenerator: return "key"
        case .hashTool: return "number"
        case .qrCode: return "qrcode"
        case .randomGenerator: return "dice"
        case .pdfEditor: return "doc.richtext"
        case .batchRenamer: return "pencil"
        case .imageTools: return "photo.on.rectangle"
        case .mp3ToFlac: return "waveform"
        case .diskUsage: return "internaldrive"
        case .duplicateFinder: return "doc.on.doc"
        case .saveInspector: return "doc.badge.gearshape"
        case .systemInfo: return "info.circle"
        case .processManager: return "list.bullet.rectangle"
        case .systemToggles: return "switch.2"
        case .managementInspector: return "building.columns"
        case .networkTools: return "network"
        case .nmap: return "network.badge.shield.half.filled"
        case .proxyClient: return "lock.shield"
        case .calculator: return "plus.forwardslash.minus"
        case .unitConverter: return "ruler"
        case .baseConverter: return "number.square"
        case .timestampConverter: return "clock"
        }
    }

    var summary: String {
        switch self {
        case .home: return "Every tool in one place."
        case .themes: return "Color themes and Light or Dark mode for all of MacTools."
        case .christmas: return "Snow, twinkling lights, a countdown, jingle bells and more festive touches."
        case .htmlGames: return "Play downloaded or online HTML games and edit their saves, storage and values like gold."
        case .settings: return "Grant permissions, customise global hotkeys and app options."
        case .updates: return "Update MacTools automatically from GitHub – no rebuilding by hand."
        case .credits: return "The people who make and test MacTools."
        case .httpClient: return "Send API requests (GET, POST…) with headers and JSON bodies, like Postman."
        case .gitHelper: return "See status, commit, pull, push, switch branches for any repository."
        case .portMonitor: return "See what's listening on which port, stop it, or serve a folder locally."
        case .devEnvironment: return "Which languages and tools are installed, their versions, PATH and env vars."
        case .homebrew: return "Search, install, upgrade and remove Homebrew packages and apps."
        case .sshKeys: return "View, create and test SSH keys for GitHub and servers."
        case .jwtDecoder: return "Decode JSON Web Tokens, check expiry and verify HMAC signatures."
        case .urlParser: return "Break a URL into parts and edit its query parameters."
        case .csvJson: return "Convert between CSV and JSON with a table preview."
        case .cronHelper: return "Understand cron schedules and see their next run times."
        case .markdownPreview: return "Write Markdown with a live preview and export to HTML."
        case .snippets: return "Save and search reusable pieces of code."
        case .gitignoreGen: return "Build a .gitignore for your project's languages and tools."
        case .hexViewer: return "Look inside any file byte by byte and detect its real type."
        case .chromeExtensionViewer: return "Download any Chrome Web Store extension and read its source code."
        case .chromeInspector: return "A DevTools-style inspector for your own Chrome tabs: edit the DOM, read the console, run JS, with a floating window and AI help."
        case .godotInspector: return "Open a Godot game's .pck, list its files and read the GDScript functions inside."
        case .localStorage: return "View and edit your browser's localStorage for any website."
        case .encryption: return "Password-protect text and files with AES-256 encryption."
        case .keyCodeViewer: return "Press any key to see its key code, characters and modifiers."
        case .devCleaner: return "Free space taken by Xcode, npm, Homebrew and other caches and node_modules."
        case .appUninstaller: return "Delete apps along with all their caches, settings and leftover data."
        case .startupItems: return "See and remove background helpers that start with your Mac."
        case .macroRecorder: return "Record keyboard & mouse actions and replay them with loops and speed control."
        case .autoClicker: return "Click and press keys automatically, with hotkeys, hold-to-click and step sequences."
        case .autoTyper: return "Type text automatically, repeat messages, line-by-line sending."
        case .keyPresser: return "Press or hold any key or key combo on repeat."
        case .textExpander: return "Type a short abbreviation and have it expand into full text."
        case .keepAwake: return "Stop your Mac sleeping and keep the mouse active."
        case .scheduler: return "Run actions, scripts, macros or reminders at set times."
        case .shellRunner: return "Run shell commands and AppleScripts, save favourites."
        case .launcher: return "Open a whole set of apps, files and websites in one click."
        case .keyboardLock: return "Temporarily lock the keyboard so you can clean it."
        case .schoolPlanner: return "Google Classroom + Infinite Campus in one to-do list, sorted by grade impact by AI."
        case .clipboard: return "Keep a searchable history of everything you copy."
        case .notes: return "A scratchpad for quick notes that saves automatically."
        case .timers: return "Stopwatch, countdown timer and Pomodoro focus timer."
        case .windowManager: return "Snap windows to halves, thirds, quarters with hotkeys."
        case .screenshot: return "Capture the screen, a window or a selection with options."
        case .colorPicker: return "Pick any colour on screen and copy it as HEX, RGB, HSL…"
        case .mouseInspector: return "Live cursor coordinates, display info and an on-screen ruler."
        case .speech: return "Read text aloud with any voice and export to audio."
        case .textTools: return "Change case, sort lines, encode/decode, count words and more."
        case .jsonFormatter: return "Pretty-print, minify and validate JSON."
        case .regexTester: return "Test regular expressions with live highlighting and replace."
        case .diffChecker: return "Compare two texts line by line."
        case .passwordGenerator: return "Strong passwords and passphrases with strength estimate."
        case .hashTool: return "MD5, SHA-1, SHA-256, SHA-512 and HMAC for text and files."
        case .qrCode: return "Create QR codes and read them from images or the screen."
        case .randomGenerator: return "Random numbers, dice, coin flips, UUIDs and list picks."
        case .pdfEditor: return "Annotate, sign, highlight, reorder, merge, split, watermark and protect PDFs."
        case .batchRenamer: return "Rename many files at once with preview and undo."
        case .imageTools: return "Convert, resize, rotate images and combine them into a PDF."
        case .mp3ToFlac: return "Convert MP3s to FLAC, keeping cover art, artist, album and all other tags."
        case .diskUsage: return "Find what is using your disk space."
        case .duplicateFinder: return "Find duplicate files by content."
        case .saveInspector: return "Break down save files and find and edit values like money, in any file type."
        case .systemInfo: return "Hardware, memory, disk, battery and OS details."
        case .processManager: return "See running apps and processes, quit or force quit them."
        case .systemToggles: return "Hidden files, dark mode, Dock, Finder tweaks and quick actions."
        case .managementInspector: return "See whether this Mac is managed, by whom, and every profile, restriction, filter and agent in force – no admin needed."
        case .networkTools: return "IP info, ping, DNS, port check, traceroute, speed test…"
        case .nmap: return "Scan hosts and networks with nmap, with every option explained in plain English."
        case .proxyClient: return "Hiddify-style client: import a subscription or vless/vmess/trojan/ss/hysteria2/tuic links and connect through sing-box."
        case .calculator: return "Scientific expression calculator with history."
        case .unitConverter: return "Convert length, weight, temperature, data and more."
        case .baseConverter: return "Binary, octal, decimal, hex and text bytes."
        case .timestampConverter: return "Unix timestamps, world clock and date differences."
        }
    }

    func makeView() -> AnyView {
        switch self {
        case .home: return AnyView(HomeView())
        case .themes: return AnyView(ThemesView())
        case .christmas: return AnyView(ChristmasView())
        case .htmlGames: return AnyView(HTMLGameEditorView())
        case .settings: return AnyView(SettingsToolView())
        case .updates: return AnyView(UpdatesView())
        case .credits: return AnyView(CreditsView())
        case .httpClient: return AnyView(HTTPClientView())
        case .gitHelper: return AnyView(GitHelperView())
        case .portMonitor: return AnyView(PortMonitorView())
        case .devEnvironment: return AnyView(DevEnvironmentView())
        case .homebrew: return AnyView(HomebrewView())
        case .sshKeys: return AnyView(SSHKeysView())
        case .jwtDecoder: return AnyView(JWTDecoderView())
        case .urlParser: return AnyView(URLParserView())
        case .csvJson: return AnyView(CSVJSONView())
        case .cronHelper: return AnyView(CronHelperView())
        case .markdownPreview: return AnyView(MarkdownView())
        case .snippets: return AnyView(SnippetsView())
        case .gitignoreGen: return AnyView(GitignoreView())
        case .hexViewer: return AnyView(HexViewerView())
        case .chromeExtensionViewer: return AnyView(ChromeExtensionViewerView())
        case .chromeInspector: return AnyView(ChromeInspectorView())
        case .godotInspector: return AnyView(GodotInspectorView())
        case .localStorage: return AnyView(LocalStorageEditorView())
        case .encryption: return AnyView(EncryptionView())
        case .keyCodeViewer: return AnyView(KeyCodeViewerView())
        case .devCleaner: return AnyView(DevCleanerView())
        case .appUninstaller: return AnyView(AppUninstallerView())
        case .startupItems: return AnyView(StartupItemsView())
        case .macroRecorder: return AnyView(MacroRecorderView())
        case .autoClicker: return AnyView(AutoClickerView())
        case .autoTyper: return AnyView(AutoTyperView())
        case .keyPresser: return AnyView(KeyPresserView())
        case .textExpander: return AnyView(TextExpanderView())
        case .keepAwake: return AnyView(KeepAwakeView())
        case .scheduler: return AnyView(SchedulerView())
        case .shellRunner: return AnyView(ShellRunnerView())
        case .launcher: return AnyView(LauncherView())
        case .keyboardLock: return AnyView(KeyboardLockView())
        case .schoolPlanner: return AnyView(SchoolPlannerView())
        case .clipboard: return AnyView(ClipboardView())
        case .notes: return AnyView(NotesView())
        case .timers: return AnyView(TimersView())
        case .windowManager: return AnyView(WindowManagerView())
        case .screenshot: return AnyView(ScreenshotView())
        case .colorPicker: return AnyView(ColorPickerTool())
        case .mouseInspector: return AnyView(MouseInspectorView())
        case .speech: return AnyView(SpeechView())
        case .textTools: return AnyView(TextToolsView())
        case .jsonFormatter: return AnyView(JSONFormatterView())
        case .regexTester: return AnyView(RegexTesterView())
        case .diffChecker: return AnyView(DiffCheckerView())
        case .passwordGenerator: return AnyView(PasswordGeneratorView())
        case .hashTool: return AnyView(HashToolView())
        case .qrCode: return AnyView(QRCodeView())
        case .randomGenerator: return AnyView(RandomGeneratorView())
        case .pdfEditor: return AnyView(PDFEditorView())
        case .batchRenamer: return AnyView(BatchRenamerView())
        case .imageTools: return AnyView(ImageToolsView())
        case .mp3ToFlac: return AnyView(MP3ToFLACView())
        case .diskUsage: return AnyView(DiskUsageView())
        case .duplicateFinder: return AnyView(DuplicateFinderView())
        case .saveInspector: return AnyView(SaveInspectorView())
        case .systemInfo: return AnyView(SystemInfoView())
        case .processManager: return AnyView(ProcessManagerView())
        case .systemToggles: return AnyView(SystemTogglesView())
        case .managementInspector: return AnyView(ManagementInspectorView())
        case .networkTools: return AnyView(NetworkToolsView())
        case .nmap: return AnyView(NmapToolView())
        case .proxyClient: return AnyView(ProxyClientView())
        case .calculator: return AnyView(CalculatorView())
        case .unitConverter: return AnyView(UnitConverterView())
        case .baseConverter: return AnyView(BaseConverterView())
        case .timestampConverter: return AnyView(TimestampView())
        }
    }
}
