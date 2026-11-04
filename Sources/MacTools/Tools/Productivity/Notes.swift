import SwiftUI
import UniformTypeIdentifiers

struct QuickNote: Codable, Identifiable, Equatable {
    var id = UUID()
    var text: String
    var modified = Date()

    var title: String {
        let first = text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        return first.trimmed.isEmpty ? "New note" : String(first.trimmed.prefix(60))
    }
}

final class NotesStore: ObservableObject {
    static let shared = NotesStore()

    @Published var notes: [QuickNote] {
        didSet { DataStore.save(notes, to: "notes.json") }
    }

    private init() {
        notes = DataStore.load([QuickNote].self, from: "notes.json") ?? [
            QuickNote(text: "Welcome to Quick Notes\n\nEverything you type here is saved automatically.")
        ]
    }
}

struct NotesView: View {
    @ObservedObject private var store = NotesStore.shared
    @State private var selectedID: UUID?
    @State private var search = ""

    private var currentIndex: Int? {
        guard let id = selectedID ?? store.notes.first?.id else { return nil }
        return store.notes.firstIndex { $0.id == id }
    }

    private var filtered: [QuickNote] {
        let sorted = store.notes.sorted { $0.modified > $1.modified }
        if search.isEmpty { return sorted }
        return sorted.filter { $0.text.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        ToolPage(tool: .notes, scrolls: false) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        TextField("Search", text: $search).textFieldStyle(.roundedBorder)
                        Button {
                            let note = QuickNote(text: "")
                            store.notes.insert(note, at: 0)
                            selectedID = note.id
                        } label: {
                            Image(systemName: "square.and.pencil")
                        }
                        .help("New note")
                    }
                    List(filtered, selection: $selectedID) { note in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(note.title).lineLimit(1).font(.headline)
                            Text(note.modified.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(note.id)
                    }
                    .listStyle(.inset)
                }
                .frame(width: 240)

                VStack(alignment: .leading, spacing: 8) {
                    if let index = currentIndex {
                        HStack {
                            Text("\(store.notes[index].text.split { $0 == " " || $0 == "\n" }.count) words · \(store.notes[index].text.count) characters")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            CopyButton(text: store.notes[index].text)
                            Button("Export…") { export(store.notes[index]) }
                            Button(role: .destructive) {
                                let id = store.notes[index].id
                                store.notes.removeAll { $0.id == id }
                                selectedID = store.notes.first?.id
                            } label: {
                                Image(systemName: "trash")
                            }
                        }
                        TextEditor(text: Binding(
                            get: { store.notes.indices.contains(index) ? store.notes[index].text : "" },
                            set: { value in
                                if store.notes.indices.contains(index) {
                                    store.notes[index].text = value
                                    store.notes[index].modified = Date()
                                }
                            }))
                            .font(.system(size: 14))
                            .padding(6)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.15)))
                    } else {
                        Text("No note selected").foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)
        }
    }

    private func export(_ note: QuickNote) {
        guard let url = Panels.saveFile(name: note.title + ".txt", types: [.plainText]) else { return }
        try? note.text.write(to: url, atomically: true, encoding: .utf8)
    }
}
