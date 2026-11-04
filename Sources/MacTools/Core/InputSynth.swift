import AppKit
import CoreGraphics

enum MouseButtonKind: String, CaseIterable, Identifiable, Codable {
    case left, right, middle

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var cgButton: CGMouseButton {
        switch self {
        case .left: return .left
        case .right: return .right
        case .middle: return .center
        }
    }

    var downType: CGEventType {
        switch self {
        case .left: return .leftMouseDown
        case .right: return .rightMouseDown
        case .middle: return .otherMouseDown
        }
    }

    var upType: CGEventType {
        switch self {
        case .left: return .leftMouseUp
        case .right: return .rightMouseUp
        case .middle: return .otherMouseUp
        }
    }

    var dragType: CGEventType {
        switch self {
        case .left: return .leftMouseDragged
        case .right: return .rightMouseDragged
        case .middle: return .otherMouseDragged
        }
    }

    var index: Int {
        switch self {
        case .left: return 0
        case .right: return 1
        case .middle: return 2
        }
    }

    static func from(index: Int) -> MouseButtonKind {
        switch index {
        case 1: return .right
        case 2: return .middle
        default: return .left
        }
    }
}

/// Posts synthetic keyboard and mouse events. Requires Accessibility permission.
enum InputSynth {
    /// Value written into every synthetic event so our own recorders can ignore them.
    static let marker: Int64 = 0x4D54_4F4C
    static let source: CGEventSource? = CGEventSource(stateID: .hidSystemState)

    static func post(_ event: CGEvent?) {
        guard let event = event else { return }
        event.setIntegerValueField(.eventSourceUserData, value: marker)
        event.post(tap: .cghidEventTap)
    }

    static func isSynthetic(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == marker
    }

    /// Current cursor position in global display coordinates (origin at top-left of the main display).
    static var cursorLocation: CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    static func moveMouse(to point: CGPoint) {
        post(CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left))
    }

    static func mouse(_ type: CGEventType, button: MouseButtonKind, at point: CGPoint, clickState: Int = 1) {
        let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button.cgButton)
        event?.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
        post(event)
    }

    static func click(_ button: MouseButtonKind, at point: CGPoint? = nil, count: Int = 1, holdSeconds: Double = 0) {
        let p = point ?? cursorLocation
        for i in 1...max(1, count) {
            mouse(button.downType, button: button, at: p, clickState: i)
            if holdSeconds > 0 { Thread.sleep(forTimeInterval: holdSeconds) }
            mouse(button.upType, button: button, at: p, clickState: i)
        }
    }

    static func scroll(dx: Int32, dy: Int32) {
        post(CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0))
    }

    static func key(_ code: CGKeyCode, down: Bool, flags: CGEventFlags = []) {
        let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
        event?.flags = flags
        post(event)
    }

    static func press(_ code: CGKeyCode, flags: CGEventFlags = [], holdSeconds: Double = 0) {
        key(code, down: true, flags: flags)
        if holdSeconds > 0 { Thread.sleep(forTimeInterval: holdSeconds) }
        key(code, down: false, flags: flags)
    }

    static func press(_ combo: KeyCombo, holdSeconds: Double = 0) {
        press(CGKeyCode(combo.keyCode), flags: combo.cgFlags, holdSeconds: holdSeconds)
    }

    /// Types a single character using its Unicode value (works with any keyboard layout).
    static func typeCharacter(_ ch: Character) {
        if ch == "\n" || ch == "\r" || ch == "\r\n" {
            press(36)
            return
        }
        if ch == "\t" {
            press(48)
            return
        }
        let units = Array(String(ch).utf16)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
            event?.flags = []
            event?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            post(event)
        }
    }

    /// Types text character by character. Call from a background thread for long text.
    static func type(_ text: String, charDelay: Double = 0.005, token: CancelToken? = nil) {
        for ch in text {
            if let token = token, token.isCancelled { return }
            typeCharacter(ch)
            if charDelay > 0 {
                if let token = token {
                    if !token.pause(charDelay) { return }
                } else {
                    Thread.sleep(forTimeInterval: charDelay)
                }
            }
        }
    }

    /// Pastes text via the clipboard (⌘V), restoring the previous clipboard afterwards.
    static func paste(_ text: String) {
        let previous = onMain { ClipboardHelper.string }
        onMain { ClipboardHelper.copy(text) }
        Thread.sleep(forTimeInterval: 0.05)
        press(9, flags: .maskCommand) // V
        Thread.sleep(forTimeInterval: 0.25)
        if let previous = previous {
            onMain { ClipboardHelper.copy(previous) }
        }
    }

    /// Runs a closure on the main thread and returns its result.
    static func onMain<T>(_ work: () -> T) -> T {
        if Thread.isMainThread { return work() }
        return DispatchQueue.main.sync(execute: work)
    }
}

/// Wraps a Quartz event tap (used for macro recording and keyboard locking).
final class EventTap {
    typealias Handler = (CGEventType, CGEvent) -> CGEvent?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let handler: Handler
    private let listenOnly: Bool

    init(listenOnly: Bool, handler: @escaping Handler) {
        self.listenOnly = listenOnly
        self.handler = handler
    }

    deinit { stop() }

    var isRunning: Bool { tap != nil }

    static func mask(_ types: [CGEventType]) -> CGEventMask {
        types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
    }

    /// Mask bit for NX_SYSDEFINED events (media / brightness keys).
    static let systemDefinedMask: CGEventMask = CGEventMask(1) << 14

    func start(mask: CGEventMask) -> Bool {
        stop()
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<EventTap>.fromOpaque(refcon).takeUnretainedValue()
            return me.process(type: type, event: event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                          place: .headInsertEventTap,
                                          options: listenOnly ? .listenOnly : .defaultTap,
                                          eventsOfInterest: mask,
                                          callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            return false
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let tap = tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        tap = nil
        runLoopSource = nil
    }

    private func process(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if let result = handler(type, event) {
            return Unmanaged.passUnretained(result)
        }
        return nil
    }
}
