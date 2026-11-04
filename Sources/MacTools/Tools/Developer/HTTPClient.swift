import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct HTTPRequestSpec: Codable, Identifiable, Equatable {
    var id = UUID()
    var method = "GET"
    var url = "https://api.github.com/repos/apple/swift"
    var headers = "Accept: application/json"
    var body = ""
    var date = Date()
}

final class HTTPClientModel: ObservableObject {
    static let methods = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"]

    @Published var request: HTTPRequestSpec {
        didSet { Prefs.save("httpCurrentRequest", request) }
    }
    @Published var history: [HTTPRequestSpec] {
        didSet { DataStore.save(history, to: "http-history.json") }
    }
    @Published private(set) var sending = false
    @Published private(set) var statusCode: Int?
    @Published private(set) var responseHeaders: [(String, String)] = []
    @Published private(set) var responseBody = ""
    @Published private(set) var rawResponse = Data()
    @Published private(set) var elapsed: Double?
    @Published private(set) var errorMessage: String?

    private var task: URLSessionDataTask?

    init() {
        request = Prefs.load("httpCurrentRequest", default: HTTPRequestSpec())
        history = DataStore.load([HTTPRequestSpec].self, from: "http-history.json") ?? []
    }

    var parsedHeaders: [(String, String)] {
        request.headers.split(separator: "\n").compactMap { line -> (String, String)? in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            return key.isEmpty ? nil : (key, value)
        }
    }

    var resolvedURL: URL? {
        var text = request.url.trimmed
        if !text.contains("://") { text = "https://" + text }
        return URL(string: text)
    }

    func send() {
        guard let url = resolvedURL else {
            errorMessage = "That URL isn't valid."
            return
        }
        cancel()
        var r = URLRequest(url: url)
        r.httpMethod = request.method
        r.timeoutInterval = 60
        for (key, value) in parsedHeaders { r.setValue(value, forHTTPHeaderField: key) }
        if !request.body.isEmpty && request.method != "GET" && request.method != "HEAD" {
            r.httpBody = Data(request.body.utf8)
            let hasType = parsedHeaders.contains { $0.0.lowercased() == "content-type" }
            let trimmedBody = request.body.trimmed
            if !hasType && (trimmedBody.hasPrefix("{") || trimmedBody.hasPrefix("[")) {
                r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
        }
        sending = true
        errorMessage = nil
        statusCode = nil
        responseHeaders = []
        responseBody = ""
        let start = Date()
        task = URLSession.shared.dataTask(with: r) { [weak self] data, response, error in
            let time = Date().timeIntervalSince(start)
            let http = response as? HTTPURLResponse
            let headers = (http?.allHeaderFields ?? [:]).map { ("\($0.key)", "\($0.value)") }.sorted { $0.0.lowercased() < $1.0.lowercased() }
            let body = data ?? Data()
            let text = HTTPClientModel.render(body)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.sending = false
                self.elapsed = time
                if let error = error as NSError?, error.code == NSURLErrorCancelled { return }
                if let error = error {
                    self.errorMessage = error.localizedDescription
                    return
                }
                self.statusCode = http?.statusCode
                self.responseHeaders = headers
                self.rawResponse = body
                self.responseBody = text
            }
        }
        task?.resume()
        var entry = request
        entry.id = UUID()
        entry.date = Date()
        history.removeAll { $0.method == entry.method && $0.url == entry.url && $0.body == entry.body }
        history.insert(entry, at: 0)
        if history.count > 60 { history.removeLast(history.count - 60) }
    }

    func cancel() {
        task?.cancel()
        task = nil
        sending = false
    }

    static func render(_ data: Data) -> String {
        if data.isEmpty { return "" }
        if let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
           let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]) {
            return String(decoding: pretty, as: UTF8.self)
        }
        if let text = String(data: data.prefix(2_000_000), encoding: .utf8) { return text }
        return "<\(data.count) bytes of binary data>"
    }

    var curlCommand: String {
        var parts = ["curl", "-X", request.method, (resolvedURL?.absoluteString ?? request.url).shellQuoted]
        for (key, value) in parsedHeaders { parts += ["-H", "\(key): \(value)".shellQuoted] }
        if !request.body.isEmpty { parts += ["--data", request.body.shellQuoted] }
        return parts.joined(separator: " ")
    }

    func saveResponse() {
        guard !rawResponse.isEmpty, let url = Panels.saveFile(name: "response.txt") else { return }
        try? rawResponse.write(to: url)
    }
}

struct HTTPClientView: View {
    @StateObject private var model = HTTPClientModel()
    @State private var requestTab = 0
    @State private var responseTab = 0

    var body: some View {
        ToolPage(tool: .httpClient) {
            Card(title: "Request", icon: "paperplane") {
                HStack {
                    Picker("", selection: $model.request.method) {
                        ForEach(HTTPClientModel.methods, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 100)
                    TextField("https://api.example.com/items", text: $model.request.url)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .onSubmit { model.send() }
                    if model.sending {
                        Button("Cancel") { model.cancel() }
                    } else {
                        Button {
                            model.send()
                        } label: {
                            Label("Send", systemImage: "paperplane.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: [.command])
                    }
                }
                Picker("", selection: $requestTab) {
                    Text("Headers (\(model.parsedHeaders.count))").tag(0)
                    Text("Body").tag(1)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 260)
                if requestTab == 0 {
                    CodeEditor(text: $model.request.headers, minHeight: 80).frame(height: 100)
                    Text("One header per line, e.g. Authorization: Bearer abc123").font(.caption).foregroundStyle(.secondary)
                } else {
                    CodeEditor(text: $model.request.body, minHeight: 100).frame(height: 130)
                    HStack {
                        Button("Format JSON") {
                            if let data = model.request.body.data(using: .utf8),
                               let object = try? JSONSerialization.jsonObject(with: data),
                               let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
                                model.request.body = String(decoding: pretty, as: UTF8.self)
                            }
                        }
                        Text("JSON bodies get Content-Type: application/json automatically.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    CopyButton(text: model.curlCommand, label: "Copy as cURL")
                    Spacer()
                    Text("⌘↩ sends").font(.caption).foregroundStyle(.secondary)
                }
            }

            Card(title: "Response", icon: "arrow.down.doc") {
                HStack(spacing: 12) {
                    if model.sending {
                        ProgressView().controlSize(.small)
                        Text("Waiting for response…").foregroundStyle(.secondary)
                    } else if let error = model.errorMessage {
                        Label(error, systemImage: "xmark.octagon.fill").foregroundColor(.red)
                    } else if let code = model.statusCode {
                        Text("\(code) \(HTTPURLResponse.localizedString(forStatusCode: code).capitalized)")
                            .bold()
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(statusColor(code).opacity(0.25)))
                        if let time = model.elapsed {
                            Text(String(format: "%.0f ms", time * 1000)).foregroundStyle(.secondary)
                        }
                        Text(Format.bytes(Int64(model.rawResponse.count))).foregroundStyle(.secondary)
                    } else {
                        Text("Send a request to see the response.").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("", selection: $responseTab) {
                        Text("Body").tag(0)
                        Text("Headers (\(model.responseHeaders.count))").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 200)
                }
                if responseTab == 0 {
                    OutputBox(text: model.responseBody, minHeight: 200, maxHeight: 480)
                    HStack {
                        CopyButton(text: model.responseBody)
                        Button("Save…") { model.saveResponse() }.disabled(model.rawResponse.isEmpty)
                    }
                } else {
                    OutputBox(text: model.responseHeaders.map { "\($0.0): \($0.1)" }.joined(separator: "\n"), minHeight: 150, maxHeight: 400)
                }
            }

            if !model.history.isEmpty {
                Card(title: "History", icon: "clock.arrow.circlepath") {
                    ForEach(model.history.prefix(25)) { entry in
                        HStack {
                            Text(entry.method)
                                .font(.system(.caption, design: .monospaced).bold())
                                .frame(width: 60, alignment: .leading)
                            Text(entry.url).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(entry.date.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                            Button("Load") {
                                var copy = entry
                                copy.id = model.request.id
                                model.request = copy
                            }
                        }
                    }
                    Button("Clear History") { model.history = [] }
                }
            }
        }
    }

    private func statusColor(_ code: Int) -> Color {
        switch code {
        case 200..<300: return Color.green
        case 300..<400: return Color.blue
        case 400..<500: return Color.orange
        default: return Color.red
        }
    }
}
