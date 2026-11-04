import SwiftUI
import AppKit

struct ClipItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var text: String
    var date: Date
    var pinned = false
    var sourceApp: String?
}

final class ClipboardManager: ObservableObject {
    static let shared = ClipboardManager()

    @Published var items: [ClipItem] {
        didSet { if persist { DataStore.save(items, to: "clipboard.json") } }
    }
    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: "clipboardEnabled") }
    }
    @Published var persist: Bool {
        didSet {
            UserDefaults.standard.set(persist, forKey: "clipboardPersist")
            if persist {
                DataStore.save(items, to: "clipboard.json")
            } else {
                try? FileManager.default.removeItem(at: DataStore.url("clipboard.json"))
            }
        }
    }
    @Published var maxItems: Int {
        didSet {
            UserDefaults.standard.set(maxItems, forKey: "clipboardMax")
            trim()
        }
    }

    private var lastChange = NSPasteboard.general.changeCount
    private var timer: Timer?

    private init() {
        let defaults = UserDefaults.standard
        enabled = defaults.object(forKey: "clipboardEnabled") as? Bool ?? true
        persist = defaults.object(forKey: "clipboardPersist") as? Bool ?? true
        maxItems = defaults.object(forKey: "clipboardMax") as? Int ?? 200
        items = DataStore.load([ClipItem].self, from: "clipboard.json") ?? []
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChange else { return }
        lastChange = pb.changeCount
        guard enabled else { return }
        let types = pb.types ?? []
        // Respect password managers that mark their copies as concealed/transient.
        let concealed = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "com.agilebits.onepassword"]
        if types.contains(where: { concealed.contains($0.rawValue) }) { return }
        guard let text = pb.string(forType: .string), !text.trimmed.isEmpty else { return }
        let app = NSWorkspace.shared.frontmostApplication?.localizedName
        if let index = items.firstIndex(where: { $0.text == text }) {
            var item = items.remove(at: index)
            item.date = Date()
            items.insert(item, at: 0)
        } else {
            items.insert(ClipItem(text: text, date: Date(), sourceApp: app), at: 0)
        }
        trim()
    }

    private func trim() {
        let limit = max(10, maxItems)
        if items.count > limit {
            var unpinnedSeen = 0
            items = items.filter { item in
                if item.pinned { return true }
                unpinnedSeen += 1
                return unpinnedSeen <= limit
            }
        }
    }

    func copy(_ item: ClipItem) {
        ClipboardHelper.copy(item.text)
        lastChange = NSPasteboard.general.changeCount
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            var moved = items.remove(at: index)
            moved.date = Date()
            items.insert(moved, at: 0)
        }
    }

    func togglePin(_ item: ClipItem) {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index].pinned.toggle()
        }
    }

    func delete(_ item: ClipItem) {
        items.removeAll { $0.id == item.id }
    }

    func clearUnpinned() {
        items.removeAll { !$0.pinned }
    }
}

struct ClipboardView: View {
    @ObservedObject private var manager = ClipboardManager.shared
    @State private var search = ""
    @State private var pinnedOnly = false

    private var filtered: [ClipItem] {
        let list = manager.items.filter { !pinnedOnly || $0.pinned }
        if search.isEmpty { return list }
        return list.filter { $0.text.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        ToolPage(tool: .clipboard) {
            Card(title: "Settings", icon: "gearshape") {
                HStack(spacing: 20) {
                    Toggle("Record clipboard history", isOn: $manager.enabled)
                    Toggle("Save history between launches", isOn: $manager.persist)
                    Stepper("Keep \(manager.maxItems) items", value: $manager.maxItems, in: 10...2000, step: 10)
                }
                Text("Items copied from password managers are skipped automatically. Click any item to copy it again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                TextField("Search history", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
                Toggle("Pinned only", isOn: $pinnedOnly)
                Spacer()
                Text("\(manager.items.count) items").foregroundStyle(.secondary)
                Button("Clear Unpinned", role: .destructive) { manager.clearUnpinned() }
            }

            if filtered.isEmpty {
                Text(manager.items.isEmpty ? "Copy something and it will show up here." : "No matches.")
                    .foregroundStyle(.secondary)
                    .padding()
            }

            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(filtered) { item in
                    ClipRow(item: item)
                }
            }
        }
    }
}

private struct ClipRow: View {
    let item: ClipItem
    @ObservedObject private var manager = ClipboardManager.shared
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.pinned ? "pin.fill" : "doc.plaintext")
                .foregroundColor(item.pinned ? Color.orange : Color.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.text.trimmed)
                    .lineLimit(3)
                    .font(.system(.callout, design: .monospaced))
                HStack(spacing: 6) {
                    Text(item.date.formatted(date: .abbreviated, time: .shortened))
                    if let app = item.sourceApp { Text("· \(app)") }
                    Text("· \(item.text.count) chars")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if copied {
                Label("Copied", systemImage: "checkmark").foregroundColor(.green).font(.caption)
            }
            Button {
                manager.togglePin(item)
            } label: {
                Image(systemName: item.pinned ? "pin.slash" : "pin")
            }
            .buttonStyle(.borderless)
            .help(item.pinned ? "Unpin" : "Pin")
            Button {
                manager.delete(item)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(hovering ? 0.08 : 0.04)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            manager.copy(item)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { copied = false }
        }
    }
}
