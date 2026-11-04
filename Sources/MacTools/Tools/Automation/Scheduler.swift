import SwiftUI
import AppKit

enum ActionType: String, Codable, CaseIterable, Identifiable {
    case notification, speak, openURL, openApp, shell, appleScript, playMacro
    case startAutoClicker, startAutoTyper, stopAll, keepAwakeOn, keepAwakeOff
    case sleepDisplay, sleepMac, lockScreen, shutDown, restart

    var id: String { rawValue }

    var title: String {
        switch self {
        case .notification: return "Show a notification"
        case .speak: return "Speak text aloud"
        case .openURL: return "Open a website / URL"
        case .openApp: return "Open an app"
        case .shell: return "Run a shell command"
        case .appleScript: return "Run an AppleScript"
        case .playMacro: return "Play a saved macro"
        case .startAutoClicker: return "Start the auto clicker"
        case .startAutoTyper: return "Start the auto typer"
        case .stopAll: return "Stop all automation"
        case .keepAwakeOn: return "Turn Keep Awake on"
        case .keepAwakeOff: return "Turn Keep Awake off"
        case .sleepDisplay: return "Turn off the display"
        case .sleepMac: return "Put the Mac to sleep"
        case .lockScreen: return "Lock the screen"
        case .shutDown: return "Shut down"
        case .restart: return "Restart"
        }
    }

    /// Placeholder for the argument field, or nil when no argument is needed.
    var argumentHint: String? {
        switch self {
        case .notification: return "Message"
        case .speak: return "Text to say"
        case .openURL: return "https://example.com"
        case .openApp: return "App name, e.g. Safari"
        case .shell: return "Command, e.g. say hello"
        case .appleScript: return "AppleScript source"
        case .playMacro: return "Macro name"
        default: return nil
        }
    }
}

enum ActionRunner {
    static func run(_ type: ActionType, argument: String) {
        let arg = argument.trimmed
        switch type {
        case .notification:
            Shell.notify(arg.isEmpty ? "Reminder" : arg)
            NSSound(named: "Glass")?.play()
        case .speak:
            let text = arg.isEmpty ? "Reminder" : arg
            DispatchQueue.global(qos: .userInitiated).async {
                Shell.runSync("/usr/bin/say", [text])
            }
        case .openURL:
            var text = arg
            if !text.contains("://") { text = "https://" + text }
            if let url = URL(string: text) { NSWorkspace.shared.open(url) }
        case .openApp:
            if arg.hasPrefix("/") {
                NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: arg), configuration: NSWorkspace.OpenConfiguration())
            } else {
                Shell.run("open -a \(arg.shellQuoted)")
            }
        case .shell:
            Shell.run(arg)
        case .appleScript:
            Shell.appleScript(arg)
        case .playMacro:
            MacroEngine.shared.playMacro(named: arg)
        case .startAutoClicker:
            AutoClicker.shared.start()
        case .startAutoTyper:
            AutoTyper.shared.start()
        case .stopAll:
            Automation.stopAll()
        case .keepAwakeOn:
            KeepAwake.shared.start()
        case .keepAwakeOff:
            KeepAwake.shared.stop()
        case .sleepDisplay:
            Shell.run("pmset displaysleepnow")
        case .sleepMac:
            Shell.run("pmset sleepnow")
        case .lockScreen:
            lockScreen()
        case .shutDown:
            Shell.appleScript("tell application \"System Events\" to shut down")
        case .restart:
            Shell.appleScript("tell application \"System Events\" to restart")
        }
    }

    static func lockScreen() {
        // ⌃⌘Q is the system "Lock Screen" shortcut.
        if Permissions.shared.accessibility {
            InputSynth.press(12, flags: [.maskControl, .maskCommand])
        } else {
            Shell.run("pmset displaysleepnow")
        }
    }
}

enum RepeatRule: String, Codable, CaseIterable, Identifiable {
    case once, everyMinutes, hourly, daily, weekdays, weekly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .once: return "Once"
        case .everyMinutes: return "Every N minutes"
        case .hourly: return "Every hour"
        case .daily: return "Every day"
        case .weekdays: return "Weekdays (Mon–Fri)"
        case .weekly: return "Every week"
        }
    }
}

struct ScheduledTask: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var action: ActionType
    var argument: String
    var nextRun: Date
    var rule: RepeatRule
    var intervalMinutes: Int = 30
    var enabled = true
    var lastRun: Date?
    var runCount = 0
}

final class TaskScheduler: ObservableObject {
    static let shared = TaskScheduler()

    @Published var tasks: [ScheduledTask] {
        didSet { DataStore.save(tasks, to: "schedule.json") }
    }
    @Published private(set) var log: [String] = []

    private var timer: Timer?

    private init() {
        tasks = DataStore.load([ScheduledTask].self, from: "schedule.json") ?? []
    }

    func start() {
        guard timer == nil else { return }
        // Skip occurrences that were missed while the app wasn't running.
        let now = Date()
        for i in tasks.indices where tasks[i].enabled && tasks[i].nextRun < now.addingTimeInterval(-60) {
            if tasks[i].rule == .once {
                tasks[i].enabled = false
            } else {
                tasks[i].nextRun = TaskScheduler.advance(tasks[i], from: tasks[i].nextRun, after: now)
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func tick() {
        let now = Date()
        for i in tasks.indices where tasks[i].enabled && tasks[i].nextRun <= now {
            let task = tasks[i]
            ActionRunner.run(task.action, argument: task.argument)
            tasks[i].lastRun = now
            tasks[i].runCount += 1
            if task.rule == .once {
                tasks[i].enabled = false
            } else {
                tasks[i].nextRun = TaskScheduler.advance(task, from: task.nextRun, after: now)
            }
            addLog("Ran “\(task.name)” – \(task.action.title)")
        }
    }

    func runNow(_ task: ScheduledTask) {
        ActionRunner.run(task.action, argument: task.argument)
        if let i = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[i].lastRun = Date()
            tasks[i].runCount += 1
        }
        addLog("Ran “\(task.name)” manually")
    }

    private func addLog(_ text: String) {
        let stamp = Date().formatted(date: .omitted, time: .standard)
        log.insert("\(stamp)  \(text)", at: 0)
        if log.count > 100 { log.removeLast(log.count - 100) }
    }

    static func advance(_ task: ScheduledTask, from date: Date, after now: Date) -> Date {
        let calendar = Calendar.current
        var next = date
        var guardCount = 0
        repeat {
            switch task.rule {
            case .once:
                return date
            case .everyMinutes:
                next = next.addingTimeInterval(Double(max(1, task.intervalMinutes)) * 60)
            case .hourly:
                next = next.addingTimeInterval(3600)
            case .daily:
                next = calendar.date(byAdding: .day, value: 1, to: next) ?? next.addingTimeInterval(86400)
            case .weekdays:
                repeat {
                    next = calendar.date(byAdding: .day, value: 1, to: next) ?? next.addingTimeInterval(86400)
                } while calendar.isDateInWeekend(next)
            case .weekly:
                next = calendar.date(byAdding: .day, value: 7, to: next) ?? next.addingTimeInterval(7 * 86400)
            }
            guardCount += 1
        } while next <= now && guardCount < 100_000
        if next <= now { next = now.addingTimeInterval(60) }
        return next
    }
}

struct SchedulerView: View {
    @ObservedObject private var scheduler = TaskScheduler.shared
    @ObservedObject private var macros = MacroEngine.shared

    @State private var name = "My task"
    @State private var action: ActionType = .notification
    @State private var argument = ""
    @State private var date = Date().addingTimeInterval(300)
    @State private var rule: RepeatRule = .once
    @State private var interval = 30

    var body: some View {
        ToolPage(tool: .scheduler) {
            Card(title: "New Scheduled Task", icon: "plus.circle") {
                HStack {
                    TextField("Name", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                    Picker("Action", selection: $action) {
                        ForEach(ActionType.allCases) { Text($0.title).tag($0) }
                    }
                    .frame(maxWidth: 320)
                }
                if let hint = action.argumentHint {
                    if action == .playMacro && !macros.library.isEmpty {
                        Picker("Macro", selection: $argument) {
                            Text("Choose…").tag("")
                            ForEach(macros.library) { Text($0.name).tag($0.name) }
                        }
                        .frame(maxWidth: 320)
                    } else if action == .appleScript || action == .shell {
                        CodeEditor(text: $argument, minHeight: 60)
                            .frame(height: 80)
                    } else {
                        TextField(hint, text: $argument)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                HStack(spacing: 16) {
                    DatePicker("First run", selection: $date)
                        .frame(maxWidth: 320)
                    Picker("Repeat", selection: $rule) {
                        ForEach(RepeatRule.allCases) { Text($0.title).tag($0) }
                    }
                    .frame(maxWidth: 260)
                    if rule == .everyMinutes {
                        Stepper("Every \(interval) min", value: $interval, in: 1...1440)
                    }
                }
                HStack {
                    Button("Add Task") {
                        let task = ScheduledTask(name: name.trimmed.isEmpty ? action.title : name.trimmed,
                                                 action: action, argument: argument,
                                                 nextRun: date, rule: rule, intervalMinutes: interval)
                        scheduler.tasks.append(task)
                        argument = ""
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Test Action Now") {
                        ActionRunner.run(action, argument: argument)
                    }
                    Spacer()
                    Text("Tasks only run while MacTools is open (it can stay in the menu bar).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Card(title: "Scheduled Tasks", icon: "calendar") {
                if scheduler.tasks.isEmpty {
                    Text("No tasks yet.").foregroundStyle(.secondary)
                }
                ForEach($scheduler.tasks) { $task in
                    HStack(alignment: .top, spacing: 10) {
                        Toggle("", isOn: $task.enabled).labelsHidden()
                        VStack(alignment: .leading, spacing: 2) {
                            Text(task.name).bold()
                            Text(task.action.title + (task.argument.isEmpty ? "" : ": " + task.argument))
                                .font(.caption)
                                .lineLimit(1)
                            Text(detail(for: task))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Run Now") { scheduler.runNow(task) }
                        Button(role: .destructive) {
                            scheduler.tasks.removeAll { $0.id == task.id }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                    Divider()
                }
            }

            if !scheduler.log.isEmpty {
                Card(title: "Activity", icon: "list.bullet.rectangle") {
                    OutputBox(text: scheduler.log.joined(separator: "\n"), minHeight: 60, maxHeight: 160)
                }
            }
        }
    }

    private func detail(for task: ScheduledTask) -> String {
        var parts: [String] = []
        if task.enabled {
            parts.append("Next: " + task.nextRun.formatted(date: .abbreviated, time: .shortened))
        } else {
            parts.append("Disabled")
        }
        parts.append(task.rule == .everyMinutes ? "every \(task.intervalMinutes) min" : task.rule.title)
        if let last = task.lastRun {
            parts.append("last ran " + last.formatted(date: .omitted, time: .shortened))
        }
        return parts.joined(separator: " · ")
    }
}
