import SwiftUI
import AppKit
import CryptoKit
import CommonCrypto
import WebKit
import UniformTypeIdentifiers

// MARK: - JWT decoder

struct JWTDecoderView: View {
    @AppStorage("jwtToken") private var token = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"
    @State private var secret = "your-256-bit-secret"

    var body: some View {
        ToolPage(tool: .jwtDecoder) {
            Card(title: "Token", icon: "key.horizontal") {
                CodeEditor(text: $token, minHeight: 80).frame(height: 100)
                HStack {
                    Button("Paste") { if let s = ClipboardHelper.string { token = s.trimmed } }
                    Text("Tokens are decoded on your Mac and never sent anywhere.").font(.caption).foregroundStyle(.secondary)
                }
            }
            switch Result(catching: { try DecodedJWT(token) }) {
            case .success(let jwt):
                decoded(jwt)
            case .failure(let error):
                Label((error as? LocalizedError)?.errorDescription ?? "Invalid token", systemImage: "xmark.octagon.fill")
                    .foregroundColor(.red)
            }
        }
    }

    private func decoded(_ jwt: DecodedJWT) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Card(title: "Header", icon: "doc.text") {
                    OutputBox(text: jwt.header, minHeight: 80, maxHeight: 200)
                }
                Card(title: "Payload", icon: "shippingbox") {
                    OutputBox(text: jwt.payload, minHeight: 80, maxHeight: 300)
                }
            }
            Card(title: "Claims", icon: "calendar.badge.clock") {
                InfoRow(label: "Algorithm", value: jwt.headerAlgorithm)
                ForEach(["iat", "nbf", "exp"], id: \.self) { claim in
                    if let date = jwt.date(claim) {
                        InfoRow(label: claimName(claim), value: date.formatted(date: .abbreviated, time: .standard)
                                + " (" + RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date()) + ")")
                    }
                }
                ForEach(["sub", "iss", "aud", "jti"], id: \.self) { claim in
                    if let value = jwt.claims[claim] {
                        InfoRow(label: claimName(claim), value: "\(value)")
                    }
                }
                if let expired = jwt.isExpired {
                    Label(expired ? "This token has expired" : "This token is still valid (not expired)",
                          systemImage: expired ? "clock.badge.exclamationmark" : "checkmark.seal")
                        .foregroundColor(expired ? Color.red : Color.green)
                }
            }
            Card(title: "Verify Signature", icon: "signature") {
                if jwt.headerAlgorithm.hasPrefix("HS") {
                    HStack {
                        TextField("Secret", text: $secret).textFieldStyle(.roundedBorder)
                        if let valid = verify(jwt) {
                            Label(valid ? "Signature verified" : "Invalid signature",
                                  systemImage: valid ? "checkmark.seal.fill" : "xmark.seal.fill")
                                .foregroundColor(valid ? Color.green : Color.red)
                        }
                    }
                } else {
                    Text("Signature checking here supports HMAC tokens (HS256, HS384, HS512). This token uses \(jwt.headerAlgorithm).")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func claimName(_ claim: String) -> String {
        switch claim {
        case "iat": return "Issued at (iat)"
        case "nbf": return "Not before (nbf)"
        case "exp": return "Expires (exp)"
        case "sub": return "Subject (sub)"
        case "iss": return "Issuer (iss)"
        case "aud": return "Audience (aud)"
        case "jti": return "Token ID (jti)"
        default: return claim
        }
    }

    private func verify(_ jwt: DecodedJWT) -> Bool? {
        let key = SymmetricKey(data: Data(secret.utf8))
        let input = Data(jwt.signingInput.utf8)
        let mac: Data
        switch jwt.headerAlgorithm {
        case "HS256": mac = Data(HMAC<SHA256>.authenticationCode(for: input, using: key))
        case "HS384": mac = Data(HMAC<SHA384>.authenticationCode(for: input, using: key))
        case "HS512": mac = Data(HMAC<SHA512>.authenticationCode(for: input, using: key))
        default: return nil
        }
        let encoded = mac.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return encoded == jwt.signature
    }
}

// MARK: - URL parser

struct QueryParam: Identifiable, Equatable {
    let id = UUID()
    var name: String
    var value: String
}

struct URLParserView: View {
    @AppStorage("urlParserInput") private var input = "https://user:pass@example.com:8080/path/to/page?search=mac+tools&page=2&lang=en#results"
    @State private var params: [QueryParam] = []

    private var components: URLComponents? { URLComponents(string: input.trimmed) }

    var body: some View {
        ToolPage(tool: .urlParser) {
            Card(title: "URL", icon: "link") {
                TextField("https://…", text: $input)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                HStack {
                    Button("Paste") { if let s = ClipboardHelper.string { input = s.trimmed } }
                    Button("Encode") { input = input.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? input }
                    Button("Decode") { input = input.removingPercentEncoding ?? input }
                    if let url = URL(string: input.trimmed), url.scheme != nil {
                        Button("Open in Browser") { NSWorkspace.shared.open(url) }
                    }
                }
            }
            if let c = components {
                Card(title: "Parts", icon: "list.bullet.rectangle") {
                    InfoRow(label: "Scheme", value: c.scheme ?? "")
                    InfoRow(label: "User", value: c.user ?? "")
                    InfoRow(label: "Password", value: c.password ?? "")
                    InfoRow(label: "Host", value: c.host ?? "")
                    InfoRow(label: "Port", value: c.port.map { "\($0)" } ?? "")
                    InfoRow(label: "Path", value: c.path)
                    InfoRow(label: "Path segments", value: c.path.split(separator: "/").joined(separator: "  ›  "))
                    InfoRow(label: "Query", value: c.query ?? "")
                    InfoRow(label: "Fragment", value: c.fragment ?? "")
                }
                Card(title: "Query Parameters", icon: "slider.horizontal.3") {
                    ForEach($params) { $param in
                        HStack {
                            TextField("name", text: $param.name).textFieldStyle(.roundedBorder).frame(width: 180)
                            Text("=")
                            TextField("value", text: $param.value).textFieldStyle(.roundedBorder)
                            Button {
                                params.removeAll { $0.id == param.id }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    HStack {
                        Button {
                            params.append(QueryParam(name: "", value: ""))
                        } label: {
                            Label("Add Parameter", systemImage: "plus")
                        }
                        Button("Apply to URL") { rebuild() }
                            .buttonStyle(.borderedProminent)
                        Button("Reload from URL") { loadParams() }
                    }
                }
            } else {
                Label("That isn't a valid URL.", systemImage: "xmark.octagon.fill").foregroundColor(.red)
            }
        }
        .onAppear(perform: loadParams)
    }

    private func loadParams() {
        params = (components?.queryItems ?? []).map { QueryParam(name: $0.name, value: $0.value ?? "") }
    }

    private func rebuild() {
        guard var c = components else { return }
        let items = params.filter { !$0.name.isEmpty }.map { URLQueryItem(name: $0.name, value: $0.value) }
        c.queryItems = items.isEmpty ? nil : items
        if let s = c.string { input = s }
    }
}

// MARK: - CSV ⇄ JSON

struct CSVJSONView: View {
    @AppStorage("csvInput") private var csv = "name,language,stars\nMacTools,Swift,42\n\"Tools, Inc.\",Go,7"
    @AppStorage("jsonInputCSV") private var json = ""
    @State private var delimiter = ","
    @State private var header = true
    @State private var inferTypes = true
    @State private var message = ""

    private var delimiterChar: Character { delimiter == "tab" ? "\t" : Character(delimiter) }

    var body: some View {
        ToolPage(tool: .csvJson) {
            HStack(spacing: 16) {
                Picker("Delimiter", selection: $delimiter) {
                    Text("Comma ,").tag(",")
                    Text("Semicolon ;").tag(";")
                    Text("Tab").tag("tab")
                    Text("Pipe |").tag("|")
                }
                .frame(width: 200)
                Toggle("First row is a header", isOn: $header)
                Toggle("Detect numbers & booleans", isOn: $inferTypes)
            }
            if !message.isEmpty {
                Text(message).font(.caption).foregroundColor(.red)
            }
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("CSV").font(.headline)
                        Spacer()
                        Button("Open…") { load { csv = $0 } }
                        CopyButton(text: csv)
                    }
                    CodeEditor(text: $csv, minHeight: 300).frame(height: 340)
                    Button {
                        do {
                            json = try CSVTools.csvToJSON(csv, delimiter: delimiterChar, header: header, inferTypes: inferTypes)
                            message = ""
                        } catch {
                            message = error.localizedDescription
                        }
                    } label: {
                        Label("CSV → JSON", systemImage: "arrow.right")
                    }
                    .buttonStyle(.borderedProminent)
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("JSON").font(.headline)
                        Spacer()
                        Button("Open…") { load { json = $0 } }
                        CopyButton(text: json)
                    }
                    CodeEditor(text: $json, minHeight: 300).frame(height: 340)
                    Button {
                        do {
                            csv = try CSVTools.jsonToCSV(json, delimiter: delimiterChar)
                            message = ""
                        } catch {
                            message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                        }
                    } label: {
                        Label("JSON → CSV", systemImage: "arrow.left")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            let rows = CSVTools.parse(csv, delimiter: delimiterChar)
            if !rows.isEmpty {
                Card(title: "Table Preview (\(max(0, rows.count - (header ? 1 : 0))) rows)", icon: "tablecells") {
                    ScrollView(.horizontal) {
                        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                            ForEach(Array(rows.prefix(30).enumerated()), id: \.offset) { item in
                                GridRow {
                                    ForEach(Array(item.element.enumerated()), id: \.offset) { cell in
                                        Text(cell.element)
                                            .font(.system(.callout, design: .monospaced))
                                            .fontWeight(header && item.offset == 0 ? Font.Weight.bold : Font.Weight.regular)
                                            .lineLimit(1)
                                    }
                                }
                            }
                        }
                        .padding(6)
                    }
                }
            }
        }
    }

    private func load(_ apply: (String) -> Void) {
        guard let url = Panels.chooseFiles(multiple: false).first,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        apply(text)
    }
}

// MARK: - Cron helper

struct CronHelperView: View {
    @AppStorage("cronExpression") private var expression = "*/15 9-17 * * MON-FRI"

    private let presets: [(String, String)] = [
        ("Every minute", "* * * * *"), ("Every 5 minutes", "*/5 * * * *"), ("Every hour", "0 * * * *"),
        ("Every day at 9:00", "0 9 * * *"), ("Weekdays at 9:00", "0 9 * * 1-5"), ("Every Sunday at midnight", "0 0 * * 0"),
        ("First day of the month", "0 0 1 * *"), ("Every 15 min, office hours", "*/15 9-17 * * MON-FRI")
    ]

    var body: some View {
        ToolPage(tool: .cronHelper) {
            Card(title: "Expression", icon: "calendar.badge.clock") {
                TextField("minute hour day month weekday", text: $expression)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.title3, design: .monospaced))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 6)], alignment: .leading, spacing: 6) {
                    ForEach(presets, id: \.1) { preset in
                        Button(preset.0) { expression = preset.1 }
                    }
                }
            }
            switch Result(catching: { try CronExpression(expression) }) {
            case .success(let cron):
                Card(title: "Meaning", icon: "text.bubble") {
                    Text(cron.description).font(.title3)
                }
                Card(title: "Next 10 Runs", icon: "list.number") {
                    ForEach(cron.nextRuns(after: Date(), count: 10), id: \.self) { date in
                        HStack {
                            Text(date.formatted(date: .complete, time: .shortened))
                            Spacer()
                            Text(RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date()))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            case .failure(let error):
                Label((error as? LocalizedError)?.errorDescription ?? "Invalid expression", systemImage: "xmark.octagon.fill")
                    .foregroundColor(.red)
            }
            Card(title: "Cheat Sheet", icon: "book") {
                let rows: [(String, String)] = [
                    ("Fields", "minute (0-59)  hour (0-23)  day (1-31)  month (1-12 or JAN-DEC)  weekday (0-6 or SUN-SAT)"),
                    ("*", "every value"), ("*/n", "every n (e.g. */10 = every 10)"), ("a-b", "range (e.g. 9-17)"),
                    ("a,b,c", "list (e.g. MON,WED,FRI)"), ("@daily @hourly @weekly @monthly", "shortcuts")
                ]
                ForEach(rows, id: \.0) { row in
                    HStack(alignment: .top) {
                        Text(row.0).font(.system(.callout, design: .monospaced)).frame(width: 220, alignment: .leading)
                        Text(row.1).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

// MARK: - Markdown editor

struct HTMLPreview: NSViewRepresentable {
    let html: String

    func makeNSView(context: Context) -> WKWebView {
        WKWebView()
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        view.loadHTMLString(html, baseURL: nil)
    }
}

struct MarkdownView: View {
    @AppStorage("markdownText") private var text = "# Hello Markdown\n\nWrite **bold**, *italic*, `code` and [links](https://www.apple.com).\n\n- Lists\n- [x] Checkboxes\n\n```swift\nprint(\"Hello\")\n```\n\n> Quotes too."

    var body: some View {
        ToolPage(tool: .markdownPreview, scrolls: false) {
            HStack {
                Button("Open…") {
                    if let url = Panels.chooseFiles(multiple: false).first, let s = try? String(contentsOf: url, encoding: .utf8) {
                        text = s
                    }
                }
                Button("Save Markdown…") {
                    if let url = Panels.saveFile(name: "Document.md") { try? text.write(to: url, atomically: true, encoding: .utf8) }
                }
                Button("Export HTML…") {
                    if let url = Panels.saveFile(name: "Document.html", types: [.html]) {
                        try? MarkdownRenderer.document(text).write(to: url, atomically: true, encoding: .utf8)
                    }
                }
                CopyButton(text: MarkdownRenderer.html(text), label: "Copy HTML")
                Spacer()
                Text("\(TextStats(text).words) words").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                CodeEditor(text: $text, minHeight: 300)
                    .frame(maxHeight: .infinity)
                HTMLPreview(html: MarkdownRenderer.document(text))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.15)))
            }
            .frame(maxHeight: .infinity)
        }
    }
}

// MARK: - Encryption

enum CryptoTools {
    static let magic = Data("MTE1".utf8)

    enum CryptoError: Error, LocalizedError {
        case keyDerivation, notEncrypted, wrongPassword
        var errorDescription: String? {
            switch self {
            case .keyDerivation: return "Couldn't derive a key from the password."
            case .notEncrypted: return "This doesn't look like something MacTools encrypted."
            case .wrongPassword: return "Wrong password (or the data was changed)."
            }
        }
    }

    static func key(password: String, salt: Data) throws -> SymmetricKey {
        var derived = [UInt8](repeating: 0, count: 32)
        let saltBytes = [UInt8](salt)
        let status = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                          password, password.utf8.count,
                                          saltBytes, saltBytes.count,
                                          CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 200_000,
                                          &derived, derived.count)
        guard status == Int32(kCCSuccess) else { throw CryptoError.keyDerivation }
        return SymmetricKey(data: Data(derived))
    }

    /// AES-256-GCM with a PBKDF2-SHA256 key. Format: "MTE1" + salt(16) + nonce + ciphertext + tag.
    static func encrypt(_ data: Data, password: String) throws -> Data {
        let salt = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let sealed = try AES.GCM.seal(data, using: key(password: password, salt: salt))
        guard let combined = sealed.combined else { throw CryptoError.keyDerivation }
        return magic + salt + combined
    }

    static func decrypt(_ data: Data, password: String) throws -> Data {
        let bytes = Data(data)
        guard bytes.count > 4 + 16 + 12 + 16, bytes.prefix(4) == magic else { throw CryptoError.notEncrypted }
        let salt = bytes.subdata(in: 4..<20)
        let combined = bytes.subdata(in: 20..<bytes.count)
        do {
            let box = try AES.GCM.SealedBox(combined: combined)
            return try AES.GCM.open(box, using: key(password: password, salt: salt))
        } catch {
            throw CryptoError.wrongPassword
        }
    }
}

struct EncryptionView: View {
    @State private var encryptMode = true
    @State private var password = ""
    @State private var input = ""
    @State private var output = ""
    @State private var message = ""
    @State private var isError = false

    var body: some View {
        ToolPage(tool: .encryption) {
            Picker("", selection: $encryptMode) {
                Text("Encrypt").tag(true)
                Text("Decrypt").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 240)
            Card(title: "Password", icon: "lock") {
                SecureField("Password", text: $password).textFieldStyle(.roundedBorder)
                Text("Uses AES-256-GCM with a key derived from your password (PBKDF2, 200,000 rounds). If you forget the password, the data can't be recovered.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Card(title: encryptMode ? "Text to Encrypt" : "Encrypted Text (Base64)", icon: "text.alignleft") {
                CodeEditor(text: $input, minHeight: 100, monospaced: !encryptMode).frame(height: 120)
                HStack {
                    Button {
                        runText()
                    } label: {
                        Label(encryptMode ? "Encrypt Text" : "Decrypt Text", systemImage: encryptMode ? "lock.fill" : "lock.open.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(password.isEmpty || input.isEmpty)
                    Button(encryptMode ? "Encrypt a File…" : "Decrypt a File…") { runFile() }
                        .disabled(password.isEmpty)
                    Spacer()
                    if !message.isEmpty {
                        Text(message).font(.caption).foregroundColor(isError ? Color.red : Color.green)
                    }
                }
            }
            Card(title: "Result", icon: "doc.on.doc") {
                OutputBox(text: output, minHeight: 80, maxHeight: 260)
                HStack {
                    CopyButton(text: output)
                    Button("Use as Input") {
                        input = output
                        output = ""
                        encryptMode.toggle()
                    }
                    .disabled(output.isEmpty)
                }
            }
        }
    }

    private func runText() {
        do {
            if encryptMode {
                output = try CryptoTools.encrypt(Data(input.utf8), password: password).base64EncodedString()
                message = "Encrypted"
            } else {
                guard let data = Data(base64Encoded: input.trimmed, options: .ignoreUnknownCharacters) else {
                    throw CryptoTools.CryptoError.notEncrypted
                }
                let plain = try CryptoTools.decrypt(data, password: password)
                output = String(decoding: plain, as: UTF8.self)
                message = "Decrypted"
            }
            isError = false
        } catch {
            message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            isError = true
        }
    }

    private func runFile() {
        guard let source = Panels.chooseFiles(multiple: false).first,
              let data = try? Data(contentsOf: source) else { return }
        do {
            if encryptMode {
                let result = try CryptoTools.encrypt(data, password: password)
                guard let dest = Panels.saveFile(name: source.lastPathComponent + ".mtenc") else { return }
                try result.write(to: dest)
                message = "Saved \(dest.lastPathComponent)"
            } else {
                let result = try CryptoTools.decrypt(data, password: password)
                var name = source.lastPathComponent
                if name.hasSuffix(".mtenc") { name = String(name.dropLast(6)) }
                guard let dest = Panels.saveFile(name: name) else { return }
                try result.write(to: dest)
                message = "Saved \(dest.lastPathComponent)"
            }
            isError = false
        } catch {
            message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            isError = true
        }
    }
}

// MARK: - Hex viewer

struct HexViewerView: View {
    @State private var fileURL: URL?
    @State private var fileSize: Int64 = 0
    @State private var loadedBytes = 0
    @State private var dump = ""
    @State private var fileType = ""
    private let page = 64 * 1024

    var body: some View {
        ToolPage(tool: .hexViewer) {
            Card(title: "File", icon: "doc.viewfinder") {
                HStack {
                    Button("Choose File…") {
                        if let url = Panels.chooseFiles(multiple: false).first { open(url) }
                    }
                    if let url = fileURL {
                        Text(url.lastPathComponent).bold().lineLimit(1)
                        Text("· \(Format.bytes(fileSize)) · \(fileType)").foregroundStyle(.secondary)
                    } else {
                        Text("…or drop any file here").foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
            .acceptsFileDrops { urls in if let url = urls.first { open(url) } }
            if fileURL != nil {
                Card(title: "Hex Dump (showing \(Format.bytes(Int64(loadedBytes))) of \(Format.bytes(fileSize)))", icon: "number") {
                    OutputBox(text: dump, minHeight: 300, maxHeight: 600)
                    HStack {
                        Button("Load More") { loadMore() }
                            .disabled(Int64(loadedBytes) >= fileSize)
                        CopyButton(text: dump)
                    }
                }
            }
        }
    }

    private func open(_ url: URL) {
        fileURL = url
        fileSize = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        loadedBytes = 0
        dump = ""
        if let handle = try? FileHandle(forReadingFrom: url) {
            fileType = HexDump.fileType(handle.readData(ofLength: 16))
            try? handle.close()
        }
        loadMore()
    }

    private func loadMore() {
        guard let url = fileURL, let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        handle.seek(toFileOffset: UInt64(loadedBytes))
        let data = handle.readData(ofLength: page)
        guard !data.isEmpty else { return }
        let text = HexDump.format(data, offset: loadedBytes)
        dump += (dump.isEmpty ? "" : "\n") + text
        loadedBytes += data.count
    }
}

// MARK: - Key code viewer

struct KeyEventRecord: Identifiable {
    let id = UUID()
    let kind: String
    let keyCode: UInt16
    let characters: String
    let modifiers: String
}

struct KeyCodeViewerView: View {
    @State private var events: [KeyEventRecord] = []
    @State private var monitor: Any?

    var body: some View {
        ToolPage(tool: .keyCodeViewer) {
            Card(title: "Press Any Key", icon: "keyboard") {
                if let last = events.first(where: { $0.kind == "Key down" }) {
                    HStack(alignment: .firstTextBaseline, spacing: 30) {
                        big("Key code", "\(last.keyCode)")
                        big("Key", KeyNames.name(for: last.keyCode))
                        big("Characters", last.characters.isEmpty ? "—" : last.characters)
                        big("Modifiers", last.modifiers.isEmpty ? "—" : last.modifiers)
                    }
                    HStack {
                        CopyButton(text: "\(last.keyCode)", label: "Copy Key Code")
                        CopyButton(text: String(format: "0x%02X", last.keyCode), label: "Copy Hex")
                    }
                } else {
                    Text("Click in this window, then press keys. Shortcuts with ⌘ still work normally.")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 20)
                }
            }
            Card(title: "Event Log", icon: "list.bullet") {
                ForEach(events.prefix(40)) { e in
                    HStack {
                        Text(e.kind).frame(width: 110, alignment: .leading)
                        Text("code \(e.keyCode)").frame(width: 80, alignment: .leading)
                        Text(KeyNames.name(for: e.keyCode)).frame(width: 110, alignment: .leading)
                        Text(e.characters.debugDescription).frame(width: 90, alignment: .leading)
                        Text(e.modifiers)
                        Spacer()
                    }
                    .font(.system(.callout, design: .monospaced))
                }
                Button("Clear") { events = [] }
            }
        }
        .onAppear(perform: startMonitoring)
        .onDisappear(perform: stopMonitoring)
    }

    private func big(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 30, weight: .semibold, design: .rounded))
        }
    }

    private func startMonitoring() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { event in
            let flags = event.modifierFlags
            var mods = ""
            if flags.contains(.control) { mods += "⌃" }
            if flags.contains(.option) { mods += "⌥" }
            if flags.contains(.shift) { mods += "⇧" }
            if flags.contains(.command) { mods += "⌘" }
            if flags.contains(.function) { mods += " fn" }
            if flags.contains(.capsLock) { mods += " ⇪" }
            let kind: String
            switch event.type {
            case .keyDown: kind = event.isARepeat ? "Key repeat" : "Key down"
            case .keyUp: kind = "Key up"
            default: kind = "Modifiers"
            }
            let chars = event.type == .flagsChanged ? "" : (event.characters ?? "")
            events.insert(KeyEventRecord(kind: kind, keyCode: event.keyCode, characters: chars, modifiers: mods), at: 0)
            if events.count > 200 { events.removeLast(events.count - 200) }
            // Swallow plain key presses (avoids the error beep) but let shortcuts through.
            if event.type == .keyDown && !flags.contains(.command) { return nil }
            return event
        }
    }

    private func stopMonitoring() {
        if let monitor = monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
