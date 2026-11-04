import AppKit
import Carbon
import CoreGraphics

/// A key plus modifier keys, used for hotkeys and the key presser.
struct KeyCombo: Codable, Equatable, Hashable {
    var keyCode: UInt16
    var command = false
    var option = false
    var control = false
    var shift = false

    init(keyCode: UInt16, command: Bool = false, option: Bool = false, control: Bool = false, shift: Bool = false) {
        self.keyCode = keyCode
        self.command = command
        self.option = option
        self.control = control
        self.shift = shift
    }

    init(event: NSEvent) {
        keyCode = event.keyCode
        let flags = event.modifierFlags
        command = flags.contains(.command)
        option = flags.contains(.option)
        control = flags.contains(.control)
        shift = flags.contains(.shift)
    }

    var hasModifiers: Bool { command || option || control || shift }

    var modifierSymbols: String {
        var s = ""
        if control { s += "⌃" }
        if option { s += "⌥" }
        if shift { s += "⇧" }
        if command { s += "⌘" }
        return s
    }

    var displayString: String { modifierSymbols + KeyNames.name(for: keyCode) }

    var carbonModifiers: UInt32 {
        var m: UInt32 = 0
        if command { m |= UInt32(cmdKey) }
        if option { m |= UInt32(optionKey) }
        if control { m |= UInt32(controlKey) }
        if shift { m |= UInt32(shiftKey) }
        return m
    }

    var cgFlags: CGEventFlags {
        var f: CGEventFlags = []
        if command { f.insert(.maskCommand) }
        if option { f.insert(.maskAlternate) }
        if control { f.insert(.maskControl) }
        if shift { f.insert(.maskShift) }
        return f
    }
}

enum KeyNames {
    static let names: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2",
        20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8",
        29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "Return",
        37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N",
        46: "M", 47: ".", 48: "Tab", 49: "Space", 50: "`", 51: "Delete", 53: "Esc",
        54: "Right ⌘", 55: "⌘", 56: "⇧", 57: "Caps Lock", 58: "⌥", 59: "⌃", 60: "Right ⇧",
        61: "Right ⌥", 62: "Right ⌃", 63: "fn",
        64: "F17", 65: "Keypad .", 67: "Keypad *", 69: "Keypad +", 71: "Clear", 75: "Keypad /",
        76: "Enter", 78: "Keypad -", 79: "F18", 80: "F19", 81: "Keypad =", 82: "Keypad 0",
        83: "Keypad 1", 84: "Keypad 2", 85: "Keypad 3", 86: "Keypad 4", 87: "Keypad 5",
        88: "Keypad 6", 89: "Keypad 7", 90: "F20", 91: "Keypad 8", 92: "Keypad 9",
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11",
        105: "F13", 106: "F16", 107: "F14", 109: "F10", 111: "F12", 113: "F15",
        114: "Help", 115: "Home", 116: "Page Up", 117: "Fwd Delete", 118: "F4", 119: "End",
        120: "F2", 121: "Page Down", 122: "F1", 123: "←", 124: "→", 125: "↓", 126: "↑"
    ]

    static let modifierKeyCodes: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]

    static func name(for code: UInt16) -> String {
        names[code] ?? "Key \(code)"
    }

    /// Keys that can be picked from a menu (non-modifier keys, sorted sensibly).
    static var selectableKeys: [(code: UInt16, name: String)] {
        names.filter { !modifierKeyCodes.contains($0.key) }
            .map { (code: $0.key, name: $0.value) }
            .sorted { a, b in
                if a.name.count != b.name.count && (a.name.count == 1 || b.name.count == 1) {
                    return a.name.count < b.name.count
                }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
    }

    static func modifierString(_ flags: CGEventFlags) -> String {
        var s = ""
        if flags.contains(.maskControl) { s += "⌃" }
        if flags.contains(.maskAlternate) { s += "⌥" }
        if flags.contains(.maskShift) { s += "⇧" }
        if flags.contains(.maskCommand) { s += "⌘" }
        if flags.contains(.maskSecondaryFn) { s += "fn" }
        return s
    }
}
