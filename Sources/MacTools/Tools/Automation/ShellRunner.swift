import SwiftUI
import AppKit

struct SavedCommand: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var command: String
    var isAppleScript = false
}

final class SavedCommandStore: ObservableObject {
    static let shared = SavedCommandStore()

    @Published var commands: [SavedCommand] {
        didSet { DataStore.save(commands, to: "commands.json") }
    }

    private init() {
        commands = DataStore.load([SavedCommand].self, from: "commands.json") ?? [
            SavedCommand(name: "Disk space", command: "df -h /"),
            SavedCommand(name: "Top CPU processes", command: "ps -Ao pid,pcpu,pmem,comm -r | head -15"),
            SavedCommand(name: "macOS version", command: "sw_vers"),
            SavedCommand(name: "Wi-Fi IP address", command: "ipconfig getifaddr en0"),
            SavedCommand(name: "Say hello", command: "say 'Hello from Mac Tools'"),
            SavedCommand(name: "Frontmost app name", command: "tell application \"System Events\" to get name of first application process whose frontmost is true", isAppleScript: true),
            SavedCommand(name: "Show a dialog", command: "display dialog \"Hello from MacTools!\" buttons {\"OK\"}", isAppleScript: true)
        ]
    }
}

struct ShellRunnerView: View {
    @StateObject private var runner = CommandRunner()
    @ObservedObject private var store = SavedCommandStore.shared
    @AppStorage("shellRunnerCommand") private var command = "echo \"Hello from $SHELL\" && date"
    @AppStorage("shellRunnerIsAppleScript") private var isAppleScript = false
    @State private var saveName = ""

    var body: some View {
        ToolPage(tool: .shellRunner) {
            Card(title: "Command", icon: "terminal") {
                Picker("Language", selection: $isAppleScript) {
                    Text("Shell (zsh)").tag(false)
                    Text("AppleScript").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 300)
                CodeEditor(text: $command, minHeight: 90)
                    .frame(height: 110)
                HStack {
                    Button {
                        if isAppleScript { runner.runAppleScript(command) } else { runner.runShell(command) }
                    } label: {
                        Label("Run", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(command.trimmed.isEmpty)
                    Button {
                        runner.stop()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .disabled(!runner.running)
                    Button("Open in Terminal") { openInTerminal() }
                        .disabled(isAppleScript || command.trimmed.isEmpty)
                    Spacer()
                    TextField("Name to save as", text: $saveName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                    Button("Save") {
                        let name = saveName.trimmed.isEmpty ? String(command.prefix(30)) : saveName.trimmed
                        store.commands.insert(SavedCommand(name: name, command: command, isAppleScript: isAppleScript), at: 0)
                        saveName = ""
                    }
                    .disabled(command.trimmed.isEmpty)
                }
                Text("⌘↩ runs the command. Commands run as you, with your login shell environment.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Card(title: "Output", icon: "text.alignleft") {
                HStack {
                    StatusBadge(active: runner.running, activeText: "Running…", idleText: runner.lastStatus.map { "Exit code \($0)" } ?? "Idle")
                    Spacer()
                    CopyButton(text: runner.output)
                    Button("Clear") { runner.clear() }
                }
                OutputBox(text: runner.output, minHeight: 180, maxHeight: 400)
            }

            Card(title: "Saved Commands", icon: "star") {
                ForEach(store.commands) { saved in
                    HStack {
                        Image(systemName: saved.isAppleScript ? "applescript" : "terminal")
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                        VStack(alignment: .leading) {
                            Text(saved.name).bold()
                            Text(saved.command)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Button("Load") {
                            command = saved.command
                            isAppleScript = saved.isAppleScript
                        }
                        Button {
                            command = saved.command
                            isAppleScript = saved.isAppleScript
                            if saved.isAppleScript { runner.runAppleScript(saved.command) } else { runner.runShell(saved.command) }
                        } label: {
                            Image(systemName: "play.fill")
                        }
                        Button(role: .destructive) {
                            store.commands.removeAll { $0.id == saved.id }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                    Divider()
                }
            }
        }
    }

    private func openInTerminal() {
        let script = "tell application \"Terminal\"\nactivate\ndo script \"\(command.appleScriptEscaped)\"\nend tell"
        Shell.appleScript(script)
    }
}
