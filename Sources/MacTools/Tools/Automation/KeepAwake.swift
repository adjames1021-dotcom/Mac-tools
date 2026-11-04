import SwiftUI
import AppKit

final class KeepAwake: ObservableObject {
    static let shared = KeepAwake()

    @Published private(set) var isActive = false
    @Published var preventDisplaySleep = true
    @Published var durationMinutes: Int = 0      // 0 = indefinitely
    @Published private(set) var endsAt: Date?

    @Published private(set) var jiggling = false
    @Published var jiggleInterval: Double = 30
    @Published var jigglePixels: Double = 1
    @Published var invisibleJiggle = true
    @Published private(set) var jiggleCount = 0

    private var activity: NSObjectProtocol?
    private var endTimer: Timer?
    private var jiggleTimer: Timer?

    func toggle() {
        if isActive { stop() } else { start() }
    }

    func start() {
        stop()
        var options: ProcessInfo.ActivityOptions = [.idleSystemSleepDisabled, .userInitiated]
        if preventDisplaySleep { options.insert(.idleDisplaySleepDisabled) }
        activity = ProcessInfo.processInfo.beginActivity(options: options, reason: "MacTools Keep Awake")
        isActive = true
        if durationMinutes > 0 {
            let seconds = Double(durationMinutes) * 60
            endsAt = Date().addingTimeInterval(seconds)
            endTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
                self?.stop()
            }
        }
    }

    func stop() {
        if let activity = activity {
            ProcessInfo.processInfo.endActivity(activity)
        }
        activity = nil
        endTimer?.invalidate()
        endTimer = nil
        endsAt = nil
        isActive = false
    }

    func toggleJiggle() {
        if jiggling { stopJiggle() } else { startJiggle() }
    }

    func startJiggle() {
        stopJiggle()
        guard Permissions.shared.ensureAccessibility() else { return }
        jiggling = true
        jiggleCount = 0
        jiggleTimer = Timer.scheduledTimer(withTimeInterval: max(1, jiggleInterval), repeats: true) { [weak self] _ in
            self?.jiggle()
        }
    }

    func stopJiggle() {
        jiggleTimer?.invalidate()
        jiggleTimer = nil
        jiggling = false
    }

    private func jiggle() {
        let p = InputSynth.cursorLocation
        if invisibleJiggle {
            InputSynth.moveMouse(to: p)
        } else {
            let d = max(1, jigglePixels)
            InputSynth.moveMouse(to: CGPoint(x: p.x + d, y: p.y + d))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                InputSynth.moveMouse(to: p)
            }
        }
        jiggleCount += 1
    }
}

struct KeepAwakeView: View {
    @ObservedObject private var awake = KeepAwake.shared

    var body: some View {
        ToolPage(tool: .keepAwake) {
            Card(title: "Keep Awake (Caffeinate)", icon: "cup.and.saucer") {
                HStack(spacing: 12) {
                    Button {
                        awake.toggle()
                    } label: {
                        Label(awake.isActive ? "Allow Sleep" : "Keep Awake",
                              systemImage: awake.isActive ? "moon.zzz" : "sun.max")
                            .frame(minWidth: 140)
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .tint(awake.isActive ? Color.orange : Color.accentColor)
                    StatusBadge(active: awake.isActive, activeText: "Mac will stay awake", idleText: "Normal sleep")
                    if let end = awake.endsAt {
                        Text("until \(end.formatted(date: .omitted, time: .shortened))")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    HotKeyHint(action: .toggleKeepAwake)
                }
                Toggle("Also keep the display on", isOn: $awake.preventDisplaySleep)
                    .disabled(awake.isActive)
                Picker("Duration", selection: $awake.durationMinutes) {
                    Text("Indefinitely").tag(0)
                    Text("15 minutes").tag(15)
                    Text("30 minutes").tag(30)
                    Text("1 hour").tag(60)
                    Text("2 hours").tag(120)
                    Text("4 hours").tag(240)
                    Text("8 hours").tag(480)
                }
                .frame(maxWidth: 300)
                .disabled(awake.isActive)
            }

            Card(title: "Mouse Jiggler", icon: "computermouse") {
                PermissionBanner(needs: [.accessibility])
                HStack(spacing: 12) {
                    Button {
                        awake.toggleJiggle()
                    } label: {
                        Label(awake.jiggling ? "Stop Jiggling" : "Start Jiggling",
                              systemImage: awake.jiggling ? "stop.fill" : "play.fill")
                            .frame(minWidth: 140)
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .tint(awake.jiggling ? Color.red : Color.accentColor)
                    StatusBadge(active: awake.jiggling, activeText: "Jiggling (\(awake.jiggleCount))", idleText: "Off")
                }
                HStack(spacing: 20) {
                    NumberField(title: "Every", value: $awake.jiggleInterval, unit: "seconds")
                    NumberField(title: "Distance", value: $awake.jigglePixels, unit: "px")
                }
                .disabled(awake.jiggling)
                Toggle("Invisible (“zen”) jiggle – the cursor doesn't visibly move", isOn: $awake.invisibleJiggle)
                Text("Keeps chat apps showing you as active and stops screen savers that ignore sleep settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
