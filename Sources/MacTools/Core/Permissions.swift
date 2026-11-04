import AppKit
import ApplicationServices
import CoreGraphics

enum PermissionKind: String, CaseIterable, Identifiable {
    case accessibility, inputMonitoring, screenRecording

    var id: String { rawValue }

    var title: String {
        switch self {
        case .accessibility: return "Accessibility"
        case .inputMonitoring: return "Input Monitoring"
        case .screenRecording: return "Screen Recording"
        }
    }

    var explanation: String {
        switch self {
        case .accessibility: return "Needed to click, type, press keys, move windows and expand text."
        case .inputMonitoring: return "Needed to record your keyboard and mouse for macros."
        case .screenRecording: return "Needed for screenshots that include other apps' windows."
        }
    }

    var settingsAnchor: String {
        switch self {
        case .accessibility: return "Privacy_Accessibility"
        case .inputMonitoring: return "Privacy_ListenEvent"
        case .screenRecording: return "Privacy_ScreenCapture"
        }
    }
}

final class Permissions: ObservableObject {
    static let shared = Permissions()

    @Published private(set) var accessibility = false
    @Published private(set) var inputMonitoring = false
    @Published private(set) var screenRecording = false

    private var timer: Timer?

    private init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        let a = AXIsProcessTrusted()
        let i = CGPreflightListenEventAccess()
        let s = CGPreflightScreenCaptureAccess()
        if a != accessibility { accessibility = a }
        if i != inputMonitoring { inputMonitoring = i }
        if s != screenRecording { screenRecording = s }
    }

    func isGranted(_ kind: PermissionKind) -> Bool {
        switch kind {
        case .accessibility: return accessibility
        case .inputMonitoring: return inputMonitoring
        case .screenRecording: return screenRecording
        }
    }

    func request(_ kind: PermissionKind) {
        switch kind {
        case .accessibility:
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        case .inputMonitoring:
            if !CGRequestListenEventAccess() { openSettings(kind) }
        case .screenRecording:
            if !CGRequestScreenCaptureAccess() { openSettings(kind) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.refresh() }
    }

    func openSettings(_ kind: PermissionKind) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(kind.settingsAnchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Returns true when Accessibility is granted, otherwise shows the system prompt.
    @discardableResult
    func ensureAccessibility() -> Bool {
        refresh()
        if accessibility { return true }
        request(.accessibility)
        return false
    }

    /// Clears stale permission entries (needed after the app is rebuilt, because the signature changes).
    func resetAll() {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.mactools.toolbox"
        for service in ["Accessibility", "ListenEvent", "PostEvent", "ScreenCapture", "AppleEvents"] {
            Shell.runSync("/usr/bin/tccutil", ["reset", service, bundleID])
        }
        refresh()
    }
}
