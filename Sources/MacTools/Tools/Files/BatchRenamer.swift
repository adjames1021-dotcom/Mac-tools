import SwiftUI
import AppKit

struct RenameOptions: Equatable {
    enum CaseChange: String, CaseIterable, Identifiable {
        case none, lower, upper, title
        var id: String { rawValue }
        var title: String {
            switch self {
            case .none: return "Keep"
            case .lower: return "lowercase"
            case .upper: return "UPPERCASE"
            case .title: return "Title Case"
            }
        }
    }

    var find = ""
    var replace = ""
    var useRegex = false
    var caseSensitive = false
    var prefix = ""
    var suffix = ""
    var caseChange: CaseChange = .none
    var numbering = false
    var numberStart = 1
    var numberPadding = 2
    var numberAsPrefix = false
    var numberSeparator = " "
    var replaceWholeName = false
    var newBaseName = "File"
    var newExtension = ""
    var trimSpaces = true
}

enum Renamer {
    static func newName(for url: URL, index: Int, options o: RenameOptions) -> String {
        let ext = url.pathExtension
        var base = url.deletingPathExtension().lastPathComponent
        if o.replaceWholeName { base = o.newBaseName }
        if !o.find.isEmpty && !o.replaceWholeName {
            if o.useRegex {
                if let re = try? NSRegularExpression(pattern: o.find, options: o.caseSensitive ? [] : [.caseInsensitive]) {
                    base = re.stringByReplacingMatches(in: base, options: [], range: NSRange(base.startIndex..<base.endIndex, in: base), withTemplate: o.replace)
                }
            } else {
                base = base.replacingOccurrences(of: o.find, with: o.replace, options: o.caseSensitive ? [] : [.caseInsensitive])
            }
        }
        switch o.caseChange {
        case .none: break
        case .lower: base = base.lowercased()
        case .upper: base = base.uppercased()
        case .title: base = base.capitalized
        }
        base = o.prefix + base + o.suffix
        if o.numbering {
            let n = String(o.numberStart + index)
            let padded = String(repeating: "0", count: max(0, o.numberPadding - n.count)) + n
            base = o.numberAsPrefix ? padded + o.numberSeparator + base : base + o.numberSeparator + padded
        }
        if o.trimSpaces { base = base.trimmed }
        base = base.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let newExt = o.newExtension.trimmed.isEmpty ? ext : o.newExtension.trimmed.replacingOccurrences(of: ".", with: "")
        return newExt.isEmpty ? base : base + "." + newExt
    }
}

struct BatchRenamerView: View {
    @State private var files: [URL] = []
    @State private var options = RenameOptions()
    @State private var lastBatch: [(from: URL, to: URL)] = []
    @State private var message = ""
    @State private var sortByDate = false

    private var preview: [(URL, String)] {
        files.enumerated().map { ($0.element, Renamer.newName(for: $0.element, index: $0.offset, options: options)) }
    }

    private var conflicts: Set<String> {
        var seen = Set<String>()
        var dupes = Set<String>()
        for (url, name) in preview {
            let key = url.deletingLastPathComponent().appendingPathComponent(name).path.lowercased()
            if !seen.insert(key).inserted { dupes.insert(key) }
        }
        return dupes
    }

    var body: some View {
        ToolPage(tool: .batchRenamer) {
            Card(title: "Files", icon: "folder") {
                HStack {
                    Button("Add Files…") { add(Panels.chooseFiles(multiple: true)) }
                    Button("Add Folder Contents…") {
                        if let folder = Panels.chooseFolder() {
                            let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])) ?? []
                            add(items.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true })
                        }
                    }
                    Button("Clear") { files = [] }
                    Toggle("Sort by date", isOn: $sortByDate)
                    Spacer()
                    Text("\(files.count) files").foregroundStyle(.secondary)
                }
                if files.isEmpty {
                    Text("Add files or drop them here.").foregroundStyle(.secondary)
                }
            }
            .acceptsFileDrops { add($0) }

            Card(title: "Rules", icon: "slider.horizontal.3") {
                Toggle("Replace the whole name with", isOn: $options.replaceWholeName)
                if options.replaceWholeName {
                    TextField("New name", text: $options.newBaseName)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 260)
                } else {
                    HStack {
                        TextField("Find", text: $options.find).textFieldStyle(.roundedBorder)
                        TextField("Replace with", text: $options.replace).textFieldStyle(.roundedBorder)
                        Toggle("Regex", isOn: $options.useRegex)
                        Toggle("Match case", isOn: $options.caseSensitive)
                    }
                }
                HStack {
                    TextField("Add prefix", text: $options.prefix).textFieldStyle(.roundedBorder)
                    TextField("Add suffix", text: $options.suffix).textFieldStyle(.roundedBorder)
                    TextField("New extension", text: $options.newExtension)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                }
                Picker("Change case", selection: $options.caseChange) {
                    ForEach(RenameOptions.CaseChange.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 420)
                HStack(spacing: 14) {
                    Toggle("Add numbers", isOn: $options.numbering)
                    if options.numbering {
                        IntField(title: "Start at", value: $options.numberStart, width: 60)
                        Stepper("Digits: \(options.numberPadding)", value: $options.numberPadding, in: 1...6)
                        Picker("", selection: $options.numberAsPrefix) {
                            Text("At end").tag(false)
                            Text("At start").tag(true)
                        }
                        .frame(width: 110)
                        TextField("Separator", text: $options.numberSeparator)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60)
                    }
                }
            }

            Card(title: "Preview", icon: "eye") {
                let conflictSet = conflicts
                if !conflictSet.isEmpty {
                    Label("Some new names clash. Add numbering to make them unique.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                }
                ForEach(Array(preview.prefix(300).enumerated()), id: \.offset) { item in
                    let url = item.element.0
                    let name = item.element.1
                    let clash = conflictSet.contains(url.deletingLastPathComponent().appendingPathComponent(name).path.lowercased())
                    HStack {
                        Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        Text(name).lineLimit(1).truncationMode(.middle)
                            .foregroundColor(clash ? Color.red : (name == url.lastPathComponent ? Color.secondary : Color.primary))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.callout)
                }
                HStack {
                    Button("Rename \(files.count) Files") { rename() }
                        .buttonStyle(.borderedProminent)
                        .disabled(files.isEmpty || !conflictSet.isEmpty)
                    Button("Undo Last Rename") { undo() }
                        .disabled(lastBatch.isEmpty)
                    Text(message).foregroundStyle(.secondary)
                }
            }
        }
        .onChange(of: sortByDate) { _ in sortFiles() }
    }

    private func add(_ urls: [URL]) {
        let existing = Set(files)
        files += urls.filter { !existing.contains($0) }
        sortFiles()
    }

    private func sortFiles() {
        if sortByDate {
            files.sort {
                let a = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return a < b
            }
        } else {
            files.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        }
    }

    private func rename() {
        var done: [(from: URL, to: URL)] = []
        var errors = 0
        let plan = preview
        // Two-phase rename via temporary names so swaps like a→b, b→a work.
        var temps: [(URL, URL, URL)] = []
        for (url, name) in plan where name != url.lastPathComponent {
            let temp = url.deletingLastPathComponent().appendingPathComponent(".mactools-\(UUID().uuidString)")
            let target = url.deletingLastPathComponent().appendingPathComponent(name)
            do {
                try FileManager.default.moveItem(at: url, to: temp)
                temps.append((url, temp, target))
            } catch {
                errors += 1
            }
        }
        for (original, temp, target) in temps {
            do {
                if FileManager.default.fileExists(atPath: target.path) { throw CocoaError(.fileWriteFileExists) }
                try FileManager.default.moveItem(at: temp, to: target)
                done.append((original, target))
            } catch {
                try? FileManager.default.moveItem(at: temp, to: original)
                errors += 1
            }
        }
        lastBatch = done
        let renamed = Dictionary(done.map { ($0.from, $0.to) }, uniquingKeysWith: { a, _ in a })
        files = files.map { renamed[$0] ?? $0 }
        message = "Renamed \(done.count) file(s)" + (errors > 0 ? ", \(errors) failed" : "")
    }

    private func undo() {
        var restored = 0
        for pair in lastBatch.reversed() {
            if (try? FileManager.default.moveItem(at: pair.to, to: pair.from)) != nil { restored += 1 }
        }
        let back = Dictionary(lastBatch.map { ($0.to, $0.from) }, uniquingKeysWith: { a, _ in a })
        files = files.map { back[$0] ?? $0 }
        lastBatch = []
        message = "Restored \(restored) file(s)"
    }
}
