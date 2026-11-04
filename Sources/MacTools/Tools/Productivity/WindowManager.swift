import SwiftUI
import AppKit
import ApplicationServices

enum WindowAction: String, CaseIterable, Identifiable {
    case leftHalf, rightHalf, topHalf, bottomHalf
    case maximize, almostMaximize, center
    case topLeft, topRight, bottomLeft, bottomRight
    case leftThird, centerThird, rightThird, leftTwoThirds, rightTwoThirds
    case nextDisplay

    var id: String { rawValue }

    var title: String {
        switch self {
        case .leftHalf: return "Left Half"
        case .rightHalf: return "Right Half"
        case .topHalf: return "Top Half"
        case .bottomHalf: return "Bottom Half"
        case .maximize: return "Maximize"
        case .almostMaximize: return "Almost Maximize"
        case .center: return "Center"
        case .topLeft: return "Top Left"
        case .topRight: return "Top Right"
        case .bottomLeft: return "Bottom Left"
        case .bottomRight: return "Bottom Right"
        case .leftThird: return "Left Third"
        case .centerThird: return "Center Third"
        case .rightThird: return "Right Third"
        case .leftTwoThirds: return "Left Two Thirds"
        case .rightTwoThirds: return "Right Two Thirds"
        case .nextDisplay: return "Next Display"
        }
    }

    /// Normalised rectangle (0…1) inside the screen's visible area, origin at top-left.
    var unitRect: CGRect? {
        switch self {
        case .leftHalf: return CGRect(x: 0, y: 0, width: 0.5, height: 1)
        case .rightHalf: return CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        case .topHalf: return CGRect(x: 0, y: 0, width: 1, height: 0.5)
        case .bottomHalf: return CGRect(x: 0, y: 0.5, width: 1, height: 0.5)
        case .maximize: return CGRect(x: 0, y: 0, width: 1, height: 1)
        case .almostMaximize: return CGRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9)
        case .topLeft: return CGRect(x: 0, y: 0, width: 0.5, height: 0.5)
        case .topRight: return CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5)
        case .bottomLeft: return CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5)
        case .bottomRight: return CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)
        case .leftThird: return CGRect(x: 0, y: 0, width: 1.0 / 3, height: 1)
        case .centerThird: return CGRect(x: 1.0 / 3, y: 0, width: 1.0 / 3, height: 1)
        case .rightThird: return CGRect(x: 2.0 / 3, y: 0, width: 1.0 / 3, height: 1)
        case .leftTwoThirds: return CGRect(x: 0, y: 0, width: 2.0 / 3, height: 1)
        case .rightTwoThirds: return CGRect(x: 1.0 / 3, y: 0, width: 2.0 / 3, height: 1)
        case .center, .nextDisplay: return nil
        }
    }

    var icon: String {
        switch self {
        case .leftHalf: return "rectangle.lefthalf.filled"
        case .rightHalf: return "rectangle.righthalf.filled"
        case .topHalf: return "rectangle.tophalf.filled"
        case .bottomHalf: return "rectangle.bottomhalf.filled"
        case .maximize: return "rectangle.fill"
        case .almostMaximize: return "rectangle.inset.filled"
        case .center: return "rectangle.center.inset.filled"
        case .topLeft: return "rectangle.inset.topleft.filled"
        case .topRight: return "rectangle.inset.topright.filled"
        case .bottomLeft: return "rectangle.inset.bottomleft.filled"
        case .bottomRight: return "rectangle.inset.bottomright.filled"
        case .leftThird: return "rectangle.leftthird.inset.filled"
        case .centerThird: return "rectangle.split.3x1"
        case .rightThird: return "rectangle.rightthird.inset.filled"
        case .leftTwoThirds: return "rectangle.split.2x1"
        case .rightTwoThirds: return "rectangle.split.2x1.fill"
        case .nextDisplay: return "display.2"
        }
    }
}

final class WindowManager: ObservableObject {
    static let shared = WindowManager()

    @Published private(set) var lastExternalApp: NSRunningApplication?
    @Published var gap: Double {
        didSet { UserDefaults.standard.set(gap, forKey: "windowGap") }
    }
    @Published var lastError: String?

    private var observer: NSObjectProtocol?

    private init() {
        gap = UserDefaults.standard.object(forKey: "windowGap") as? Double ?? 0
    }

    func startTracking() {
        guard observer == nil else { return }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != ownPID {
            lastExternalApp = front
        }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            if app.processIdentifier != ownPID { self?.lastExternalApp = app }
        }
    }

    /// Moves the focused window. With `onFrontmost` it acts on the active app (hotkeys),
    /// otherwise on the last app that was active before MacTools (buttons).
    func perform(_ action: WindowAction, onFrontmost: Bool) {
        guard Permissions.shared.ensureAccessibility() else {
            lastError = "Accessibility permission is required to move windows."
            return
        }
        let target = onFrontmost ? NSWorkspace.shared.frontmostApplication : (lastExternalApp ?? NSWorkspace.shared.frontmostApplication)
        guard let app = target, let window = WindowManager.focusedWindow(of: app),
              let current = WindowManager.frame(of: window) else {
            lastError = "Couldn't find a window to move. Click the window you want first."
            NSSound.beep()
            return
        }
        lastError = nil
        var screen = WindowManager.screen(containing: current)
        if action == .nextDisplay {
            let screens = NSScreen.screens
            if let index = screens.firstIndex(of: screen), screens.count > 1 {
                screen = screens[(index + 1) % screens.count]
            }
        }
        let area = WindowManager.axVisibleFrame(of: screen)
        var target_: CGRect
        if let unit = action.unitRect {
            target_ = CGRect(x: area.minX + unit.minX * area.width,
                             y: area.minY + unit.minY * area.height,
                             width: unit.width * area.width,
                             height: unit.height * area.height)
            if gap > 0 { target_ = target_.insetBy(dx: gap / 2, dy: gap / 2) }
        } else {
            let size = CGSize(width: min(current.width, area.width), height: min(current.height, area.height))
            target_ = CGRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2,
                             width: size.width, height: size.height)
        }
        WindowManager.setFrame(window, target_)
        if !onFrontmost { app.activate(options: []) }
    }

    // MARK: Accessibility helpers

    static func focusedWindow(of app: NSRunningApplication) -> AXUIElement? {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &value) == .success, let v = value {
            return (v as! AXUIElement)
        }
        if AXUIElementCopyAttributeValue(element, kAXMainWindowAttribute as CFString, &value) == .success, let v = value {
            return (v as! AXUIElement)
        }
        if AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success,
           let windows = value as? [AXUIElement], let first = windows.first {
            return first
        }
        return nil
    }

    static func frame(of window: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posValue = posRef, let sizeValue = sizeRef else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posValue as! AXValue, .cgPoint, &position)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        return CGRect(origin: position, size: size)
    }

    static func setFrame(_ window: AXUIElement, _ rect: CGRect) {
        var position = rect.origin
        var size = rect.size
        // Set size, then position, then size again – some apps clamp size to the current screen.
        if let sizeValue = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        }
        if let posValue = AXValueCreate(.cgPoint, &position) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, posValue)
        }
        if let sizeValue = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        }
    }

    /// Height of the primary display, used to flip between Cocoa and Quartz coordinates.
    static var primaryHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? 0
    }

    /// Visible frame (minus menu bar and Dock) in top-left-origin coordinates.
    static func axVisibleFrame(of screen: NSScreen) -> CGRect {
        let v = screen.visibleFrame
        return CGRect(x: v.minX, y: primaryHeight - v.maxY, width: v.width, height: v.height)
    }

    static func screen(containing axRect: CGRect) -> NSScreen {
        let center = CGPoint(x: axRect.midX, y: primaryHeight - axRect.midY)
        return NSScreen.screens.first(where: { $0.frame.contains(center) })
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }
}

struct WindowManagerView: View {
    @ObservedObject private var manager = WindowManager.shared
    @ObservedObject private var hotkeys = HotKeyCenter.shared

    private let groups: [(String, [WindowAction])] = [
        ("Halves", [.leftHalf, .rightHalf, .topHalf, .bottomHalf]),
        ("Quarters", [.topLeft, .topRight, .bottomLeft, .bottomRight]),
        ("Thirds", [.leftThird, .centerThird, .rightThird, .leftTwoThirds, .rightTwoThirds]),
        ("Other", [.maximize, .almostMaximize, .center, .nextDisplay])
    ]

    var body: some View {
        ToolPage(tool: .windowManager) {
            PermissionBanner(needs: [.accessibility])
            if let error = manager.lastError {
                Label(error, systemImage: "exclamationmark.circle").foregroundColor(.red)
            }

            Card(title: "Move a Window", icon: "macwindow") {
                HStack {
                    Text("Target:").foregroundStyle(.secondary)
                    if let app = manager.lastExternalApp {
                        if let icon = app.icon {
                            Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                        }
                        Text(app.localizedName ?? "Unknown app").bold()
                    } else {
                        Text("Click on another app's window first").foregroundStyle(.secondary)
                    }
                    Spacer()
                    HStack {
                        Text("Gap between windows")
                        Slider(value: $manager.gap, in: 0...40, step: 2).frame(width: 140)
                        Text("\(Int(manager.gap)) px").monospacedDigit().frame(width: 44)
                    }
                }
                ForEach(groups, id: \.0) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(group.0).font(.subheadline).foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            ForEach(group.1) { action in
                                Button {
                                    manager.perform(action, onFrontmost: false)
                                } label: {
                                    VStack(spacing: 4) {
                                        Image(systemName: action.icon).font(.title2)
                                        Text(action.title).font(.caption)
                                    }
                                    .frame(width: 104, height: 54)
                                }
                            }
                        }
                    }
                }
            }

            Card(title: "Keyboard Shortcuts", icon: "keyboard") {
                Toggle("Enable window hotkeys (work in any app)", isOn: $hotkeys.windowHotkeysEnabled)
                    .toggleStyle(.switch)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), alignment: .leading)], alignment: .leading, spacing: 6) {
                    ForEach(HotKeyAction.allCases.filter { $0.windowAction != nil }) { action in
                        HStack {
                            Text(action.windowAction?.title ?? "")
                            Spacer()
                            Text(hotkeys.displayString(for: action))
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8)
                    }
                }
                Text("Change these in Permissions & Hotkeys.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
