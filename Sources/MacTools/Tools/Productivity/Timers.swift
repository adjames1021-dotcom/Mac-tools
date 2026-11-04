import SwiftUI
import AppKit

final class TimerEngine: ObservableObject {
    static let shared = TimerEngine()

    // Stopwatch
    @Published private(set) var stopwatchStart: Date?
    @Published private(set) var stopwatchAccumulated: TimeInterval = 0
    @Published private(set) var laps: [TimeInterval] = []

    var stopwatchRunning: Bool { stopwatchStart != nil }
    var stopwatchElapsed: TimeInterval {
        stopwatchAccumulated + (stopwatchStart.map { Date().timeIntervalSince($0) } ?? 0)
    }

    func toggleStopwatch() {
        if let start = stopwatchStart {
            stopwatchAccumulated += Date().timeIntervalSince(start)
            stopwatchStart = nil
        } else {
            stopwatchStart = Date()
        }
    }

    func lap() { laps.insert(stopwatchElapsed, at: 0) }

    func resetStopwatch() {
        stopwatchStart = nil
        stopwatchAccumulated = 0
        laps = []
    }

    // Countdown
    @Published var countdownDuration: TimeInterval = 300
    @Published private(set) var countdownEnd: Date?
    @Published private(set) var countdownPaused: TimeInterval?
    @Published var countdownMessage = "Time's up!"
    @Published var countdownSpeak = true
    private var countdownTimer: Timer?

    var countdownRunning: Bool { countdownEnd != nil }
    var countdownRemaining: TimeInterval {
        if let end = countdownEnd { return max(0, end.timeIntervalSinceNow) }
        return countdownPaused ?? countdownDuration
    }

    func startCountdown() {
        let remaining = countdownPaused ?? countdownDuration
        guard remaining > 0 else { return }
        countdownPaused = nil
        countdownEnd = Date().addingTimeInterval(remaining)
        countdownTimer?.invalidate()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: remaining, repeats: false) { [weak self] _ in
            self?.countdownFinished()
        }
    }

    func pauseCountdown() {
        guard let end = countdownEnd else { return }
        countdownPaused = max(0, end.timeIntervalSinceNow)
        countdownEnd = nil
        countdownTimer?.invalidate()
        countdownTimer = nil
    }

    func resetCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        countdownEnd = nil
        countdownPaused = nil
    }

    private func countdownFinished() {
        countdownEnd = nil
        countdownPaused = nil
        countdownTimer = nil
        TimerEngine.alert(countdownMessage, speak: countdownSpeak)
    }

    // Pomodoro
    enum Phase: String {
        case idle = "Ready"
        case work = "Focus"
        case shortBreak = "Short Break"
        case longBreak = "Long Break"
    }

    @Published var workMinutes = 25
    @Published var shortBreakMinutes = 5
    @Published var longBreakMinutes = 15
    @Published var sessionsBeforeLongBreak = 4
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var phaseEnd: Date?
    @Published private(set) var completedSessions = 0
    private var pomodoroTimer: Timer?

    var phaseRemaining: TimeInterval {
        if let end = phaseEnd { return max(0, end.timeIntervalSinceNow) }
        return Double(workMinutes) * 60
    }

    var phaseTotal: TimeInterval {
        switch phase {
        case .idle, .work: return Double(workMinutes) * 60
        case .shortBreak: return Double(shortBreakMinutes) * 60
        case .longBreak: return Double(longBreakMinutes) * 60
        }
    }

    func startPomodoro() {
        begin(.work)
    }

    func skipPhase() {
        advancePhase(announce: false)
    }

    func stopPomodoro() {
        pomodoroTimer?.invalidate()
        pomodoroTimer = nil
        phase = .idle
        phaseEnd = nil
    }

    private func begin(_ newPhase: Phase) {
        phase = newPhase
        let seconds = phaseTotal
        phaseEnd = Date().addingTimeInterval(seconds)
        pomodoroTimer?.invalidate()
        pomodoroTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            self?.advancePhase(announce: true)
        }
    }

    private func advancePhase(announce: Bool) {
        switch phase {
        case .work:
            completedSessions += 1
            let long = completedSessions % max(1, sessionsBeforeLongBreak) == 0
            if announce { TimerEngine.alert(long ? "Great work! Take a long break." : "Time for a short break.", speak: true) }
            begin(long ? .longBreak : .shortBreak)
        case .shortBreak, .longBreak:
            if announce { TimerEngine.alert("Break's over. Back to focus!", speak: true) }
            begin(.work)
        case .idle:
            begin(.work)
        }
    }

    static func alert(_ message: String, speak: Bool) {
        NSSound(named: "Glass")?.play()
        Shell.notify(message)
        if speak {
            DispatchQueue.global(qos: .userInitiated).async {
                Shell.runSync("/usr/bin/say", [message])
            }
        }
        NSApp.requestUserAttention(.criticalRequest)
    }
}

struct TimersView: View {
    @ObservedObject private var engine = TimerEngine.shared
    @AppStorage("timersTab") private var tab = 0
    @State private var hours = 0
    @State private var minutes = 5
    @State private var seconds = 0

    var body: some View {
        ToolPage(tool: .timers) {
            Picker("", selection: $tab) {
                Text("Stopwatch").tag(0)
                Text("Countdown").tag(1)
                Text("Pomodoro").tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 420)

            switch tab {
            case 0: stopwatch
            case 1: countdown
            default: pomodoro
            }
        }
    }

    private func bigTime(_ value: TimeInterval, fraction: Bool) -> some View {
        Text(Format.duration(value, showFraction: fraction))
            .font(.system(size: 64, weight: .light, design: .rounded))
            .monospacedDigit()
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
    }

    private var stopwatch: some View {
        Card(title: "Stopwatch", icon: "stopwatch") {
            TimelineView(.periodic(from: .now, by: 0.05)) { _ in
                bigTime(engine.stopwatchElapsed, fraction: true)
            }
            HStack {
                Spacer()
                Button(engine.stopwatchRunning ? "Pause" : "Start") { engine.toggleStopwatch() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                Button("Lap") { engine.lap() }
                    .controlSize(.large)
                    .disabled(!engine.stopwatchRunning)
                Button("Reset") { engine.resetStopwatch() }
                    .controlSize(.large)
                Spacer()
            }
            if !engine.laps.isEmpty {
                Divider()
                ForEach(Array(engine.laps.enumerated()), id: \.offset) { item in
                    HStack {
                        Text("Lap \(engine.laps.count - item.offset)")
                        Spacer()
                        Text(Format.duration(item.element)).monospacedDigit()
                    }
                    .font(.callout)
                }
            }
        }
    }

    private var countdown: some View {
        Card(title: "Countdown Timer", icon: "timer") {
            TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                VStack {
                    bigTime(engine.countdownRemaining, fraction: false)
                    ProgressView(value: engine.countdownDuration > 0 ? 1 - engine.countdownRemaining / max(engine.countdownDuration, 1) : 0)
                }
            }
            if !engine.countdownRunning && engine.countdownPaused == nil {
                HStack(spacing: 16) {
                    Stepper("\(hours) h", value: $hours, in: 0...23)
                    Stepper("\(minutes) min", value: $minutes, in: 0...59)
                    Stepper("\(seconds) sec", value: $seconds, in: 0...59, step: 5)
                    Button("Set") { applyDuration() }
                }
                HStack {
                    Text("Presets:").foregroundStyle(.secondary)
                    ForEach([1, 3, 5, 10, 15, 25, 30, 45, 60], id: \.self) { m in
                        Button("\(m)m") {
                            hours = m / 60
                            minutes = m % 60
                            seconds = 0
                            applyDuration()
                        }
                    }
                }
            }
            HStack {
                TextField("Message when done", text: $engine.countdownMessage)
                    .textFieldStyle(.roundedBorder)
                Toggle("Speak it", isOn: $engine.countdownSpeak)
            }
            HStack {
                Spacer()
                if engine.countdownRunning {
                    Button("Pause") { engine.pauseCountdown() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                } else {
                    Button(engine.countdownPaused == nil ? "Start" : "Resume") {
                        if engine.countdownPaused == nil { applyDuration() }
                        engine.startCountdown()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                Button("Reset") { engine.resetCountdown() }
                    .controlSize(.large)
                Spacer()
            }
        }
        .onAppear {
            let total = Int(engine.countdownDuration)
            hours = total / 3600
            minutes = (total % 3600) / 60
            seconds = total % 60
        }
    }

    private func applyDuration() {
        let total = TimeInterval(hours * 3600 + minutes * 60 + seconds)
        if total > 0 && !engine.countdownRunning {
            engine.resetCountdown()
            engine.countdownDuration = total
        }
    }

    private var phaseColor: Color {
        switch engine.phase {
        case .work: return Color.red
        case .idle: return Color.secondary
        case .shortBreak, .longBreak: return Color.green
        }
    }

    private var pomodoro: some View {
        Card(title: "Pomodoro", icon: "leaf") {
            TimelineView(.periodic(from: .now, by: 0.2)) { _ in
                VStack(spacing: 6) {
                    Text(engine.phase.rawValue)
                        .font(.title2.bold())
                        .foregroundColor(phaseColor)
                    bigTime(engine.phase == .idle ? Double(engine.workMinutes) * 60 : engine.phaseRemaining, fraction: false)
                    ProgressView(value: engine.phase == .idle ? 0 : 1 - engine.phaseRemaining / max(engine.phaseTotal, 1))
                }
            }
            Text("Completed focus sessions: \(engine.completedSessions)")
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                if engine.phase == .idle {
                    Button("Start Focus") { engine.startPomodoro() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                } else {
                    Button("Skip") { engine.skipPhase() }.controlSize(.large)
                    Button("Stop") { engine.stopPomodoro() }.controlSize(.large)
                }
                Spacer()
            }
            Divider()
            HStack(spacing: 16) {
                Stepper("Focus \(engine.workMinutes) min", value: $engine.workMinutes, in: 1...120)
                Stepper("Break \(engine.shortBreakMinutes) min", value: $engine.shortBreakMinutes, in: 1...60)
                Stepper("Long break \(engine.longBreakMinutes) min", value: $engine.longBreakMinutes, in: 1...90)
                Stepper("Long break every \(engine.sessionsBeforeLongBreak)", value: $engine.sessionsBeforeLongBreak, in: 1...10)
            }
            .disabled(engine.phase != .idle)
        }
    }
}
