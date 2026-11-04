import SwiftUI

struct MacroRecorderView: View {
    @ObservedObject private var engine = MacroEngine.shared
    @State private var showAllEvents = false

    var body: some View {
        ToolPage(tool: .macroRecorder) {
            PermissionBanner(needs: [.accessibility, .inputMonitoring])

            if let error = engine.lastError {
                Label(error, systemImage: "exclamationmark.circle")
                    .foregroundColor(.red)
            }

            controls
            options
            currentMacro
            library
        }
    }

    private var controls: some View {
        Card(title: "Record & Play", icon: "record.circle") {
            HStack(spacing: 12) {
                if engine.state == .recording {
                    Button {
                        engine.stopRecording(trimTrailingClick: true)
                    } label: {
                        Label("Stop Recording", systemImage: "stop.fill")
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                } else {
                    Button {
                        engine.startRecording()
                    } label: {
                        Label("Record", systemImage: "record.circle")
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(engine.state == .playing)
                }

                if engine.state == .playing {
                    Button {
                        engine.stopPlayback()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .controlSize(.large)
                } else {
                    Button {
                        engine.play()
                    } label: {
                        Label("Play", systemImage: "play.fill")
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .disabled(engine.state != .idle || engine.events.isEmpty)
                }

                Spacer()
                StatusBadge(active: engine.state != .idle,
                            activeText: engine.state == .recording ? "Recording… \(engine.liveCount) events" : "Playing (loop \(engine.loopsDone + 1))",
                            idleText: "Idle")
            }
            if engine.state == .playing {
                ProgressView(value: min(max(engine.progress, 0), 1))
            }
            HStack(spacing: 16) {
                HotKeyHint(action: .toggleMacroRecording)
                HotKeyHint(action: .toggleMacroPlayback)
                HotKeyHint(action: .stopAll)
            }
            Text("Tip: use the hotkeys so the click on MacTools itself isn't part of the recording. Hotkey presses are never recorded.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var options: some View {
        Card(title: "Options", icon: "slider.horizontal.3") {
            Toggle("Record mouse movement (turn off to record only clicks, scrolls and keys)", isOn: $engine.settings.recordMouseMoves)
            HStack {
                Text("Playback speed")
                Slider(value: $engine.settings.speed, in: 0.25...5, step: 0.25)
                    .frame(maxWidth: 260)
                Text(String(format: "%.2f×", engine.settings.speed))
                    .monospacedDigit()
                    .frame(width: 50, alignment: .leading)
                Button("1×") { engine.settings.speed = 1 }
            }
            HStack(spacing: 20) {
                IntField(title: "Repeat", value: $engine.settings.repeatCount, unit: "times (0 = forever)")
                NumberField(title: "Pause between loops", value: $engine.settings.loopDelay, unit: "sec")
            }
            NumberField(title: "Start delay", value: $engine.settings.startDelay, unit: "sec")
        }
    }

    private var currentMacro: some View {
        Card(title: "Current Recording", icon: "list.bullet") {
            HStack {
                TextField("Name", text: $engine.currentName)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                Button("Save to Library") { engine.saveCurrent() }
                    .disabled(engine.events.isEmpty)
                Button("Export…") { engine.exportCurrent() }
                    .disabled(engine.events.isEmpty)
                Spacer()
                Text("\(engine.events.count) events · \(Format.duration(engine.duration))")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            HStack {
                Button("Remove Mouse Moves") { engine.removeMouseMoves() }
                Button("Shorten Long Pauses") { engine.compressPauses(maxGap: 1.0) }
                Button("Clear", role: .destructive) { engine.events = [] }
                Spacer()
                Toggle("Show all events", isOn: $showAllEvents)
            }
            .disabled(engine.events.isEmpty || engine.state != .idle)

            let limit = showAllEvents ? engine.events.count : min(engine.events.count, 300)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(0..<limit, id: \.self) { index in
                        let event = engine.events[index]
                        HStack {
                            Text(String(format: "%7.2fs", event.time))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Image(systemName: event.icon)
                                .frame(width: 18)
                                .foregroundStyle(.secondary)
                            Text(event.summary).font(.callout)
                            Spacer()
                            Button {
                                engine.removeEvent(at: index)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .disabled(engine.state != .idle)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                    }
                    if engine.events.count > limit {
                        Text("…and \(engine.events.count - limit) more")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(6)
                    }
                    if engine.events.isEmpty {
                        Text("No events yet. Press Record, do your actions, then stop.")
                            .foregroundStyle(.secondary)
                            .padding(8)
                    }
                }
            }
            .frame(height: 220)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
        }
    }

    private var library: some View {
        Card(title: "Macro Library", icon: "books.vertical") {
            HStack {
                Button("Import…") { engine.importMacros() }
                Spacer()
                Text("Saved macros can also be played from the Task Scheduler.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if engine.library.isEmpty {
                Text("No saved macros yet.").foregroundStyle(.secondary)
            }
            ForEach(engine.library) { macro in
                HStack {
                    Image(systemName: "record.circle").foregroundStyle(.red)
                    VStack(alignment: .leading) {
                        Text(macro.name).bold()
                        Text("\(macro.events.count) events · \(Format.duration(macro.duration)) · \(macro.created.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Load") { engine.load(macro) }
                    Button {
                        engine.load(macro)
                        engine.play(macro.events)
                    } label: {
                        Image(systemName: "play.fill")
                    }
                    .help("Play")
                    Button(role: .destructive) {
                        engine.delete(macro)
                    } label: {
                        Image(systemName: "trash")
                    }
                }
                .disabled(engine.state != .idle)
                Divider()
            }
        }
    }
}
