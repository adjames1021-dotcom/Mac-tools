import AppKit
import Carbon

/// Thin wrapper around Carbon's RegisterEventHotKey (works without extra permissions).
final class HotKeyManager {
    static let shared = HotKeyManager()

    private var pressHandlers: [UInt32: () -> Void] = [:]
    private var releaseHandlers: [UInt32: () -> Void] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var nextID: UInt32 = 1
    private var eventHandler: EventHandlerRef?

    private init() {
        var specs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        InstallEventHandler(GetApplicationEventTarget(), { (_, event, _) -> OSStatus in
            guard let event = event else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event,
                                           EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID),
                                           nil,
                                           MemoryLayout<EventHotKeyID>.size,
                                           nil,
                                           &hotKeyID)
            if status == 0 {
                let id = hotKeyID.id
                let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
                DispatchQueue.main.async { HotKeyManager.shared.fire(id, pressed: pressed) }
            }
            return 0
        }, 2, &specs, nil, &eventHandler)
    }

    /// Registers a global hotkey. Returns an id (0 when registration failed).
    @discardableResult
    func register(_ combo: KeyCombo, onRelease: (() -> Void)? = nil, handler: @escaping () -> Void) -> UInt32 {
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4D544C53), id: id) // 'MTLS'
        let status = RegisterEventHotKey(UInt32(combo.keyCode), combo.carbonModifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == 0, let hotKeyRef = ref else { return 0 }
        refs[id] = hotKeyRef
        pressHandlers[id] = handler
        releaseHandlers[id] = onRelease
        return id
    }

    func unregister(_ id: UInt32) {
        if let ref = refs[id] { UnregisterEventHotKey(ref) }
        refs[id] = nil
        pressHandlers[id] = nil
        releaseHandlers[id] = nil
    }

    fileprivate func fire(_ id: UInt32, pressed: Bool) {
        if pressed {
            pressHandlers[id]?()
        } else {
            releaseHandlers[id]?()
        }
    }
}

enum HotKeyAction: String, CaseIterable, Identifiable {
    case toggleAutoClicker, captureClickPosition, toggleAutoTyper, toggleKeyPresser
    case toggleMacroRecording, toggleMacroPlayback, stopAll, toggleKeepAwake
    case winLeftHalf, winRightHalf, winTopHalf, winBottomHalf, winMaximize, winAlmostMaximize, winCenter
    case winTopLeft, winTopRight, winBottomLeft, winBottomRight
    case winLeftThird, winCenterThird, winRightThird, winLeftTwoThirds, winRightTwoThirds, winNextDisplay

    var id: String { rawValue }

    var windowAction: WindowAction? {
        switch self {
        case .winLeftHalf: return .leftHalf
        case .winRightHalf: return .rightHalf
        case .winTopHalf: return .topHalf
        case .winBottomHalf: return .bottomHalf
        case .winMaximize: return .maximize
        case .winAlmostMaximize: return .almostMaximize
        case .winCenter: return .center
        case .winTopLeft: return .topLeft
        case .winTopRight: return .topRight
        case .winBottomLeft: return .bottomLeft
        case .winBottomRight: return .bottomRight
        case .winLeftThird: return .leftThird
        case .winCenterThird: return .centerThird
        case .winRightThird: return .rightThird
        case .winLeftTwoThirds: return .leftTwoThirds
        case .winRightTwoThirds: return .rightTwoThirds
        case .winNextDisplay: return .nextDisplay
        default: return nil
        }
    }

    var title: String {
        if let w = windowAction { return "Window: " + w.title }
        switch self {
        case .toggleAutoClicker: return "Start / stop Auto Clicker"
        case .captureClickPosition: return "Auto Clicker: capture mouse position"
        case .toggleAutoTyper: return "Start / stop Auto Typer"
        case .toggleKeyPresser: return "Start / stop Key Presser"
        case .toggleMacroRecording: return "Start / stop macro recording"
        case .toggleMacroPlayback: return "Play / stop macro"
        case .stopAll: return "Stop ALL automation"
        case .toggleKeepAwake: return "Toggle Keep Awake"
        default: return rawValue
        }
    }

    var defaultCombo: KeyCombo? {
        switch self {
        case .toggleAutoClicker: return KeyCombo(keyCode: 97)          // F6
        case .captureClickPosition: return KeyCombo(keyCode: 96)       // F5
        case .toggleAutoTyper: return KeyCombo(keyCode: 98)            // F7
        case .toggleKeyPresser: return KeyCombo(keyCode: 100)          // F8
        case .toggleMacroRecording: return KeyCombo(keyCode: 101)      // F9
        case .toggleMacroPlayback: return KeyCombo(keyCode: 109)       // F10
        case .stopAll: return KeyCombo(keyCode: 111)                   // F12
        case .toggleKeepAwake: return nil
        case .winLeftHalf: return KeyCombo(keyCode: 123, option: true, control: true)
        case .winRightHalf: return KeyCombo(keyCode: 124, option: true, control: true)
        case .winTopHalf: return KeyCombo(keyCode: 126, option: true, control: true)
        case .winBottomHalf: return KeyCombo(keyCode: 125, option: true, control: true)
        case .winMaximize: return KeyCombo(keyCode: 36, option: true, control: true)
        case .winAlmostMaximize: return nil
        case .winCenter: return KeyCombo(keyCode: 8, option: true, control: true)        // C
        case .winTopLeft: return KeyCombo(keyCode: 32, option: true, control: true)      // U
        case .winTopRight: return KeyCombo(keyCode: 34, option: true, control: true)     // I
        case .winBottomLeft: return KeyCombo(keyCode: 38, option: true, control: true)   // J
        case .winBottomRight: return KeyCombo(keyCode: 40, option: true, control: true)  // K
        case .winLeftThird: return KeyCombo(keyCode: 2, option: true, control: true)     // D
        case .winCenterThird: return KeyCombo(keyCode: 3, option: true, control: true)   // F
        case .winRightThird: return KeyCombo(keyCode: 5, option: true, control: true)    // G
        case .winLeftTwoThirds: return KeyCombo(keyCode: 14, option: true, control: true) // E
        case .winRightTwoThirds: return KeyCombo(keyCode: 17, option: true, control: true) // T
        case .winNextDisplay: return KeyCombo(keyCode: 124, command: true, option: true, control: true)
        }
    }
}

/// Stores the user's hotkey bindings and keeps them registered.
final class HotKeyCenter: ObservableObject {
    static let shared = HotKeyCenter()

    @Published private(set) var bindings: [String: KeyCombo]
    @Published var windowHotkeysEnabled: Bool {
        didSet {
            UserDefaults.standard.set(windowHotkeysEnabled, forKey: "windowHotkeysEnabled")
            registerAll()
        }
    }
    @Published private(set) var failed: Set<String> = []

    private var registered: [UInt32] = []
    private var suspended = false

    private init() {
        var defaults: [String: KeyCombo] = [:]
        for action in HotKeyAction.allCases {
            if let combo = action.defaultCombo { defaults[action.rawValue] = combo }
        }
        bindings = Prefs.load("hotkeyBindings", default: defaults)
        if UserDefaults.standard.object(forKey: "windowHotkeysEnabled") == nil {
            windowHotkeysEnabled = true
        } else {
            windowHotkeysEnabled = UserDefaults.standard.bool(forKey: "windowHotkeysEnabled")
        }
    }

    func combo(for action: HotKeyAction) -> KeyCombo? { bindings[action.rawValue] }

    func displayString(for action: HotKeyAction) -> String {
        combo(for: action)?.displayString ?? "—"
    }

    func set(_ combo: KeyCombo?, for action: HotKeyAction) {
        bindings[action.rawValue] = combo
        Prefs.save("hotkeyBindings", bindings)
        registerAll()
    }

    func restoreDefaults() {
        var defaults: [String: KeyCombo] = [:]
        for action in HotKeyAction.allCases {
            if let combo = action.defaultCombo { defaults[action.rawValue] = combo }
        }
        bindings = defaults
        Prefs.save("hotkeyBindings", bindings)
        registerAll()
    }

    /// Key codes used by automation hotkeys (filtered out of macro recordings).
    var automationKeyCodes: Set<Int> {
        let actions: [HotKeyAction] = [.toggleMacroRecording, .toggleMacroPlayback, .stopAll,
                                       .toggleAutoClicker, .captureClickPosition, .toggleAutoTyper, .toggleKeyPresser]
        return Set(actions.compactMap { combo(for: $0).map { Int($0.keyCode) } })
    }

    /// Temporarily removes all hotkeys (used while the user records a new shortcut).
    func suspend() {
        suspended = true
        unregisterAll()
    }

    func resume() {
        suspended = false
        registerAll()
    }

    func registerAll() {
        unregisterAll()
        if suspended { return }
        var failures: Set<String> = []
        for action in HotKeyAction.allCases {
            if action.windowAction != nil && !windowHotkeysEnabled { continue }
            guard let combo = combo(for: action) else { continue }
            let id = HotKeyManager.shared.register(combo, onRelease: { [weak self] in
                self?.release(action)
            }, handler: { [weak self] in
                self?.perform(action)
            })
            if id == 0 {
                failures.insert(action.rawValue)
            } else {
                registered.append(id)
            }
        }
        failed = failures
    }

    private func unregisterAll() {
        for id in registered { HotKeyManager.shared.unregister(id) }
        registered.removeAll()
    }

    func perform(_ action: HotKeyAction) {
        if let windowAction = action.windowAction {
            WindowManager.shared.perform(windowAction, onFrontmost: true)
            return
        }
        switch action {
        case .toggleAutoClicker: AutoClicker.shared.hotkeyPressed()
        case .captureClickPosition: AutoClicker.shared.captureMousePosition()
        case .toggleAutoTyper: AutoTyper.shared.toggle()
        case .toggleKeyPresser: KeyPresser.shared.toggle()
        case .toggleMacroRecording: MacroEngine.shared.toggleRecording()
        case .toggleMacroPlayback: MacroEngine.shared.togglePlayback()
        case .stopAll: Automation.stopAll()
        case .toggleKeepAwake: KeepAwake.shared.toggle()
        default: break
        }
    }

    /// Called when a hotkey is let go (used for hold-to-click).
    func release(_ action: HotKeyAction) {
        if action == .toggleAutoClicker { AutoClicker.shared.hotkeyReleased() }
    }
}
