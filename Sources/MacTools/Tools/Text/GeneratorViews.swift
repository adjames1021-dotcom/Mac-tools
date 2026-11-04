import SwiftUI
import AppKit
import CryptoKit
import CoreImage
import CoreImage.CIFilterBuiltins
import UniformTypeIdentifiers

// MARK: - Password generator

struct PasswordGeneratorView: View {
    @State private var options = Prefs.load("passwordOptions", default: PasswordGenerator.Options())
    @State private var passwords: [String] = []
    @State private var count = 5
    @State private var mode = 0
    @State private var wordCount = 5
    @State private var separator = "-"
    @State private var capitalize = true
    @State private var addNumber = true

    private var bits: Double {
        mode == 0 ? PasswordGenerator.entropy(options) : PasswordGenerator.passphraseEntropy(words: wordCount)
    }

    var body: some View {
        ToolPage(tool: .passwordGenerator) {
            Picker("", selection: $mode) {
                Text("Password").tag(0)
                Text("Passphrase").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 300)

            Card(title: "Options", icon: "slider.horizontal.3") {
                if mode == 0 {
                    HStack {
                        Text("Length: \(options.length)").frame(width: 90, alignment: .leading)
                        Slider(value: Binding(get: { Double(options.length) }, set: { options.length = Int($0) }), in: 4...128, step: 1)
                    }
                    HStack(spacing: 18) {
                        Toggle("A–Z", isOn: $options.useUpper)
                        Toggle("a–z", isOn: $options.useLower)
                        Toggle("0–9", isOn: $options.useDigits)
                        Toggle("!@#$", isOn: $options.useSymbols)
                        Toggle("Avoid look-alikes (0 O 1 l I)", isOn: $options.avoidAmbiguous)
                    }
                } else {
                    Stepper("Words: \(wordCount)", value: $wordCount, in: 3...12)
                    HStack(spacing: 18) {
                        Picker("Separator", selection: $separator) {
                            Text("Hyphen -").tag("-")
                            Text("Space").tag(" ")
                            Text("Dot .").tag(".")
                            Text("Underscore _").tag("_")
                            Text("None").tag("")
                        }
                        .frame(width: 220)
                        Toggle("Capitalise", isOn: $capitalize)
                        Toggle("Add a number", isOn: $addNumber)
                    }
                }
                HStack {
                    Stepper("Generate \(count)", value: $count, in: 1...50)
                    Spacer()
                    Text(String(format: "%.0f bits · %@", bits, PasswordGenerator.strengthLabel(bits)))
                        .foregroundColor(bits < 60 ? Color.orange : Color.green)
                }
                ProgressView(value: min(bits, 128), total: 128)
                Button {
                    generate()
                } label: {
                    Label("Generate", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("g", modifiers: [.command])
            }

            Card(title: "Results", icon: "key") {
                ForEach(Array(passwords.enumerated()), id: \.offset) { item in
                    HStack {
                        Text(item.element)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(1)
                        Spacer()
                        CopyButton(text: item.element)
                    }
                }
                if passwords.count > 1 {
                    CopyButton(text: passwords.joined(separator: "\n"), label: "Copy All")
                }
            }
        }
        .onAppear { if passwords.isEmpty { generate() } }
        .onChange(of: options) { newValue in
            Prefs.save("passwordOptions", newValue)
            generate()
        }
    }

    private func generate() {
        passwords = (0..<count).map { _ in
            mode == 0
                ? PasswordGenerator.generate(options)
                : PasswordGenerator.passphrase(words: wordCount, separator: separator, capitalize: capitalize, addNumber: addNumber)
        }
    }
}

// MARK: - Hash tool

struct HashToolView: View {
    @AppStorage("hashText") private var text = "Hello, world!"
    @State private var hmacKey = ""
    @State private var fileURL: URL?
    @State private var fileHashes: [(String, String)] = []
    @State private var fileProgress: Double?
    @State private var compare = ""
    @State private var uppercase = false

    private func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        let s = bytes.map { String(format: "%02x", $0) }.joined()
        return uppercase ? s.uppercased() : s
    }

    private var textHashes: [(String, String)] {
        let data = Data(text.utf8)
        var rows: [(String, String)] = [
            ("MD5", hex(Insecure.MD5.hash(data: data))),
            ("SHA-1", hex(Insecure.SHA1.hash(data: data))),
            ("SHA-256", hex(SHA256.hash(data: data))),
            ("SHA-384", hex(SHA384.hash(data: data))),
            ("SHA-512", hex(SHA512.hash(data: data))),
            ("Base64", data.base64EncodedString())
        ]
        if !hmacKey.isEmpty {
            let key = SymmetricKey(data: Data(hmacKey.utf8))
            rows.append(("HMAC-SHA256", hex(HMAC<SHA256>.authenticationCode(for: data, using: key))))
            rows.append(("HMAC-SHA512", hex(HMAC<SHA512>.authenticationCode(for: data, using: key))))
        }
        return rows
    }

    var body: some View {
        ToolPage(tool: .hashTool) {
            Card(title: "Text", icon: "text.alignleft") {
                CodeEditor(text: $text, minHeight: 80).frame(height: 100)
                HStack {
                    TextField("HMAC secret key (optional)", text: $hmacKey)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 320)
                    Toggle("Uppercase hex", isOn: $uppercase)
                }
                hashRows(textHashes)
            }

            Card(title: "File Checksum", icon: "doc") {
                HStack {
                    Button("Choose File…") {
                        if let url = Panels.chooseFiles(multiple: false).first { hashFile(url) }
                    }
                    if let url = fileURL {
                        Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                    } else {
                        Text("…or drop a file onto this box").foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                if let progress = fileProgress {
                    ProgressView(value: progress)
                }
                if !fileHashes.isEmpty {
                    hashRows(fileHashes)
                }
                TextField("Paste an expected checksum to verify", text: $compare)
                    .textFieldStyle(.roundedBorder)
                if !compare.trimmed.isEmpty {
                    let target = compare.trimmed.lowercased()
                    let all = (fileHashes + textHashes).map { ($0.0, $0.1.lowercased()) }
                    if let hit = all.first(where: { $0.1 == target }) {
                        Label("Match: \(hit.0)", systemImage: "checkmark.seal.fill").foregroundColor(.green)
                    } else {
                        Label("No match", systemImage: "xmark.octagon.fill").foregroundColor(.red)
                    }
                }
            }
            .acceptsFileDrops { urls in
                if let url = urls.first { hashFile(url) }
            }
        }
    }

    private func hashRows(_ rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(rows, id: \.0) { row in
                HStack(alignment: .top) {
                    Text(row.0).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
                    Text(row.1)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    CopyButton(text: row.1)
                }
            }
        }
    }

    private func hashFile(_ url: URL) {
        fileURL = url
        fileHashes = []
        fileProgress = 0
        let upper = uppercase
        DispatchQueue.global(qos: .userInitiated).async {
            guard let handle = try? FileHandle(forReadingFrom: url) else {
                DispatchQueue.main.async { fileProgress = nil }
                return
            }
            let total = Double((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 1)
            var md5 = Insecure.MD5()
            var sha1 = Insecure.SHA1()
            var sha256 = SHA256()
            var sha512 = SHA512()
            var read = 0.0
            var lastReport = 0.0
            while true {
                let chunk = autoreleasepool { handle.readData(ofLength: 4 * 1024 * 1024) }
                if chunk.isEmpty { break }
                md5.update(data: chunk)
                sha1.update(data: chunk)
                sha256.update(data: chunk)
                sha512.update(data: chunk)
                read += Double(chunk.count)
                if read - lastReport > 32 * 1024 * 1024 {
                    lastReport = read
                    let p = read / max(total, 1)
                    DispatchQueue.main.async { fileProgress = p }
                }
            }
            try? handle.close()
            func h<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
                let s = bytes.map { String(format: "%02x", $0) }.joined()
                return upper ? s.uppercased() : s
            }
            let rows: [(String, String)] = [
                ("MD5", h(md5.finalize())),
                ("SHA-1", h(sha1.finalize())),
                ("SHA-256", h(sha256.finalize())),
                ("SHA-512", h(sha512.finalize())),
                ("Size", Format.bytes(Int64(read)) + " (\(Int64(read)) bytes)")
            ]
            DispatchQueue.main.async {
                fileHashes = rows
                fileProgress = nil
            }
        }
    }
}

// MARK: - QR codes

enum QRTools {
    static func generate(_ text: String, correction: String, scale: CGFloat) -> NSImage? {
        guard !text.isEmpty else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = correction
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) else { return nil }
        let context = CIContext()
        guard let cg = context.createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: output.extent.width, height: output.extent.height))
    }

    static func decode(_ image: CIImage) -> [String] {
        let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        let features = detector?.features(in: image) ?? []
        return features.compactMap { ($0 as? CIQRCodeFeature)?.messageString }
    }

    static func decode(nsImage: NSImage) -> [String] {
        guard let tiff = nsImage.tiffRepresentation, let ci = CIImage(data: tiff) else { return [] }
        return decode(ci)
    }

    static func pngData(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

struct QRCodeView: View {
    @AppStorage("qrText") private var text = "https://www.apple.com"
    @State private var kind = 0
    @State private var wifiName = ""
    @State private var wifiPassword = ""
    @State private var wifiSecurity = "WPA"
    @State private var correction = "M"
    @State private var decoded: [String] = []
    @State private var decodeStatus = ""

    private var payload: String {
        if kind == 1 {
            func esc(_ s: String) -> String {
                var out = s
                for ch in ["\\", ";", ",", ":", "\""] { out = out.replacingOccurrences(of: ch, with: "\\" + ch) }
                return out
            }
            return "WIFI:T:\(wifiSecurity);S:\(esc(wifiName));P:\(esc(wifiPassword));;"
        }
        return text
    }

    var body: some View {
        ToolPage(tool: .qrCode) {
            Card(title: "Create a QR Code", icon: "qrcode") {
                Picker("", selection: $kind) {
                    Text("Text / URL").tag(0)
                    Text("Wi-Fi Network").tag(1)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 300)
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 10) {
                        if kind == 0 {
                            CodeEditor(text: $text, minHeight: 100, monospaced: false).frame(height: 120)
                        } else {
                            TextField("Network name (SSID)", text: $wifiName).textFieldStyle(.roundedBorder)
                            SecureField("Password", text: $wifiPassword).textFieldStyle(.roundedBorder)
                            Picker("Security", selection: $wifiSecurity) {
                                Text("WPA/WPA2/WPA3").tag("WPA")
                                Text("WEP").tag("WEP")
                                Text("None").tag("nopass")
                            }
                        }
                        Picker("Error correction", selection: $correction) {
                            Text("Low (7%)").tag("L")
                            Text("Medium (15%)").tag("M")
                            Text("Quartile (25%)").tag("Q")
                            Text("High (30%)").tag("H")
                        }
                        .frame(maxWidth: 280)
                    }
                    let image = QRTools.generate(payload, correction: correction, scale: 12)
                    VStack(spacing: 8) {
                        if let image = image {
                            Image(nsImage: image)
                                .interpolation(.none)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 220, height: 220)
                                .background(Color.white)
                            HStack {
                                Button("Copy Image") { ClipboardHelper.copy(image: image) }
                                Button("Save PNG…") {
                                    if let url = Panels.saveFile(name: "QR Code.png", types: [.png]), let data = QRTools.pngData(image) {
                                        try? data.write(to: url)
                                    }
                                }
                            }
                        } else {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.primary.opacity(0.05))
                                .frame(width: 220, height: 220)
                                .overlay(Text("Enter text").foregroundStyle(.secondary))
                        }
                    }
                }
            }

            Card(title: "Read a QR Code", icon: "qrcode.viewfinder") {
                HStack {
                    Button("From Image File…") {
                        if let url = Panels.chooseFiles(multiple: false, types: [.image]).first,
                           let ci = CIImage(contentsOf: url) {
                            show(QRTools.decode(ci))
                        }
                    }
                    Button("From Clipboard") {
                        let images = NSPasteboard.general.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage] ?? []
                        if let image = images.first { show(QRTools.decode(nsImage: image)) } else { decodeStatus = "No image on the clipboard." }
                    }
                    Button("Scan Area of Screen…") { scanScreen() }
                    Spacer()
                }
                if !decodeStatus.isEmpty {
                    Text(decodeStatus).foregroundStyle(.secondary)
                }
                ForEach(Array(decoded.enumerated()), id: \.offset) { item in
                    HStack {
                        Text(item.element).textSelection(.enabled)
                        Spacer()
                        if let url = URL(string: item.element), url.scheme?.hasPrefix("http") == true {
                            Button("Open") { NSWorkspace.shared.open(url) }
                        }
                        CopyButton(text: item.element)
                    }
                }
            }
            .acceptsFileDrops { urls in
                if let url = urls.first, let ci = CIImage(contentsOf: url) { show(QRTools.decode(ci)) }
            }
        }
    }

    private func show(_ results: [String]) {
        decoded = results
        decodeStatus = results.isEmpty ? "No QR code found." : "Found \(results.count) code(s)."
    }

    private func scanScreen() {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("mactools-qr-scan.png")
        try? FileManager.default.removeItem(at: temp)
        decodeStatus = "Drag over the QR code on screen…"
        DispatchQueue.global(qos: .userInitiated).async {
            Shell.runSync("/usr/sbin/screencapture", ["-i", "-x", temp.path])
            let results: [String]
            if let ci = CIImage(contentsOf: temp) {
                results = QRTools.decode(ci)
            } else {
                results = []
            }
            try? FileManager.default.removeItem(at: temp)
            DispatchQueue.main.async { show(results) }
        }
    }
}

// MARK: - Random generator

struct RandomGeneratorView: View {
    @State private var minValue = 1
    @State private var maxValue = 100
    @State private var howMany = 1
    @State private var unique = false
    @State private var numbers: [Int] = []
    @State private var diceNotation = "2d6"
    @State private var diceResult = ""
    @State private var coin = ""
    @State private var uuidCount = 5
    @State private var uuidUpper = true
    @State private var uuidDashes = true
    @State private var uuids: [String] = []
    @AppStorage("randomList") private var listText = "Pizza\nSushi\nTacos\nBurgers\nSalad"
    @State private var picked = ""

    var body: some View {
        ToolPage(tool: .randomGenerator) {
            Card(title: "Random Numbers", icon: "number") {
                HStack(spacing: 16) {
                    IntField(title: "From", value: $minValue)
                    IntField(title: "To", value: $maxValue)
                    IntField(title: "How many", value: $howMany, width: 60)
                    Toggle("No repeats", isOn: $unique)
                    Button("Generate") { generateNumbers() }
                        .buttonStyle(.borderedProminent)
                }
                if !numbers.isEmpty {
                    let joined = numbers.map(String.init).joined(separator: ", ")
                    HStack {
                        Text(joined)
                            .font(.system(size: numbers.count == 1 ? 40 : 16, weight: .semibold, design: .rounded))
                            .textSelection(.enabled)
                        Spacer()
                        CopyButton(text: joined)
                    }
                }
            }

            HStack(alignment: .top, spacing: 16) {
                Card(title: "Dice", icon: "dice") {
                    HStack {
                        TextField("e.g. 2d6+1", text: $diceNotation)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 110)
                        Button("Roll") {
                            if let r = RandomTools.dice(diceNotation) {
                                diceResult = "\(r.total)   (\(r.rolls.map(String.init).joined(separator: " + ")))"
                            } else {
                                diceResult = "Use notation like 2d6, d20 or 3d8+2"
                            }
                        }
                    }
                    HStack {
                        ForEach(["d4", "d6", "d8", "d10", "d12", "d20", "d100"], id: \.self) { d in
                            Button(d) {
                                diceNotation = d
                                if let r = RandomTools.dice(d) { diceResult = "\(r.total)" }
                            }
                        }
                    }
                    Text(diceResult).font(.title2.bold())
                }
                Card(title: "Coin Flip", icon: "circle.lefthalf.filled") {
                    Button("Flip") { coin = Bool.random() ? "Heads" : "Tails" }
                    Text(coin).font(.title.bold())
                }
            }

            Card(title: "Pick from a List", icon: "list.bullet") {
                CodeEditor(text: $listText, minHeight: 80, monospaced: false).frame(height: 100)
                HStack {
                    Button("Pick One") {
                        let items = listText.components(separatedBy: .newlines).map { $0.trimmed }.filter { !$0.isEmpty }
                        picked = items.randomElement() ?? ""
                    }
                    Button("Shuffle List") {
                        listText = listText.components(separatedBy: .newlines).filter { !$0.trimmed.isEmpty }.shuffled().joined(separator: "\n")
                    }
                    Text(picked).font(.title2.bold())
                }
            }

            Card(title: "UUIDs", icon: "barcode") {
                HStack(spacing: 16) {
                    Stepper("Count: \(uuidCount)", value: $uuidCount, in: 1...100)
                    Toggle("Uppercase", isOn: $uuidUpper)
                    Toggle("Dashes", isOn: $uuidDashes)
                    Button("Generate") {
                        uuids = (0..<uuidCount).map { _ in
                            var s = UUID().uuidString
                            if !uuidUpper { s = s.lowercased() }
                            if !uuidDashes { s = s.replacingOccurrences(of: "-", with: "") }
                            return s
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    if !uuids.isEmpty { CopyButton(text: uuids.joined(separator: "\n"), label: "Copy All") }
                }
                if !uuids.isEmpty {
                    OutputBox(text: uuids.joined(separator: "\n"), minHeight: 60, maxHeight: 200)
                }
            }
        }
    }

    private func generateNumbers() {
        let lo = min(minValue, maxValue)
        let hi = max(minValue, maxValue)
        let n = max(1, min(howMany, 10_000))
        if unique {
            let span = hi - lo + 1
            if n >= span {
                numbers = Array(lo...hi).shuffled()
            } else {
                var set = Set<Int>()
                while set.count < n { set.insert(Int.random(in: lo...hi)) }
                numbers = Array(set).shuffled()
            }
        } else {
            numbers = (0..<n).map { _ in Int.random(in: lo...hi) }
        }
    }
}
