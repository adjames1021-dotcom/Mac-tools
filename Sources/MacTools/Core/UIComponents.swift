import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Standard page layout for a tool: header + content, optionally scrollable.
struct ToolPage<Content: View>: View {
    let tool: ToolID
    var scrolls: Bool = true
    @ViewBuilder let content: () -> Content

    var body: some View {
        if scrolls {
            ScrollView {
                inner
            }
        } else {
            inner
        }
    }

    private var inner: some View {
        VStack(alignment: .leading, spacing: 16) {
            ToolHeader(tool: tool)
            content()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: scrolls ? nil : .infinity, alignment: .topLeading)
    }
}

struct ToolHeader: View {
    let tool: ToolID

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: tool.icon)
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 44, height: 44)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(LinearGradient(colors: [Color.accentColor, Color.accentColor.opacity(0.65)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(tool.title).font(.title2.bold())
                Text(tool.summary).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

/// A rounded card section with a title.
struct Card<Content: View>: View {
    let title: String
    var icon: String? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                if let icon = icon {
                    Image(systemName: icon).foregroundStyle(.secondary)
                }
                Text(title).font(.headline)
            }
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08)))
    }
}

/// Shows a warning with buttons when required permissions are missing.
struct PermissionBanner: View {
    let needs: [PermissionKind]
    @ObservedObject private var permissions = Permissions.shared

    var body: some View {
        let missing = needs.filter { !permissions.isGranted($0) }
        if !missing.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label("Permission needed", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundColor(.orange)
                ForEach(missing) { kind in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(kind.title).bold()
                            Text(kind.explanation).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Grant…") { permissions.request(kind) }
                        Button("Open Settings") { permissions.openSettings(kind) }
                    }
                }
                Text("Turn MacTools on in System Settings ▸ Privacy & Security. If it is already on but not working, remove it with “–” and add it again (this happens after rebuilding).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.12)))
        }
    }
}

struct StatusBadge: View {
    let active: Bool
    let activeText: String
    let idleText: String

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(active ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 9, height: 9)
            Text(active ? activeText : idleText)
                .font(.callout.weight(.medium))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
    }
}

struct HotKeyHint: View {
    let action: HotKeyAction
    @ObservedObject private var center = HotKeyCenter.shared

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "keyboard")
            Text("Hotkey: \(center.displayString(for: action))")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .help("Change hotkeys in Permissions & Hotkeys. On laptops you may need to hold fn for F-keys.")
    }
}

struct CopyButton: View {
    let text: String
    var label: String = "Copy"
    @State private var copied = false

    var body: some View {
        Button {
            ClipboardHelper.copy(text)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
        } label: {
            Label(copied ? "Copied" : label, systemImage: copied ? "checkmark" : "doc.on.doc")
        }
        .disabled(text.isEmpty)
    }
}

/// A plain-text editor with monospaced font and a border.
struct CodeEditor: View {
    @Binding var text: String
    var minHeight: CGFloat = 160
    var monospaced = true

    var body: some View {
        TextEditor(text: $text)
            .font(monospaced ? .system(.body, design: .monospaced) : .body)
            .frame(minHeight: minHeight)
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.15)))
    }
}

/// Read-only, selectable output box.
struct OutputBox: View {
    let text: String
    var minHeight: CGFloat = 140
    var maxHeight: CGFloat = 360

    var body: some View {
        ScrollView {
            Text(text.isEmpty ? " " : text)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(8)
        }
        .frame(minHeight: minHeight, maxHeight: maxHeight)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.15)))
    }
}

/// Button that records the next key press (with modifiers) into a KeyCombo.
struct KeyComboRecorder: View {
    @Binding var combo: KeyCombo?
    var placeholder: String = "Click to set"
    var suspendHotkeys: Bool = true

    @State private var listening = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            if listening { stopListening() } else { startListening() }
        } label: {
            Text(listening ? "Press keys… (Esc cancels)" : (combo?.displayString ?? placeholder))
                .frame(minWidth: 120)
        }
        .onDisappear { stopListening() }
    }

    private func startListening() {
        listening = true
        if suspendHotkeys { HotKeyCenter.shared.suspend() }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let combo = KeyCombo(event: event)
            if event.keyCode == 53 && !combo.hasModifiers {
                stopListening()
                return nil
            }
            self.combo = combo
            stopListening()
            return nil
        }
    }

    private func stopListening() {
        if let monitor = monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if listening && suspendHotkeys { HotKeyCenter.shared.resume() }
        listening = false
    }
}

/// Counts down a few seconds then reports the cursor position.
struct PickPointButton: View {
    var title: String = "Pick Location"
    var seconds: Int = 3
    let onPick: (CGPoint) -> Void

    @State private var remaining = 0

    var body: some View {
        Button {
            remaining = seconds
            tick()
        } label: {
            Label(remaining > 0 ? "Move mouse to target… \(remaining)" : title, systemImage: "scope")
        }
        .disabled(remaining > 0)
        .help("After clicking, move your mouse to the spot. The position is captured when the countdown ends.")
    }

    private func tick() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            remaining -= 1
            if remaining <= 0 {
                remaining = 0
                onPick(InputSynth.cursorLocation)
                NSSound(named: "Tink")?.play()
            } else {
                tick()
            }
        }
    }
}

/// A number field with a label and unit suffix.
struct NumberField: View {
    let title: String
    @Binding var value: Double
    var unit: String = ""
    var width: CGFloat = 80

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            TextField("", value: $value, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: width)
                .multilineTextAlignment(.trailing)
            if !unit.isEmpty {
                Text(unit).foregroundStyle(.secondary)
            }
        }
    }
}

struct IntField: View {
    let title: String
    @Binding var value: Int
    var unit: String = ""
    var width: CGFloat = 80

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            TextField("", value: $value, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: width)
                .multilineTextAlignment(.trailing)
            if !unit.isEmpty {
                Text(unit).foregroundStyle(.secondary)
            }
        }
    }
}

/// Simple key/value row used in info screens.
struct InfoRow: View {
    let label: String
    let value: String
    var copyable = true

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 170, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if copyable && !value.isEmpty {
                Button {
                    ClipboardHelper.copy(value)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy")
            }
        }
        .font(.callout)
    }
}

/// Accepts dropped files and calls back with their URLs.
struct FileDropModifier: ViewModifier {
    let onDrop: ([URL]) -> Void
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .opacity(targeted ? 1 : 0)
            )
            .onDrop(of: [UTType.fileURL], isTargeted: $targeted) { providers in
                let group = DispatchGroup()
                let collector = URLCollector()
                for provider in providers {
                    group.enter()
                    provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                        if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                            collector.add(url)
                        } else if let url = item as? URL {
                            collector.add(url)
                        }
                        group.leave()
                    }
                }
                group.notify(queue: .main) { onDrop(collector.urls) }
                return true
            }
    }
}

final class URLCollector {
    private let lock = NSLock()
    private(set) var urls: [URL] = []

    func add(_ url: URL) {
        lock.lock()
        urls.append(url)
        lock.unlock()
    }
}

extension View {
    func acceptsFileDrops(_ onDrop: @escaping ([URL]) -> Void) -> some View {
        modifier(FileDropModifier(onDrop: onDrop))
    }
}

/// A rounded, content-sized button for icon-over-label tiles.
/// (The standard macOS button has a fixed height, which clips multi-line labels.)
struct TileButtonStyle: ButtonStyle {
    var selected: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        TileBody(configuration: configuration, selected: selected)
    }

    private struct TileBody: View {
        let configuration: ButtonStyleConfiguration
        let selected: Bool
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        private var fill: Color {
            if selected { return Color.accentColor.opacity(configuration.isPressed ? 0.75 : 1) }
            if configuration.isPressed { return Color.primary.opacity(0.18) }
            return Color.primary.opacity(hovering ? 0.10 : 0.06)
        }

        var body: some View {
            configuration.label
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .foregroundColor(selected ? Color.white : Color.primary)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(fill))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.primary.opacity(selected ? 0 : 0.12))
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .opacity(isEnabled ? 1 : 0.45)
                .onHover { hovering = $0 }
        }
    }
}
