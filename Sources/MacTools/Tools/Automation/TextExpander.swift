import SwiftUI
import AppKit

struct Snippet: Codable, Identifiable, Equatable {
    var id = UUID()
    var trigger: String
    var expansion: String
    var enabled = true
}

final class TextExpander: ObservableObject {
    static let shared = TextExpander()

    @Published var snippets: [Snippet] {
        didSet { DataStore.save(snippets, to: "snippets.json") }
    }
    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "textExpanderEnabled")
            if enabled { start() } else { stop() }
        }
    }
    @Published var usePaste: Bool {
        didSet { UserDefaults.standard.set(usePaste, forKey: "textExpanderUsePaste") }
    }
    @Published private(set) var expansions = 0

    private var monitor: Any?
    private var buffer = ""

    private init() {
        snippets = DataStore.load([Snippet].self, from: "snippets.json") ?? [
            Snippet(trigger: ";date", expansion: "{date}"),
            Snippet(trigger: ";time", expansion: "{time}"),
            Snippet(trigger: ";shrug", expansion: "¯\\_(ツ)_/¯"),
            Snippet(trigger: ";sig", expansion: "Best regards,\nYour Name"),
            Snippet(trigger: ";uuid", expansion: "{uuid}")
        ]
        enabled = UserDefaults.standard.bool(forKey: "textExpanderEnabled")
        usePaste = UserDefaults.standard.bool(forKey: "textExpanderUsePaste")
    }

    var isMonitoring: Bool { monitor != nil }

    func startIfEnabled() {
        if enabled { start() }
    }

    func start() {
        guard monitor == nil else { return }
        if !Permissions.shared.accessibility {
            Permissions.shared.request(.accessibility)
        }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.handle(event)
        }
    }

    func stop() {
        if let monitor = monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        buffer = ""
    }

    private func handle(_ event: NSEvent) {
        guard event.type == .keyDown else {
            buffer = ""
            return
        }
        if let cg = event.cgEvent, InputSynth.isSynthetic(cg) { return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) || flags.contains(.control) {
            buffer = ""
            return
        }
        switch event.keyCode {
        case 51: // delete
            if !buffer.isEmpty { buffer.removeLast() }
            return
        case 36, 48, 53, 76, 123, 124, 125, 126, 115, 116, 119, 121:
            buffer = ""
            return
        default:
            break
        }
        guard let chars = event.characters, !chars.isEmpty else { return }
        buffer += chars
        if buffer.count > 120 { buffer = String(buffer.suffix(120)) }
        for snippet in snippets where snippet.enabled && !snippet.trigger.isEmpty {
            if buffer.hasSuffix(snippet.trigger) {
                buffer = ""
                expand(snippet)
                break
            }
        }
    }

    private func expand(_ snippet: Snippet) {
        let deleteCount = snippet.trigger.count
        let text = TextExpander.fillPlaceholders(snippet.expansion)
        let paste = usePaste
        expansions += 1
        DispatchQueue.global(qos: .userInitiated).async {
            Thread.sleep(forTimeInterval: 0.04)
            for _ in 0..<deleteCount {
                InputSynth.press(51)
                Thread.sleep(forTimeInterval: 0.004)
            }
            if paste {
                InputSynth.paste(text)
            } else {
                InputSynth.type(text, charDelay: 0.003)
            }
        }
    }

    static func fillPlaceholders(_ text: String) -> String {
        let now = Date()
        let date = DateFormatter()
        date.dateStyle = .medium
        date.timeStyle = .none
        let time = DateFormatter()
        time.dateStyle = .none
        time.timeStyle = .short
        let iso = DateFormatter()
        iso.dateFormat = "yyyy-MM-dd"
        var out = text
        out = out.replacingOccurrences(of: "{date}", with: date.string(from: now))
        out = out.replacingOccurrences(of: "{time}", with: time.string(from: now))
        out = out.replacingOccurrences(of: "{isodate}", with: iso.string(from: now))
        out = out.replacingOccurrences(of: "{datetime}", with: date.string(from: now) + " " + time.string(from: now))
        out = out.replacingOccurrences(of: "{uuid}", with: UUID().uuidString)
        if out.contains("{clipboard}") {
            let clip = InputSynth.onMain { ClipboardHelper.string ?? "" }
            out = out.replacingOccurrences(of: "{clipboard}", with: clip)
        }
        return out
    }
}

struct TextExpanderView: View {
    @ObservedObject private var expander = TextExpander.shared
    @State private var newTrigger = ""
    @State private var newExpansion = ""
    @State private var search = ""

    private var filteredIndices: [Int] {
        expander.snippets.indices.filter { i in
            search.isEmpty
                || expander.snippets[i].trigger.localizedCaseInsensitiveContains(search)
                || expander.snippets[i].expansion.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        ToolPage(tool: .textExpander) {
            PermissionBanner(needs: [.accessibility])

            Card(title: "Status", icon: "power") {
                HStack {
                    Toggle("Enable text expansion everywhere", isOn: $expander.enabled)
                        .toggleStyle(.switch)
                    Spacer()
                    StatusBadge(active: expander.enabled && expander.isMonitoring, activeText: "Listening", idleText: "Off")
                    Text("\(expander.expansions) expansions this session")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle("Insert by pasting (faster for long text, briefly uses the clipboard)", isOn: $expander.usePaste)
                Text("Placeholders: {date} {time} {isodate} {datetime} {uuid} {clipboard}. Tip: start abbreviations with a symbol like ; so they never trigger by accident.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Card(title: "New Snippet", icon: "plus.circle") {
                HStack(alignment: .top) {
                    TextField("Abbreviation e.g. ;addr", text: $newTrigger)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                    CodeEditor(text: $newExpansion, minHeight: 60, monospaced: false)
                        .frame(height: 70)
                    Button("Add") {
                        let trigger = newTrigger.trimmed
                        guard !trigger.isEmpty, !newExpansion.isEmpty else { return }
                        expander.snippets.insert(Snippet(trigger: trigger, expansion: newExpansion), at: 0)
                        newTrigger = ""
                        newExpansion = ""
                    }
                    .disabled(newTrigger.trimmed.isEmpty || newExpansion.isEmpty)
                }
            }

            Card(title: "Snippets (\(expander.snippets.count))", icon: "text.badge.plus") {
                TextField("Search snippets", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 300)
                ForEach(filteredIndices, id: \.self) { index in
                    SnippetRow(snippet: Binding(
                        get: { expander.snippets.indices.contains(index) ? expander.snippets[index] : Snippet(trigger: "", expansion: "") },
                        set: { if expander.snippets.indices.contains(index) { expander.snippets[index] = $0 } }
                    ), onDelete: {
                        if expander.snippets.indices.contains(index) { expander.snippets.remove(at: index) }
                    })
                    Divider()
                }
            }
        }
    }
}

private struct SnippetRow: View {
    @Binding var snippet: Snippet
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: $snippet.enabled).labelsHidden()
            TextField("Abbreviation", text: $snippet.trigger)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .frame(width: 150)
            TextField("Expansion", text: $snippet.expansion, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
    }
}
