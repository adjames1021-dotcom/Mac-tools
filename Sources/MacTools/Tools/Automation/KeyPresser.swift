import SwiftUI
import AppKit

struct KeyPresserSettings: Codable, Equatable {
    enum Mode: String, Codable, CaseIterable, Identifiable {
        case repeatPress, hold
        var id: String { rawValue }
        var title: String {
            switch self {
            case .repeatPress: return "Press repeatedly"
            case .hold: return "Hold down until stopped"
            }
        }
    }

    var keys: [KeyCombo] = [KeyCombo(keyCode: 49)]   // Space
    var mode: Mode = .repeatPress
    var intervalMs: Double = 500
    var holdMs: Double = 30
    var keyGapMs: Double = 50
    var repeatCount: Int = 0          // 0 = forever
    var startDelay: Double = 3
    var jitterMs: Double = 0
}

final class KeyPresser: ObservableObject {
    static let shared = KeyPresser()

    @Published var settings: KeyPresserSettings {
        didSet { Prefs.save("keyPresserSettings", settings) }
    }
    @Published private(set) var running = false
    @Published private(set) var presses = 0
    @Published var lastError: String?

    private var token: CancelToken?

    private init() {
        settings = Prefs.load("keyPresserSettings", default: KeyPresserSettings())
    }

    func toggle() {
        if running { stop() } else { start() }
    }

    func start() {
        guard !running else { return }
        guard Permissions.shared.ensureAccessibility() else {
            lastError = "Accessibility permission is required to press keys."
            return
        }
        let s = settings
        guard !s.keys.isEmpty else {
            lastError = "Add at least one key."
            return
        }
        lastError = nil
        let token = CancelToken()
        self.token = token
        running = true
        presses = 0

        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            if s.startDelay > 0 && !token.pause(s.startDelay) {
                KeyPresser.finish(self, token)
                return
            }
            if s.mode == .hold {
                for combo in s.keys {
                    InputSynth.key(CGKeyCode(combo.keyCode), down: true, flags: combo.cgFlags)
                }
                // Some games need auto-repeat events while a key is held.
                while !token.isCancelled {
                    if !token.pause(0.05) { break }
                    for combo in s.keys {
                        let event = CGEvent(keyboardEventSource: InputSynth.source, virtualKey: CGKeyCode(combo.keyCode), keyDown: true)
                        event?.flags = combo.cgFlags
                        event?.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
                        InputSynth.post(event)
                    }
                }
                for combo in s.keys {
                    InputSynth.key(CGKeyCode(combo.keyCode), down: false, flags: [])
                }
                KeyPresser.finish(self, token)
                return
            }

            var count = 0
            var lastUI = 0.0
            while !token.isCancelled && (s.repeatCount == 0 || count < s.repeatCount) {
                for (i, combo) in s.keys.enumerated() {
                    if token.isCancelled { break }
                    InputSynth.press(combo, holdSeconds: s.holdMs / 1000)
                    if i < s.keys.count - 1 && !token.pause(s.keyGapMs / 1000) { break }
                }
                count += 1
                let now = ProcessInfo.processInfo.systemUptime
                if now - lastUI > 0.1 {
                    lastUI = now
                    let c = count
                    DispatchQueue.main.async { self?.presses = c }
                }
                if s.repeatCount != 0 && count >= s.repeatCount { break }
                let extra = s.jitterMs > 0 ? Double.random(in: 0...s.jitterMs) / 1000 : 0
                if !token.pause(max(0.001, s.intervalMs / 1000 + extra)) { break }
            }
            let final = count
            DispatchQueue.main.async { self?.presses = final }
            KeyPresser.finish(self, token)
        }
    }

    private static func finish(_ presser: KeyPresser?, _ token: CancelToken) {
        DispatchQueue.main.async {
            guard let presser = presser, presser.token === token else { return }
            presser.token = nil
            presser.running = false
        }
    }

    func stop() {
        token?.cancel()
        token = nil
        running = false
    }
}

struct KeyPresserView: View {
    @ObservedObject private var presser = KeyPresser.shared

    var body: some View {
        ToolPage(tool: .keyPresser) {
            PermissionBanner(needs: [.accessibility])
            if let error = presser.lastError {
                Label(error, systemImage: "exclamationmark.circle").foregroundColor(.red)
            }

            Card(title: "Control", icon: "play.circle") {
                HStack(spacing: 12) {
                    Button {
                        presser.toggle()
                    } label: {
                        Label(presser.running ? "Stop" : "Start",
                              systemImage: presser.running ? "stop.fill" : "play.fill")
                            .frame(minWidth: 120)
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .tint(presser.running ? Color.red : Color.accentColor)
                    StatusBadge(active: presser.running,
                                activeText: presser.settings.mode == .hold ? "Holding" : "Pressing",
                                idleText: "Stopped")
                    if presser.settings.mode == .repeatPress {
                        Text("\(presser.presses) presses").monospacedDigit().foregroundStyle(.secondary)
                    }
                    Spacer()
                    HotKeyHint(action: .toggleKeyPresser)
                }
            }

            Card(title: "Keys", icon: "keyboard") {
                Text("Keys are pressed in this order every cycle. Click a key to change it, then press the new key (modifiers like ⌘ ⇧ work too).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(presser.settings.keys.indices, id: \.self) { index in
                    HStack {
                        Text("\(index + 1).").foregroundStyle(.secondary).frame(width: 24)
                        KeyComboRecorder(combo: Binding<KeyCombo?>(
                            get: { presser.settings.keys.indices.contains(index) ? presser.settings.keys[index] : nil },
                            set: { value in
                                if let value = value, presser.settings.keys.indices.contains(index) {
                                    presser.settings.keys[index] = value
                                }
                            }))
                        Picker("", selection: Binding<UInt16>(
                            get: { presser.settings.keys.indices.contains(index) ? presser.settings.keys[index].keyCode : 49 },
                            set: { code in
                                if presser.settings.keys.indices.contains(index) { presser.settings.keys[index].keyCode = code }
                            })) {
                            ForEach(KeyNames.selectableKeys, id: \.code) { key in
                                Text(key.name).tag(key.code)
                            }
                        }
                        .frame(width: 140)
                        .help("Or choose the key from the list")
                        Spacer()
                        Button {
                            if presser.settings.keys.indices.contains(index) {
                                presser.settings.keys.remove(at: index)
                            }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .disabled(presser.settings.keys.count <= 1)
                    }
                }
                Button {
                    presser.settings.keys.append(KeyCombo(keyCode: 36))
                } label: {
                    Label("Add Key", systemImage: "plus")
                }
            }

            Card(title: "Timing", icon: "clock") {
                Picker("Mode", selection: $presser.settings.mode) {
                    ForEach(KeyPresserSettings.Mode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 420)
                if presser.settings.mode == .repeatPress {
                    HStack(spacing: 20) {
                        NumberField(title: "Every", value: $presser.settings.intervalMs, unit: "ms")
                        NumberField(title: "Hold each press", value: $presser.settings.holdMs, unit: "ms")
                        NumberField(title: "Gap between keys", value: $presser.settings.keyGapMs, unit: "ms")
                    }
                    HStack(spacing: 20) {
                        IntField(title: "Repeat", value: $presser.settings.repeatCount, unit: "times (0 = forever)")
                        NumberField(title: "Random extra delay", value: $presser.settings.jitterMs, unit: "ms")
                    }
                } else {
                    Text("All keys are held down together until you stop.").foregroundStyle(.secondary)
                }
                NumberField(title: "Start delay", value: $presser.settings.startDelay, unit: "sec")
            }
        }
    }
}
