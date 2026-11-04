import SwiftUI
import AppKit

/// Swallows all keyboard input for a while so the keyboard can be cleaned.
final class KeyboardLock: ObservableObject {
    static let shared = KeyboardLock()

    @Published private(set) var locked = false
    @Published var autoUnlockSeconds: Double = 60
    @Published var blockTrackpadClicks = false
    @Published private(set) var remaining = 0
    @Published var lastError: String?

    private var tap: EventTap?
    private var timer: Timer?

    func lock() {
        guard !locked else { return }
        guard Permissions.shared.ensureAccessibility() else {
            lastError = "Accessibility permission is required to lock the keyboard."
            return
        }
        lastError = nil
        let blockClicks = blockTrackpadClicks
        let tap = EventTap(listenOnly: false) { type, event in
            // Let mouse movement through; block keys (and clicks if requested).
            if !blockClicks && (type == .leftMouseDown || type == .leftMouseUp) { return event }
            return nil
        }
        var types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged]
        if blockClicks {
            types += [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp, .scrollWheel]
        }
        let mask = EventTap.mask(types) | EventTap.systemDefinedMask
        guard tap.start(mask: mask) else {
            lastError = "Couldn't lock the keyboard. Check Accessibility permission."
            return
        }
        self.tap = tap
        locked = true
        // Never lock for longer than 10 minutes, as a safety net.
        remaining = Int(min(max(autoUnlockSeconds, 5), 600))
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.remaining -= 1
            if self.remaining <= 0 { self.unlock() }
        }
    }

    func unlock() {
        tap?.stop()
        tap = nil
        timer?.invalidate()
        timer = nil
        remaining = 0
        if locked { NSSound(named: "Glass")?.play() }
        locked = false
    }
}

struct KeyboardLockView: View {
    @ObservedObject private var lock = KeyboardLock.shared

    var body: some View {
        ToolPage(tool: .keyboardLock) {
            PermissionBanner(needs: [.accessibility])
            if let error = lock.lastError {
                Label(error, systemImage: "exclamationmark.circle").foregroundColor(.red)
            }
            Card(title: lock.locked ? "Keyboard Locked" : "Lock Keyboard", icon: lock.locked ? "lock.fill" : "lock.open") {
                if lock.locked {
                    VStack(spacing: 14) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 54))
                            .foregroundColor(.orange)
                        Text("Keyboard is locked – clean away!")
                            .font(.title2.bold())
                        Text("Unlocks automatically in \(lock.remaining) seconds")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Button {
                            lock.unlock()
                        } label: {
                            Label("Unlock Now", systemImage: "lock.open")
                                .frame(minWidth: 160)
                        }
                        .controlSize(.large)
                        .buttonStyle(.borderedProminent)
                        .disabled(lock.blockTrackpadClicks)
                        if lock.blockTrackpadClicks {
                            Text("Clicks are blocked too, so wait for the timer.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                } else {
                    Text("All key presses (including media keys) are ignored while locked. Use the mouse to click “Unlock Now”, or wait for the timer.")
                        .foregroundStyle(.secondary)
                    Picker("Auto-unlock after", selection: $lock.autoUnlockSeconds) {
                        Text("30 seconds").tag(30.0)
                        Text("1 minute").tag(60.0)
                        Text("2 minutes").tag(120.0)
                        Text("5 minutes").tag(300.0)
                        Text("10 minutes").tag(600.0)
                    }
                    .frame(maxWidth: 300)
                    Toggle("Also block clicks and scrolling (trackpad cleaning – waits for the timer)", isOn: $lock.blockTrackpadClicks)
                    Button {
                        lock.lock()
                    } label: {
                        Label("Lock Keyboard", systemImage: "lock.fill")
                            .frame(minWidth: 160)
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                }
            }
        }
    }
}
