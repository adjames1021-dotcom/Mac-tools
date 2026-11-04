import AppKit
import CoreGraphics
import UniformTypeIdentifiers

struct MacroEvent: Codable, Equatable {
    enum Kind: String, Codable {
        case mouseMove, mouseDown, mouseUp, mouseDrag, scroll, keyDown, keyUp, flagsChanged
    }

    var kind: Kind
    var time: Double          // seconds since the start of the recording
    var x: Double = 0
    var y: Double = 0
    var keyCode: Int = 0
    var flags: UInt64 = 0
    var button: Int = 0       // 0 left, 1 right, 2 middle
    var clickCount: Int = 1
    var scrollX: Int = 0
    var scrollY: Int = 0

    var buttonName: String { MouseButtonKind.from(index: button).title }

    var summary: String {
        let pos = "(\(Int(x)), \(Int(y)))"
        switch kind {
        case .mouseMove: return "Move to \(pos)"
        case .mouseDown: return "\(buttonName) button down at \(pos)" + (clickCount > 1 ? " ×\(clickCount)" : "")
        case .mouseUp: return "\(buttonName) button up at \(pos)"
        case .mouseDrag: return "\(buttonName) drag to \(pos)"
        case .scroll: return "Scroll  x: \(scrollX)  y: \(scrollY)"
        case .keyDown:
            return "Key down  " + KeyNames.modifierString(CGEventFlags(rawValue: flags)) + KeyNames.name(for: UInt16(keyCode))
        case .keyUp:
            return "Key up  " + KeyNames.name(for: UInt16(keyCode))
        case .flagsChanged:
            let mods = KeyNames.modifierString(CGEventFlags(rawValue: flags))
            return "Modifiers: " + (mods.isEmpty ? "none" : mods)
        }
    }

    var icon: String {
        switch kind {
        case .mouseMove: return "arrow.up.and.down.and.arrow.left.and.right"
        case .mouseDown, .mouseUp: return "cursorarrow.click"
        case .mouseDrag: return "hand.draw"
        case .scroll: return "scroll"
        case .keyDown, .keyUp, .flagsChanged: return "keyboard"
        }
    }
}

struct SavedMacro: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var created = Date()
    var events: [MacroEvent]

    var duration: Double { events.last?.time ?? 0 }
}

struct MacroSettings: Codable, Equatable {
    var recordMouseMoves = true
    var speed: Double = 1.0
    var repeatCount: Int = 1        // 0 = forever
    var loopDelay: Double = 0.5
    var startDelay: Double = 0
}

final class MacroEngine: ObservableObject {
    static let shared = MacroEngine()

    enum State { case idle, recording, playing }

    @Published private(set) var state: State = .idle
    @Published var events: [MacroEvent] = []
    @Published var currentName = "Untitled Macro"
    @Published var library: [SavedMacro] = [] {
        didSet { DataStore.save(library, to: "macros.json") }
    }
    @Published var settings: MacroSettings {
        didSet { Prefs.save("macroSettings", settings) }
    }
    @Published private(set) var liveCount = 0
    @Published private(set) var progress: Double = 0
    @Published private(set) var loopsDone = 0
    @Published var lastError: String?

    private var tap: EventTap?
    private var buffer: [MacroEvent] = []
    private var recordStart: TimeInterval = 0
    private var ignoredKeys: Set<Int> = []
    private var playToken: CancelToken?
    private var uiTimer: Timer?

    static let recordTypes: [CGEventType] = [
        .mouseMoved, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
        .otherMouseDown, .otherMouseUp, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
        .scrollWheel, .keyDown, .keyUp, .flagsChanged
    ]

    private init() {
        settings = Prefs.load("macroSettings", default: MacroSettings())
        library = DataStore.load([SavedMacro].self, from: "macros.json") ?? []
    }

    var duration: Double { events.last?.time ?? 0 }

    // MARK: Recording

    func toggleRecording() {
        if state == .recording { stopRecording() } else { startRecording() }
    }

    func startRecording() {
        guard state == .idle else { return }
        lastError = nil
        let permissions = Permissions.shared
        permissions.refresh()
        if !permissions.inputMonitoring && !permissions.accessibility {
            permissions.request(.inputMonitoring)
        }
        buffer = []
        ignoredKeys = HotKeyCenter.shared.automationKeyCodes
        let tap = EventTap(listenOnly: true) { [weak self] type, event in
            self?.record(type: type, event: event)
            return event
        }
        guard tap.start(mask: EventTap.mask(MacroEngine.recordTypes)) else {
            lastError = "Couldn't start recording. Give MacTools Input Monitoring and Accessibility permission (Permissions & Hotkeys), then try again."
            NSSound.beep()
            return
        }
        self.tap = tap
        recordStart = ProcessInfo.processInfo.systemUptime
        state = .recording
        liveCount = 0
        uiTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.liveCount = self.buffer.count
        }
        NSSound(named: "Pop")?.play()
    }

    /// Stops recording. When `trimTrailingClick` is true the last click (on the Stop button) is removed.
    func stopRecording(trimTrailingClick: Bool = false) {
        guard state == .recording else { return }
        tap?.stop()
        tap = nil
        uiTimer?.invalidate()
        uiTimer = nil
        var recorded = buffer
        if trimTrailingClick, let index = recorded.lastIndex(where: { $0.kind == .mouseDown }) {
            recorded.removeSubrange(index...)
        }
        // Drop trailing modifier changes (e.g. from pressing a hotkey combination).
        while let last = recorded.last, last.kind == .flagsChanged {
            recorded.removeLast()
        }
        events = recorded
        buffer = []
        state = .idle
        liveCount = events.count
        if currentName.isEmpty || currentName.hasPrefix("Untitled") {
            currentName = "Macro \(library.count + 1)"
        }
        NSSound(named: "Pop")?.play()
    }

    private func record(type: CGEventType, event: CGEvent) {
        guard state == .recording else { return }
        if InputSynth.isSynthetic(event) { return }
        let location = event.location
        var e = MacroEvent(kind: .mouseMove,
                           time: ProcessInfo.processInfo.systemUptime - recordStart,
                           x: Double(location.x), y: Double(location.y))
        switch type {
        case .mouseMoved:
            guard settings.recordMouseMoves else { return }
            e.kind = .mouseMove
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            e.kind = .mouseDown
            e.button = type == .leftMouseDown ? 0 : (type == .rightMouseDown ? 1 : 2)
            e.clickCount = Int(event.getIntegerValueField(.mouseEventClickState))
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            e.kind = .mouseUp
            e.button = type == .leftMouseUp ? 0 : (type == .rightMouseUp ? 1 : 2)
            e.clickCount = Int(event.getIntegerValueField(.mouseEventClickState))
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            e.kind = .mouseDrag
            e.button = type == .leftMouseDragged ? 0 : (type == .rightMouseDragged ? 1 : 2)
        case .scrollWheel:
            e.kind = .scroll
            e.scrollY = Int(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1))
            e.scrollX = Int(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2))
            if e.scrollX == 0 && e.scrollY == 0 { return }
        case .keyDown, .keyUp:
            let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
            if ignoredKeys.contains(code) { return }
            e.kind = type == .keyDown ? .keyDown : .keyUp
            e.keyCode = code
            e.flags = event.flags.rawValue
        case .flagsChanged:
            e.kind = .flagsChanged
            e.keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
            e.flags = event.flags.rawValue
        default:
            return
        }
        buffer.append(e)
    }

    // MARK: Playback

    func togglePlayback() {
        if state == .playing { stopPlayback() } else { play() }
    }

    func play(_ macroEvents: [MacroEvent]? = nil) {
        guard state == .idle else { return }
        let list = macroEvents ?? events
        guard !list.isEmpty else {
            lastError = "Nothing to play. Record a macro or load one from the library first."
            NSSound.beep()
            return
        }
        guard Permissions.shared.ensureAccessibility() else {
            lastError = "Accessibility permission is required to replay macros."
            return
        }
        lastError = nil
        let token = CancelToken()
        playToken = token
        state = .playing
        progress = 0
        loopsDone = 0
        let s = settings
        let speed = max(0.05, s.speed)
        let total = max(list.last?.time ?? 0, 0.001)

        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            var heldKeys = Set<Int>()
            var heldButtons = Set<Int>()
            var lastUI = 0.0
            var loop = 0
            if s.startDelay > 0 { token.pause(s.startDelay) }
            outer: while !token.isCancelled && (s.repeatCount == 0 || loop < s.repeatCount) {
                let start = ProcessInfo.processInfo.systemUptime
                for event in list {
                    let target = start + event.time / speed
                    let wait = target - ProcessInfo.processInfo.systemUptime
                    if wait > 0 && !token.pause(wait) { break outer }
                    if token.isCancelled { break outer }
                    MacroEngine.post(event)
                    switch event.kind {
                    case .keyDown: heldKeys.insert(event.keyCode)
                    case .keyUp: heldKeys.remove(event.keyCode)
                    case .mouseDown: heldButtons.insert(event.button)
                    case .mouseUp: heldButtons.remove(event.button)
                    default: break
                    }
                    let now = ProcessInfo.processInfo.systemUptime
                    if now - lastUI > 0.1 {
                        lastUI = now
                        let p = event.time / total
                        DispatchQueue.main.async { self?.progress = p }
                    }
                }
                loop += 1
                let done = loop
                DispatchQueue.main.async { self?.loopsDone = done }
                if s.repeatCount == 0 || loop < s.repeatCount {
                    if !token.pause(s.loopDelay) { break outer }
                }
            }
            // Release anything still held so no key or button gets stuck.
            let location = InputSynth.cursorLocation
            for code in heldKeys { InputSynth.key(CGKeyCode(code), down: false) }
            for b in heldButtons {
                let button = MouseButtonKind.from(index: b)
                InputSynth.mouse(button.upType, button: button, at: location)
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                if self.playToken === token {
                    self.playToken = nil
                    self.state = .idle
                    self.progress = 1
                }
            }
        }
    }

    func stopPlayback() {
        playToken?.cancel()
        playToken = nil
        if state == .playing { state = .idle }
    }

    func stopEverything() {
        if state == .recording { stopRecording() }
        if state == .playing { stopPlayback() }
    }

    static func post(_ e: MacroEvent) {
        let point = CGPoint(x: e.x, y: e.y)
        let src = InputSynth.source
        switch e.kind {
        case .mouseMove:
            InputSynth.moveMouse(to: point)
        case .mouseDown, .mouseUp, .mouseDrag:
            let button = MouseButtonKind.from(index: e.button)
            let type: CGEventType
            switch e.kind {
            case .mouseDown: type = button.downType
            case .mouseUp: type = button.upType
            default: type = button.dragType
            }
            InputSynth.mouse(type, button: button, at: point, clickState: max(1, e.clickCount))
        case .scroll:
            let event = CGEvent(scrollWheelEvent2Source: src, units: .pixel, wheelCount: 2,
                                wheel1: Int32(clamping: e.scrollY), wheel2: Int32(clamping: e.scrollX), wheel3: 0)
            event?.location = point
            InputSynth.post(event)
        case .keyDown, .keyUp:
            let event = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(e.keyCode), keyDown: e.kind == .keyDown)
            event?.flags = CGEventFlags(rawValue: e.flags)
            InputSynth.post(event)
        case .flagsChanged:
            let event = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(e.keyCode), keyDown: true)
            event?.type = .flagsChanged
            event?.flags = CGEventFlags(rawValue: e.flags)
            InputSynth.post(event)
        }
    }

    // MARK: Library & editing

    func saveCurrent() {
        guard !events.isEmpty else { return }
        let name = currentName.trimmed.isEmpty ? "Macro \(library.count + 1)" : currentName.trimmed
        if let index = library.firstIndex(where: { $0.name == name }) {
            library[index].events = events
        } else {
            library.insert(SavedMacro(name: name, events: events), at: 0)
        }
        currentName = name
    }

    func load(_ macro: SavedMacro) {
        guard state == .idle else { return }
        events = macro.events
        currentName = macro.name
    }

    func delete(_ macro: SavedMacro) {
        library.removeAll { $0.id == macro.id }
    }

    func playMacro(named name: String) {
        if let macro = library.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            play(macro.events)
        } else {
            lastError = "No saved macro named “\(name)”."
        }
    }

    func removeMouseMoves() {
        events.removeAll { $0.kind == .mouseMove }
    }

    func removeEvent(at index: Int) {
        guard events.indices.contains(index) else { return }
        events.remove(at: index)
    }

    /// Removes long idle gaps so playback never waits more than `maxGap` seconds between events.
    func compressPauses(maxGap: Double = 1.0) {
        guard !events.isEmpty else { return }
        var shift = 0.0
        var previous = events[0].time
        var result: [MacroEvent] = []
        for var e in events {
            let gap = e.time - previous
            if gap > maxGap { shift += gap - maxGap }
            previous = e.time
            e.time -= shift
            result.append(e)
        }
        events = result
    }

    func exportCurrent() {
        guard !events.isEmpty, let url = Panels.saveFile(name: currentName + ".json", types: [.json]) else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        let macro = SavedMacro(name: currentName, events: events)
        if let data = try? encoder.encode(macro) {
            try? data.write(to: url)
        }
    }

    func importMacros() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for url in Panels.chooseFiles(multiple: true, types: [.json]) {
            guard let data = try? Data(contentsOf: url) else { continue }
            if var macro = try? decoder.decode(SavedMacro.self, from: data) {
                macro.id = UUID()
                library.insert(macro, at: 0)
            } else if let list = try? decoder.decode([SavedMacro].self, from: data) {
                let renamed = list.map { (m: SavedMacro) -> SavedMacro in
                    var copy = m
                    copy.id = UUID()
                    return copy
                }
                library.insert(contentsOf: renamed, at: 0)
            } else {
                lastError = "\(url.lastPathComponent) is not a MacTools macro file."
            }
        }
    }
}
