import SwiftUI
import AppKit

struct AutoTyperSettings: Codable, Equatable {
    enum Mode: String, Codable, CaseIterable, Identifiable {
        case wholeText, eachLine, randomLine
        var id: String { rawValue }
        var title: String {
            switch self {
            case .wholeText: return "Whole text"
            case .eachLine: return "One line at a time"
            case .randomLine: return "Random line"
            }
        }
    }

    var text = "Hello from MacTools!"
    var mode: Mode = .wholeText
    var charDelayMs: Double = 25
    var humanize = false
    var pressEnter = true
    var usePaste = false
    var intervalSec: Double = 2
    var repeatCount: Int = 1        // 0 = forever
    var startDelay: Double = 3
}

final class AutoTyper: ObservableObject {
    static let shared = AutoTyper()

    @Published var settings: AutoTyperSettings {
        didSet { Prefs.save("autoTyperSettings", settings) }
    }
    @Published private(set) var running = false
    @Published private(set) var status = ""
    @Published var lastError: String?

    private var token: CancelToken?

    private init() {
        settings = Prefs.load("autoTyperSettings", default: AutoTyperSettings())
    }

    func toggle() {
        if running { stop() } else { start() }
    }

    func start() {
        guard !running else { return }
        guard Permissions.shared.ensureAccessibility() else {
            lastError = "Accessibility permission is required for typing."
            return
        }
        let s = settings
        guard !s.text.isEmpty else {
            lastError = "Enter some text to type first."
            return
        }
        lastError = nil
        let token = CancelToken()
        self.token = token
        running = true
        status = s.startDelay > 0 ? "Starting in \(Int(s.startDelay))s — click into the target window…" : "Typing…"

        let lines = s.text.components(separatedBy: .newlines).filter { !$0.isEmpty }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            func report(_ text: String) {
                DispatchQueue.main.async { self?.status = text }
            }
            if s.startDelay > 0 && !token.pause(s.startDelay) {
                AutoTyper.finish(self, token)
                return
            }
            var iteration = 0
            var lineIndex = 0
            while !token.isCancelled && (s.repeatCount == 0 || iteration < s.repeatCount) {
                let chunk: String
                switch s.mode {
                case .wholeText:
                    chunk = s.text
                case .eachLine:
                    if lines.isEmpty { chunk = s.text } else {
                        chunk = lines[lineIndex % lines.count]
                        lineIndex += 1
                    }
                case .randomLine:
                    chunk = lines.randomElement() ?? s.text
                }
                iteration += 1
                report(s.repeatCount == 0 ? "Typing message \(iteration)…" : "Typing \(iteration) of \(s.repeatCount)…")

                if s.usePaste {
                    InputSynth.paste(chunk)
                } else {
                    for ch in chunk {
                        if token.isCancelled { break }
                        InputSynth.typeCharacter(ch)
                        var delay = s.charDelayMs / 1000
                        if s.humanize { delay *= Double.random(in: 0.4...1.8) }
                        if delay > 0 && !token.pause(delay) { break }
                    }
                }
                if token.isCancelled { break }
                if s.pressEnter {
                    Thread.sleep(forTimeInterval: 0.03)
                    InputSynth.press(36)
                }
                if s.repeatCount != 0 && iteration >= s.repeatCount { break }
                if !token.pause(s.intervalSec) { break }
            }
            report(token.isCancelled ? "Stopped" : "Finished")
            AutoTyper.finish(self, token)
        }
    }

    private static func finish(_ typer: AutoTyper?, _ token: CancelToken) {
        DispatchQueue.main.async {
            guard let typer = typer, typer.token === token else { return }
            typer.token = nil
            typer.running = false
        }
    }

    func stop() {
        token?.cancel()
        token = nil
        if running { status = "Stopped" }
        running = false
    }
}

struct AutoTyperView: View {
    @ObservedObject private var typer = AutoTyper.shared

    var body: some View {
        ToolPage(tool: .autoTyper) {
            PermissionBanner(needs: [.accessibility])
            if let error = typer.lastError {
                Label(error, systemImage: "exclamationmark.circle").foregroundColor(.red)
            }

            Card(title: "Control", icon: "play.circle") {
                HStack(spacing: 12) {
                    Button {
                        typer.toggle()
                    } label: {
                        Label(typer.running ? "Stop Typing" : "Start Typing",
                              systemImage: typer.running ? "stop.fill" : "play.fill")
                            .frame(minWidth: 140)
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .tint(typer.running ? Color.red : Color.accentColor)
                    StatusBadge(active: typer.running, activeText: "Running", idleText: "Stopped")
                    Text(typer.status).foregroundStyle(.secondary)
                    Spacer()
                    HotKeyHint(action: .toggleAutoTyper)
                }
                Text("After pressing Start, click into the window you want to type in before the start delay ends.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Card(title: "Text to Type", icon: "text.alignleft") {
                CodeEditor(text: $typer.settings.text, minHeight: 140, monospaced: false)
                    .frame(height: 160)
                HStack {
                    Text("\(typer.settings.text.count) characters").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Paste from Clipboard") {
                        if let s = ClipboardHelper.string { typer.settings.text = s }
                    }
                }
                Picker("Send", selection: $typer.settings.mode) {
                    ForEach(AutoTyperSettings.Mode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 420)
            }

            Card(title: "Timing", icon: "clock") {
                HStack(spacing: 20) {
                    NumberField(title: "Delay between characters", value: $typer.settings.charDelayMs, unit: "ms")
                    Toggle("Human-like random speed", isOn: $typer.settings.humanize)
                }
                HStack(spacing: 20) {
                    IntField(title: "Repeat", value: $typer.settings.repeatCount, unit: "times (0 = forever)")
                    NumberField(title: "Wait between repeats", value: $typer.settings.intervalSec, unit: "sec")
                }
                NumberField(title: "Start delay", value: $typer.settings.startDelay, unit: "sec")
                Toggle("Press Return after each message", isOn: $typer.settings.pressEnter)
                Toggle("Paste instead of typing (instant, uses the clipboard)", isOn: $typer.settings.usePaste)
            }
        }
    }
}
