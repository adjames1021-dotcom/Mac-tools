import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct LaunchItem: Codable, Identifiable, Equatable {
    enum Kind: String, Codable {
        case app, file, url, command
    }

    var id = UUID()
    var kind: Kind
    var value: String

    var displayName: String {
        switch kind {
        case .app, .file:
            return URL(fileURLWithPath: value).deletingPathExtension().lastPathComponent
        case .url, .command:
            return value
        }
    }

    var icon: String {
        switch kind {
        case .app: return "app"
        case .file: return "doc"
        case .url: return "globe"
        case .command: return "terminal"
        }
    }
}

struct LaunchProfile: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var items: [LaunchItem] = []
}

final class LauncherStore: ObservableObject {
    static let shared = LauncherStore()

    @Published var profiles: [LaunchProfile] {
        didSet { DataStore.save(profiles, to: "launcher.json") }
    }

    private init() {
        profiles = DataStore.load([LaunchProfile].self, from: "launcher.json") ?? [
            LaunchProfile(name: "Work", items: [
                LaunchItem(kind: .url, value: "https://calendar.google.com"),
                LaunchItem(kind: .url, value: "https://mail.google.com")
            ])
        ]
    }

    func launch(_ profile: LaunchProfile) {
        for item in profile.items { launch(item) }
    }

    func launch(_ item: LaunchItem) {
        switch item.kind {
        case .app:
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: item.value), configuration: NSWorkspace.OpenConfiguration())
        case .file:
            NSWorkspace.shared.open(URL(fileURLWithPath: item.value))
        case .url:
            var text = item.value
            if !text.contains("://") { text = "https://" + text }
            if let url = URL(string: text) { NSWorkspace.shared.open(url) }
        case .command:
            Shell.run(item.value)
        }
    }
}

struct LauncherView: View {
    @ObservedObject private var store = LauncherStore.shared
    @State private var selectedID: UUID?
    @State private var newURL = ""
    @State private var newCommand = ""
    @State private var newProfileName = ""

    private var selectedIndex: Int? {
        guard let id = selectedID ?? store.profiles.first?.id else { return nil }
        return store.profiles.firstIndex(where: { $0.id == id })
    }

    private var currentID: UUID? {
        selectedIndex.map { store.profiles[$0].id }
    }

    var body: some View {
        ToolPage(tool: .launcher) {
            HStack(alignment: .top, spacing: 16) {
                Card(title: "Profiles", icon: "square.stack.3d.up") {
                    ForEach(store.profiles) { profile in
                        HStack {
                            Button {
                                selectedID = profile.id
                            } label: {
                                HStack {
                                    Image(systemName: profile.id == currentID ? "largecircle.fill.circle" : "circle")
                                    Text(profile.name)
                                    Spacer()
                                    Text("\(profile.items.count)").foregroundStyle(.secondary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Button {
                                store.launch(profile)
                            } label: {
                                Image(systemName: "play.fill")
                            }
                            .help("Launch everything in this profile")
                        }
                    }
                    Divider()
                    HStack {
                        TextField("New profile", text: $newProfileName)
                            .textFieldStyle(.roundedBorder)
                        Button("Add") {
                            let p = LaunchProfile(name: newProfileName.trimmed.isEmpty ? "Profile \(store.profiles.count + 1)" : newProfileName.trimmed)
                            store.profiles.append(p)
                            selectedID = p.id
                            newProfileName = ""
                        }
                    }
                }
                .frame(width: 260)

                if let index = selectedIndex {
                    profileEditor(index)
                } else {
                    Text("Create a profile to get started.").foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func profileEditor(_ index: Int) -> some View {
        Card(title: "Items", icon: "list.bullet") {
            HStack {
                TextField("Profile name", text: Binding(
                    get: { store.profiles.indices.contains(index) ? store.profiles[index].name : "" },
                    set: { if store.profiles.indices.contains(index) { store.profiles[index].name = $0 } }))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 240)
                Spacer()
                Button {
                    if store.profiles.indices.contains(index) { store.launch(store.profiles[index]) }
                } label: {
                    Label("Launch All", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                Button(role: .destructive) {
                    if store.profiles.indices.contains(index) {
                        store.profiles.remove(at: index)
                        selectedID = store.profiles.first?.id
                    }
                } label: {
                    Image(systemName: "trash")
                }
            }
            HStack {
                Button("Add App…") {
                    let urls = Panels.chooseFiles(multiple: true, types: [.application])
                    addItems(urls.map { LaunchItem(kind: .app, value: $0.path) }, to: index)
                }
                Button("Add File or Folder…") {
                    let urls = Panels.chooseFiles(multiple: true, directories: true)
                    addItems(urls.map { LaunchItem(kind: .file, value: $0.path) }, to: index)
                }
            }
            HStack {
                TextField("Website, e.g. github.com", text: $newURL)
                    .textFieldStyle(.roundedBorder)
                Button("Add URL") {
                    addItems([LaunchItem(kind: .url, value: newURL.trimmed)], to: index)
                    newURL = ""
                }
                .disabled(newURL.trimmed.isEmpty)
            }
            HStack {
                TextField("Shell command", text: $newCommand)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                Button("Add Command") {
                    addItems([LaunchItem(kind: .command, value: newCommand.trimmed)], to: index)
                    newCommand = ""
                }
                .disabled(newCommand.trimmed.isEmpty)
            }
            Divider()
            if store.profiles.indices.contains(index) {
                if store.profiles[index].items.isEmpty {
                    Text("No items yet. You can also drop apps and files here.").foregroundStyle(.secondary)
                }
                ForEach(store.profiles[index].items) { item in
                    HStack {
                        if item.kind == .app || item.kind == .file {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: item.value))
                                .resizable()
                                .frame(width: 20, height: 20)
                        } else {
                            Image(systemName: item.icon).frame(width: 20)
                        }
                        Text(item.displayName).lineLimit(1)
                        Spacer()
                        Button("Open") { store.launch(item) }
                        Button {
                            if store.profiles.indices.contains(index) {
                                store.profiles[index].items.removeAll { $0.id == item.id }
                            }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
        .acceptsFileDrops { urls in
            let items = urls.map { url -> LaunchItem in
                LaunchItem(kind: url.pathExtension == "app" ? .app : .file, value: url.path)
            }
            addItems(items, to: index)
        }
    }

    private func addItems(_ items: [LaunchItem], to index: Int) {
        guard store.profiles.indices.contains(index) else { return }
        store.profiles[index].items.append(contentsOf: items.filter { !$0.value.isEmpty })
    }
}
