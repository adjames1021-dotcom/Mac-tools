import SwiftUI
import AppKit
import CryptoKit

struct SizedItem: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let size: Int64
    let isDirectory: Bool
}

// MARK: - Disk usage

final class DiskScanner: ObservableObject {
    @Published private(set) var scanning = false
    @Published private(set) var scannedFiles = 0
    @Published private(set) var topLevel: [SizedItem] = []
    @Published private(set) var largestFiles: [SizedItem] = []
    @Published private(set) var totalSize: Int64 = 0
    @Published var root: URL?

    private var token: CancelToken?

    func scan(_ url: URL) {
        cancel()
        root = url
        scanning = true
        scannedFiles = 0
        topLevel = []
        largestFiles = []
        totalSize = 0
        let token = CancelToken()
        self.token = token
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let fm = FileManager.default
            let keys: [URLResourceKey] = [.isDirectoryKey, .totalFileAllocatedSizeKey, .fileSizeKey, .isPackageKey]
            let children = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [])) ?? []
            var totals: [SizedItem] = []
            var biggest: [SizedItem] = []
            var count = 0
            var lastUI = 0.0

            func fileSize(_ values: URLResourceValues) -> Int64 {
                Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
            }

            func noteFile(_ file: URL, _ size: Int64) {
                biggest.append(SizedItem(url: file, size: size, isDirectory: false))
                if biggest.count > 400 {
                    biggest.sort { $0.size > $1.size }
                    biggest.removeLast(biggest.count - 200)
                }
                count += 1
                let now = ProcessInfo.processInfo.systemUptime
                if now - lastUI > 0.2 {
                    lastUI = now
                    let c = count
                    DispatchQueue.main.async { self?.scannedFiles = c }
                }
            }

            for child in children {
                if token.isCancelled { break }
                guard let values = try? child.resourceValues(forKeys: Set(keys)) else { continue }
                if values.isDirectory == true {
                    var sum: Int64 = 0
                    if let enumerator = fm.enumerator(at: child, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) {
                        for case let file as URL in enumerator {
                            if token.isCancelled { break }
                            guard let v = try? file.resourceValues(forKeys: Set(keys)), v.isDirectory != true else { continue }
                            let size = fileSize(v)
                            sum += size
                            noteFile(file, size)
                        }
                    }
                    totals.append(SizedItem(url: child, size: sum, isDirectory: true))
                } else {
                    let size = fileSize(values)
                    totals.append(SizedItem(url: child, size: size, isDirectory: false))
                    noteFile(child, size)
                }
                let snapshot = totals.sorted { $0.size > $1.size }
                DispatchQueue.main.async { self?.topLevel = snapshot }
            }
            biggest.sort { $0.size > $1.size }
            let finalTop = totals.sorted { $0.size > $1.size }
            let finalBiggest = Array(biggest.prefix(100))
            let finalCount = count
            let total = totals.reduce(Int64(0)) { $0 + $1.size }
            DispatchQueue.main.async {
                guard let self = self, self.token === token else { return }
                self.topLevel = finalTop
                self.largestFiles = finalBiggest
                self.scannedFiles = finalCount
                self.totalSize = total
                self.scanning = false
            }
        }
    }

    func cancel() {
        token?.cancel()
        token = nil
        scanning = false
    }

    func trash(_ item: SizedItem) {
        do {
            try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
            topLevel.removeAll { $0.url == item.url }
            largestFiles.removeAll { $0.url == item.url || $0.url.path.hasPrefix(item.url.path + "/") }
        } catch {
            NSSound.beep()
        }
    }
}

struct DiskUsageView: View {
    @StateObject private var scanner = DiskScanner()
    @State private var volumeInfo: [(String, Int64, Int64)] = []
    @State private var confirmTrash: SizedItem?

    var body: some View {
        ToolPage(tool: .diskUsage) {
            Card(title: "Volumes", icon: "internaldrive") {
                ForEach(volumeInfo, id: \.0) { volume in
                    let used = volume.1 - volume.2
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(volume.0).bold()
                            Spacer()
                            Text("\(Format.bytes(used)) used of \(Format.bytes(volume.1)) · \(Format.bytes(volume.2)) free")
                                .foregroundStyle(.secondary)
                        }
                        ProgressView(value: Double(used), total: Double(max(volume.1, 1)))
                    }
                }
            }

            Card(title: "Scan a Folder", icon: "magnifyingglass") {
                HStack {
                    Button("Choose Folder…") {
                        if let url = Panels.chooseFolder() { scanner.scan(url) }
                    }
                    Button("Home Folder") { scanner.scan(URL(fileURLWithPath: NSHomeDirectory())) }
                    Button("Downloads") {
                        scanner.scan(URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads"))
                    }
                    if scanner.scanning {
                        ProgressView().controlSize(.small)
                        Text("\(scanner.scannedFiles) files…").monospacedDigit().foregroundStyle(.secondary)
                        Button("Stop") { scanner.cancel() }
                    }
                    Spacer()
                    if let root = scanner.root, !scanner.scanning {
                        Text("\(root.lastPathComponent): \(Format.bytes(scanner.totalSize)) in \(scanner.scannedFiles) files")
                            .foregroundStyle(.secondary)
                    }
                }
                Text("Some folders need Full Disk Access (System Settings ▸ Privacy & Security) to be measured.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !scanner.topLevel.isEmpty {
                Card(title: "Biggest Items in Folder", icon: "chart.bar") {
                    let maxSize = Double(max(scanner.topLevel.first?.size ?? 1, 1))
                    ForEach(scanner.topLevel.prefix(40)) { item in
                        itemRow(item, maxSize: maxSize)
                    }
                }
            }

            if !scanner.largestFiles.isEmpty {
                Card(title: "Largest Files", icon: "doc") {
                    let maxSize = Double(max(scanner.largestFiles.first?.size ?? 1, 1))
                    ForEach(scanner.largestFiles.prefix(50)) { item in
                        itemRow(item, maxSize: maxSize)
                    }
                }
            }
        }
        .onAppear(perform: loadVolumes)
        .confirmationDialog("Move to Trash?", isPresented: Binding(get: { confirmTrash != nil }, set: { if !$0 { confirmTrash = nil } })) {
            Button("Move to Trash", role: .destructive) {
                if let item = confirmTrash { scanner.trash(item) }
                confirmTrash = nil
            }
        } message: {
            Text(confirmTrash?.url.path ?? "")
        }
    }

    private func itemRow(_ item: SizedItem, maxSize: Double) -> some View {
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                .resizable()
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(item.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(Format.bytes(item.size)).monospacedDigit().foregroundStyle(.secondary)
                }
                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.accentColor.opacity(0.6))
                        .frame(width: max(2, geo.size.width * CGFloat(Double(item.size) / maxSize)))
                }
                .frame(height: 4)
            }
            Button {
                Panels.reveal(item.url)
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("Show in Finder")
            Button {
                confirmTrash = item
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Move to Trash")
        }
    }

    private func loadVolumes() {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        volumeInfo = urls.compactMap { (url: URL) -> (String, Int64, Int64)? in
            guard let v = try? url.resourceValues(forKeys: Set(keys)), let total = v.volumeTotalCapacity, total > 0 else { return nil }
            let free = v.volumeAvailableCapacityForImportantUsage ?? Int64(v.volumeAvailableCapacity ?? 0)
            return (v.volumeName ?? url.lastPathComponent, Int64(total), free)
        }
    }
}

// MARK: - Duplicate finder

final class DuplicateScanner: ObservableObject {
    @Published private(set) var scanning = false
    @Published private(set) var status = ""
    @Published private(set) var groups: [[SizedItem]] = []
    @Published var minimumSizeKB = 1

    private var token: CancelToken?

    var wasted: Int64 {
        groups.reduce(Int64(0)) { $0 + Int64($1.count - 1) * ($1.first?.size ?? 0) }
    }

    func scan(_ folder: URL) {
        cancel()
        scanning = true
        groups = []
        status = "Listing files…"
        let token = CancelToken()
        self.token = token
        let minimum = Int64(max(0, minimumSizeKB)) * 1024
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            func report(_ text: String) { DispatchQueue.main.async { self?.status = text } }
            let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
            var bySize: [Int64: [URL]] = [:]
            var count = 0
            if let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in true }) {
                for case let url as URL in enumerator {
                    if token.isCancelled { break }
                    guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
                    let size = Int64(v.fileSize ?? 0)
                    if size < max(1, minimum) { continue }
                    bySize[size, default: []].append(url)
                    count += 1
                    if count % 500 == 0 { report("Listed \(count) files…") }
                }
            }
            let candidates = bySize.filter { $0.value.count > 1 }
            var result: [[SizedItem]] = []
            var hashed = 0
            let totalCandidates = candidates.values.reduce(0) { $0 + $1.count }
            for (size, urls) in candidates {
                if token.isCancelled { break }
                var byHash: [String: [URL]] = [:]
                for url in urls {
                    if token.isCancelled { break }
                    if let digest = DuplicateScanner.sha256(url, token: token) {
                        byHash[digest, default: []].append(url)
                    }
                    hashed += 1
                    if hashed % 20 == 0 { report("Comparing \(hashed) of \(totalCandidates) possible duplicates…") }
                }
                for (_, same) in byHash where same.count > 1 {
                    result.append(same.map { SizedItem(url: $0, size: size, isDirectory: false) })
                }
            }
            result.sort { Int64($0.count - 1) * ($0.first?.size ?? 0) > Int64($1.count - 1) * ($1.first?.size ?? 0) }
            let final = result
            let scannedCount = count
            DispatchQueue.main.async {
                guard let self = self, self.token === token else { return }
                self.groups = final
                self.scanning = false
                self.status = "Scanned \(scannedCount) files · \(final.count) duplicate groups"
            }
        }
    }

    static func sha256(_ url: URL, token: CancelToken) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while !token.isCancelled {
            let chunk = autoreleasepool { handle.readData(ofLength: 2 * 1024 * 1024) }
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func cancel() {
        token?.cancel()
        token = nil
        scanning = false
    }

    func trash(_ item: SizedItem) {
        do {
            try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
            groups = groups.map { $0.filter { $0.url != item.url } }.filter { $0.count > 1 }
        } catch {
            NSSound.beep()
        }
    }
}

struct DuplicateFinderView: View {
    @StateObject private var scanner = DuplicateScanner()

    var body: some View {
        ToolPage(tool: .duplicateFinder) {
            Card(title: "Scan", icon: "magnifyingglass") {
                HStack {
                    Button("Choose Folder…") {
                        if let url = Panels.chooseFolder() { scanner.scan(url) }
                    }
                    .disabled(scanner.scanning)
                    IntField(title: "Ignore files smaller than", value: $scanner.minimumSizeKB, unit: "KB")
                    if scanner.scanning {
                        ProgressView().controlSize(.small)
                        Button("Stop") { scanner.cancel() }
                    }
                    Spacer()
                }
                Text(scanner.status).foregroundStyle(.secondary)
                if !scanner.groups.isEmpty {
                    Text("You could free up \(Format.bytes(scanner.wasted)) by removing duplicates.")
                        .bold()
                }
            }

            ForEach(Array(scanner.groups.prefix(200).enumerated()), id: \.offset) { item in
                let group = item.element
                Card(title: "\(group.count) copies · \(Format.bytes(group.first?.size ?? 0)) each", icon: "doc.on.doc") {
                    ForEach(group) { file in
                        HStack {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: file.url.path))
                                .resizable()
                                .frame(width: 18, height: 18)
                            Text(file.url.path)
                                .font(.callout)
                                .lineLimit(1)
                                .truncationMode(.head)
                            Spacer()
                            Button("Show") { Panels.reveal(file.url) }
                            Button(role: .destructive) {
                                scanner.trash(file)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .help("Move this copy to the Trash")
                        }
                    }
                }
            }
        }
    }
}
