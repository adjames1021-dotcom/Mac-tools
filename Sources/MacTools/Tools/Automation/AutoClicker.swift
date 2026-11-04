import SwiftUI
import AppKit

/// One step of an auto-clicker sequence: a click at a point, a key press, typed text or a pause.
struct ClickPoint: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case click, key, text, wait
        var id: String { rawValue }
        var title: String {
            switch self {
            case .click: return "Click"
            case .key: return "Press key"
            case .text: return "Type text"
            case .wait: return "Wait"
            }
        }
        var icon: String {
            switch self {
            case .click: return "cursorarrow.click"
            case .key: return "keyboard"
            case .text: return "character.cursor.ibeam"
            case .wait: return "hourglass"
            }
        }
    }

    var id = UUID()
    var kind: Kind = .click
    var x: Double = 0
    var y: Double = 0
    var delayMs: Double = 500
    var button: MouseButtonKind = .left
    var clicks: Int = 1
    var key: KeyCombo = KeyCombo(keyCode: 36)
    var text: String = ""
}

struct AutoClickerSettings: Codable, Equatable {
    enum LocationMode: String, Codable, CaseIterable, Identifiable {
        case cursor, fixed, sequence
        var id: String { rawValue }
        var title: String {
            switch self {
            case .cursor: return "Wherever the cursor is"
            case .fixed: return "Fixed position"
            case .sequence: return "Sequence of steps (clicks, keys, text)"
            }
        }
    }

    enum StopMode: String, Codable, CaseIterable, Identifiable {
        case never, afterClicks, afterSeconds
        var id: String { rawValue }
        var title: String {
            switch self {
            case .never: return "Until stopped"
            case .afterClicks: return "After N clicks"
            case .afterSeconds: return "After a time limit"
            }
        }
    }

    enum KeyTiming: String, Codable, CaseIterable, Identifiable {
        case before, after, instead
        var id: String { rawValue }
        var title: String {
            switch self {
            case .before: return "Before each click"
            case .after: return "After each click"
            case .instead: return "Instead of clicking"
            }
        }
    }

    enum Activation: String, Codable, CaseIterable, Identifiable {
        case toggle, hold
        var id: String { rawValue }
        var title: String {
            switch self {
            case .toggle: return "Press hotkey to start, again to stop"
            case .hold: return "Click only while the hotkey is held down"
            }
        }
    }

    var intervalMs: Double = 100
    var button: MouseButtonKind = .left
    var clicksPerAction: Int = 1      // 1 single, 2 double, 3 triple
    var holdMs: Double = 0
    var location: LocationMode = .cursor
    var fixedX: Double = 500
    var fixedY: Double = 400
    var points: [ClickPoint] = []
    var stopMode: StopMode = .never
    var maxClicks: Int = 100
    var maxSeconds: Double = 60
    var jitterMs: Double = 0
    var positionJitter: Double = 0
    var startDelay: Double = 0
    var pressKey = false
    var keys: [KeyCombo] = [KeyCombo(keyCode: 49)]   // Space
    var keyTiming: KeyTiming = .after
    var keyGapMs: Double = 20
    var activation: Activation = .toggle
    var returnCursor = false
}

final class AutoClicker: ObservableObject {
    static let shared = AutoClicker()

    @Published var settings: AutoClickerSettings {
        didSet { Prefs.save("autoClickerSettings.v2", settings) }
    }
    @Published private(set) var running = false
    @Published private(set) var clicks = 0
    @Published var lastError: String?
    @Published private(set) var lastCapture: CGPoint?

    private var token: CancelToken?

    private init() {
        settings = Prefs.load("autoClickerSettings.v2", default: AutoClickerSettings())
    }

    func toggle() {
        if running { stop() } else { start() }
    }

    // MARK: Hotkeys

    func hotkeyPressed() {
        if settings.activation == .hold {
            start(ignoreStartDelay: true)
        } else {
            toggle()
        }
    }

    func hotkeyReleased() {
        if settings.activation == .hold { stop() }
    }

    /// Captures the current mouse position into the fixed point or the step sequence.
    func captureMousePosition() {
        let p = InputSynth.cursorLocation
        let x = Double(Int(p.x))
        let y = Double(Int(p.y))
        switch settings.location {
        case .sequence:
            settings.points.append(ClickPoint(kind: .click, x: x, y: y, button: settings.button))
        case .cursor, .fixed:
            settings.location = .fixed
            settings.fixedX = x
            settings.fixedY = y
        }
        lastCapture = p
        NSSound(named: "Tink")?.play()
    }

    // MARK: Running

    func start(ignoreStartDelay: Bool = false) {
        guard !running else { return }
        guard Permissions.shared.ensureAccessibility() else {
            lastError = "Accessibility permission is required for clicking and pressing keys."
            return
        }
        let s = settings
        if s.location == .sequence && s.points.isEmpty {
            lastError = "Add at least one step to the sequence first."
            NSSound.beep()
            return
        }
        if s.pressKey && s.keys.isEmpty {
            lastError = "Choose at least one key to press."
            NSSound.beep()
            return
        }
        lastError = nil
        let token = CancelToken()
        self.token = token
        running = true
        clicks = 0
        let startDelay = ignoreStartDelay ? 0 : s.startDelay

        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            if startDelay > 0 && !token.pause(startDelay) {
                AutoClicker.finish(self, token)
                return
            }
            let startTime = ProcessInfo.processInfo.systemUptime
            let originalCursor = InputSynth.cursorLocation
            var count = 0
            var lastUI = 0.0
            var stepIndex = 0

            func shouldStop() -> Bool {
                if token.isCancelled { return true }
                switch s.stopMode {
                case .never: return false
                case .afterClicks: return count >= max(1, s.maxClicks)
                case .afterSeconds: return ProcessInfo.processInfo.systemUptime - startTime >= s.maxSeconds
                }
            }

            func jittered(_ p: CGPoint) -> CGPoint {
                guard s.positionJitter > 0 else { return p }
                return CGPoint(x: p.x + Double.random(in: -s.positionJitter...s.positionJitter),
                               y: p.y + Double.random(in: -s.positionJitter...s.positionJitter))
            }

            func pressKeys() {
                for (i, combo) in s.keys.enumerated() {
                    if token.isCancelled { return }
                    InputSynth.press(combo, holdSeconds: 0.02)
                    if i < s.keys.count - 1 { token.pause(s.keyGapMs / 1000) }
                }
            }

            func click(_ button: MouseButtonKind, at point: CGPoint?, count clickCount: Int) {
                if let point = point { InputSynth.moveMouse(to: point) }
                InputSynth.click(button, at: point, count: max(1, clickCount), holdSeconds: s.holdMs / 1000)
            }

            while !shouldStop() {
                var delay = s.intervalMs / 1000
                switch s.location {
                case .cursor, .fixed:
                    let point: CGPoint? = s.location == .fixed ? jittered(CGPoint(x: s.fixedX, y: s.fixedY)) : nil
                    if s.pressKey && s.keyTiming == .before { pressKeys(); token.pause(s.keyGapMs / 1000) }
                    if !(s.pressKey && s.keyTiming == .instead) {
                        click(s.button, at: point, count: s.clicksPerAction)
                    }
                    if s.pressKey && s.keyTiming == .after { token.pause(s.keyGapMs / 1000); pressKeys() }
                    if s.pressKey && s.keyTiming == .instead { pressKeys() }
                case .sequence:
                    let step = s.points[stepIndex % s.points.count]
                    stepIndex += 1
                    delay = step.delayMs / 1000
                    switch step.kind {
                    case .click:
                        click(step.button, at: jittered(CGPoint(x: step.x, y: step.y)), count: step.clicks)
                        if s.pressKey && s.keyTiming != .instead { token.pause(s.keyGapMs / 1000); pressKeys() }
                    case .key:
                        InputSynth.press(step.key, holdSeconds: 0.02)
                    case .text:
                        InputSynth.type(step.text, charDelay: 0.01, token: token)
                    case .wait:
                        break
                    }
                }
                count += 1

                let now = ProcessInfo.processInfo.systemUptime
                if now - lastUI > 0.1 {
                    lastUI = now
                    let c = count
                    DispatchQueue.main.async { self?.clicks = c }
                }
                if shouldStop() { break }
                let extra = s.jitterMs > 0 ? Double.random(in: 0...s.jitterMs) / 1000 : 0
                if !token.pause(max(0.001, delay + extra)) { break }
            }
            if s.returnCursor && s.location != .cursor {
                InputSynth.moveMouse(to: originalCursor)
            }
            let final = count
            DispatchQueue.main.async { self?.clicks = final }
            AutoClicker.finish(self, token)
        }
    }

    private static func finish(_ clicker: AutoClicker?, _ token: CancelToken) {
        DispatchQueue.main.async {
            guard let clicker = clicker, clicker.token === token else { return }
            clicker.token = nil
            clicker.running = false
        }
    }

    func stop() {
        token?.cancel()
        token = nil
        running = false
    }

    var clicksPerSecond: Double {
        settings.intervalMs > 0 ? 1000 / settings.intervalMs : 0
    }
}

struct AutoClickerView: View {
    @ObservedObject private var clicker = AutoClicker.shared
    @ObservedObject private var hotkeys = HotKeyCenter.shared

    var body: some View {
        ToolPage(tool: .autoClicker) {
            PermissionBanner(needs: [.accessibility])
            if let error = clicker.lastError {
                Label(error, systemImage: "exclamationmark.circle").foregroundColor(.red)
            }
            controlCard
            hotkeyCard
            clickCard
            keyCard
            locationCard
            stopCard
        }
    }

    private var controlCard: some View {
        Card(title: "Control", icon: "play.circle") {
            HStack(spacing: 12) {
                Button {
                    clicker.toggle()
                } label: {
                    Label(clicker.running ? "Stop" : "Start",
                          systemImage: clicker.running ? "stop.fill" : "play.fill")
                        .frame(minWidth: 120)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .tint(clicker.running ? Color.red : Color.accentColor)

                StatusBadge(active: clicker.running, activeText: "Running", idleText: "Stopped")
                Text("\(clicker.clicks) actions").monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                Text(summary).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
            }
        }
    }

    private var summary: String {
        let s = clicker.settings
        var parts: [String] = []
        if !(s.pressKey && s.keyTiming == .instead) || s.location == .sequence {
            parts.append(s.location == .sequence ? "\(s.points.count)-step sequence" : "\(s.button.title.lowercased()) click every \(Int(s.intervalMs)) ms")
        }
        if s.pressKey {
            parts.append("keys " + s.keys.map { $0.displayString }.joined(separator: " "))
        }
        return parts.joined(separator: " + ")
    }

    private var hotkeyCard: some View {
        Card(title: "Hotkeys", icon: "keyboard") {
            HStack {
                Text("Start / stop").frame(width: 150, alignment: .leading)
                KeyComboRecorder(combo: binding(for: .toggleAutoClicker), placeholder: "Not set")
                Spacer()
                Picker("", selection: $clicker.settings.activation) {
                    ForEach(AutoClickerSettings.Activation.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(width: 300)
            }
            HStack {
                Text("Capture mouse position").frame(width: 150, alignment: .leading)
                KeyComboRecorder(combo: binding(for: .captureClickPosition), placeholder: "Not set")
                Text("Hover over a spot and press it to set the click position (or add a step).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            HStack {
                Text("Stop everything").frame(width: 150, alignment: .leading)
                KeyComboRecorder(combo: binding(for: .stopAll), placeholder: "Not set")
                Spacer()
            }
            if let p = clicker.lastCapture {
                Text("Last captured position: \(Int(p.x)), \(Int(p.y))").font(.caption).foregroundStyle(.secondary)
            }
            Text("Hotkeys work from any app. On most Mac keyboards hold fn to press F-keys. Click a hotkey to change it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func binding(for action: HotKeyAction) -> Binding<KeyCombo?> {
        Binding(get: { hotkeys.combo(for: action) }, set: { hotkeys.set($0, for: action) })
    }

    private var clickCard: some View {
        Card(title: "Clicking", icon: "cursorarrow.click.2") {
            HStack(spacing: 20) {
                NumberField(title: "Interval", value: $clicker.settings.intervalMs, unit: "ms")
                Text(String(format: "≈ %.1f per second", clicker.clicksPerSecond))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Text("Presets:").foregroundStyle(.secondary)
                ForEach([1.0, 10.0, 50.0, 100.0, 250.0, 500.0, 1000.0, 5000.0], id: \.self) { ms in
                    Button(ms >= 1000 ? "\(Int(ms / 1000))s" : "\(Int(ms))ms") {
                        clicker.settings.intervalMs = ms
                    }
                }
            }
            HStack(spacing: 20) {
                Picker("Button", selection: $clicker.settings.button) {
                    ForEach(MouseButtonKind.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 300)
                Picker("Click type", selection: $clicker.settings.clicksPerAction) {
                    Text("Single").tag(1)
                    Text("Double").tag(2)
                    Text("Triple").tag(3)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 300)
            }
            HStack(spacing: 20) {
                NumberField(title: "Hold each click", value: $clicker.settings.holdMs, unit: "ms")
                NumberField(title: "Random extra delay", value: $clicker.settings.jitterMs, unit: "ms")
                NumberField(title: "Start delay", value: $clicker.settings.startDelay, unit: "sec")
            }
        }
    }

    private var keyCard: some View {
        Card(title: "Press Keys Too", icon: "keyboard.badge.ellipsis") {
            Toggle("Also press keys while auto-clicking", isOn: $clicker.settings.pressKey)
                .toggleStyle(.switch)
            if clicker.settings.pressKey {
                Picker("When", selection: $clicker.settings.keyTiming) {
                    ForEach(AutoClickerSettings.KeyTiming.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 480)
                Text("Click a key below and press any key or shortcut (letters, numbers, F-keys, arrows, ⌘C, ⇧Tab, Space, Return…). Keys are pressed in order.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(clicker.settings.keys.indices, id: \.self) { index in
                    HStack {
                        Text("\(index + 1).").foregroundStyle(.secondary).frame(width: 24)
                        KeyComboRecorder(combo: Binding<KeyCombo?>(
                            get: { clicker.settings.keys.indices.contains(index) ? clicker.settings.keys[index] : nil },
                            set: { value in
                                if let value = value, clicker.settings.keys.indices.contains(index) {
                                    clicker.settings.keys[index] = value
                                }
                            }))
                        Picker("", selection: Binding<UInt16>(
                            get: { clicker.settings.keys.indices.contains(index) ? clicker.settings.keys[index].keyCode : 49 },
                            set: { code in
                                if clicker.settings.keys.indices.contains(index) { clicker.settings.keys[index].keyCode = code }
                            })) {
                            ForEach(KeyNames.selectableKeys, id: \.code) { key in
                                Text(key.name).tag(key.code)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 130)
                        Spacer()
                        Button {
                            if clicker.settings.keys.indices.contains(index) { clicker.settings.keys.remove(at: index) }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .disabled(clicker.settings.keys.count <= 1)
                    }
                }
                HStack {
                    Button {
                        clicker.settings.keys.append(KeyCombo(keyCode: 36))
                    } label: {
                        Label("Add Key", systemImage: "plus")
                    }
                    NumberField(title: "Gap between keys", value: $clicker.settings.keyGapMs, unit: "ms")
                }
            }
        }
    }

    private var locationCard: some View {
        Card(title: "Where to Click", icon: "scope") {
            Picker("Location", selection: $clicker.settings.location) {
                ForEach(AutoClickerSettings.LocationMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.radioGroup)

            if clicker.settings.location == .fixed {
                HStack(spacing: 16) {
                    NumberField(title: "X", value: $clicker.settings.fixedX)
                    NumberField(title: "Y", value: $clicker.settings.fixedY)
                    PickPointButton { p in
                        clicker.settings.fixedX = Double(Int(p.x))
                        clicker.settings.fixedY = Double(Int(p.y))
                    }
                }
            }
            if clicker.settings.location != .cursor {
                HStack(spacing: 20) {
                    NumberField(title: "Random position offset ±", value: $clicker.settings.positionJitter, unit: "px")
                    Toggle("Put the cursor back when finished", isOn: $clicker.settings.returnCursor)
                }
            }
            if clicker.settings.location == .sequence {
                sequenceEditor
            }
        }
    }

    private var stopCard: some View {
        Card(title: "Stop Condition", icon: "stop.circle") {
            Picker("Stop", selection: $clicker.settings.stopMode) {
                ForEach(AutoClickerSettings.StopMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            if clicker.settings.stopMode == .afterClicks {
                IntField(title: "Stop after", value: $clicker.settings.maxClicks, unit: "actions")
            }
            if clicker.settings.stopMode == .afterSeconds {
                NumberField(title: "Stop after", value: $clicker.settings.maxSeconds, unit: "seconds")
            }
        }
    }

    private var sequenceEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                PickPointButton(title: "Add Click Step") { p in
                    clicker.settings.points.append(ClickPoint(kind: .click, x: Double(Int(p.x)), y: Double(Int(p.y)), button: clicker.settings.button))
                }
                Button("Add Key Step") {
                    clicker.settings.points.append(ClickPoint(kind: .key, delayMs: 200))
                }
                Button("Add Text Step") {
                    clicker.settings.points.append(ClickPoint(kind: .text, delayMs: 300, text: "Hello"))
                }
                Button("Add Wait") {
                    clicker.settings.points.append(ClickPoint(kind: .wait, delayMs: 1000))
                }
                Spacer()
                Button("Clear All", role: .destructive) { clicker.settings.points.removeAll() }
                    .disabled(clicker.settings.points.isEmpty)
            }
            Text("Tip: press the capture hotkey (\(hotkeys.displayString(for: .captureClickPosition))) while hovering to add click steps quickly.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(clicker.settings.points.indices, id: \.self) { index in
                SequenceStepRow(index: index)
            }
            if clicker.settings.points.isEmpty {
                Text("Each step runs in order, then the sequence repeats.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct SequenceStepRow: View {
    let index: Int
    @ObservedObject private var clicker = AutoClicker.shared

    private var step: Binding<ClickPoint> {
        Binding(
            get: { clicker.settings.points.indices.contains(index) ? clicker.settings.points[index] : ClickPoint() },
            set: { if clicker.settings.points.indices.contains(index) { clicker.settings.points[index] = $0 } })
    }

    var body: some View {
        HStack(spacing: 8) {
            Text("\(index + 1)").foregroundStyle(.secondary).frame(width: 20)
            Picker("", selection: step.kind) {
                ForEach(ClickPoint.Kind.allCases) { Label($0.title, systemImage: $0.icon).tag($0) }
            }
            .labelsHidden()
            .frame(width: 120)

            switch step.wrappedValue.kind {
            case .click:
                NumberField(title: "X", value: step.x, width: 55)
                NumberField(title: "Y", value: step.y, width: 55)
                Picker("", selection: step.button) {
                    ForEach(MouseButtonKind.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(width: 85)
                Picker("", selection: step.clicks) {
                    Text("×1").tag(1)
                    Text("×2").tag(2)
                    Text("×3").tag(3)
                }
                .labelsHidden()
                .frame(width: 60)
            case .key:
                KeyComboRecorder(combo: Binding<KeyCombo?>(get: { step.wrappedValue.key }, set: { if let v = $0 { step.wrappedValue.key = v } }))
            case .text:
                TextField("Text to type", text: step.text)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 160)
            case .wait:
                EmptyView()
            }
            NumberField(title: step.wrappedValue.kind == .wait ? "wait" : "then wait", value: step.delayMs, unit: "ms", width: 70)
            Spacer()
            Button {
                if index > 0 { clicker.settings.points.swapAt(index, index - 1) }
            } label: {
                Image(systemName: "arrow.up")
            }
            .buttonStyle(.borderless)
            .disabled(index == 0)
            Button {
                if clicker.settings.points.indices.contains(index) { clicker.settings.points.remove(at: index) }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
    }
}
