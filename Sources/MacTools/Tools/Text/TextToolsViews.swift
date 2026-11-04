import SwiftUI
import AppKit

struct TextToolsView: View {
    @AppStorage("textToolsText") private var text = "Paste or type some text here, then click a transformation below."
    @State private var undoStack: [String] = []
    @State private var findText = ""
    @State private var replaceText = ""
    @State private var loremCount = 3

    var body: some View {
        ToolPage(tool: .textTools) {
            Card(title: "Text", icon: "text.alignleft") {
                CodeEditor(text: $text, minHeight: 200, monospaced: false)
                    .frame(height: 230)
                let stats = TextStats(text)
                HStack(spacing: 14) {
                    statLabel("Characters", stats.characters)
                    statLabel("No spaces", stats.charactersNoSpaces)
                    statLabel("Words", stats.words)
                    statLabel("Lines", stats.lines)
                    statLabel("Sentences", stats.sentences)
                    statLabel("Paragraphs", stats.paragraphs)
                    Text(String(format: "~%.1f min read", stats.readingMinutes))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                HStack {
                    Button("Undo") {
                        if let last = undoStack.popLast() { text = last }
                    }
                    .disabled(undoStack.isEmpty)
                    Button("Paste") {
                        if let clip = ClipboardHelper.string { apply { _ in clip } }
                    }
                    CopyButton(text: text)
                    Button("Clear") { apply { _ in "" } }
                    Spacer()
                    Stepper("\(loremCount) paragraphs", value: $loremCount, in: 1...20)
                    Button("Lorem Ipsum") { apply { _ in LoremIpsum.paragraphs(loremCount) } }
                }
            }

            Card(title: "Find & Replace", icon: "magnifyingglass") {
                HStack {
                    TextField("Find", text: $findText).textFieldStyle(.roundedBorder)
                    TextField("Replace with", text: $replaceText).textFieldStyle(.roundedBorder)
                    Button("Replace All") {
                        guard !findText.isEmpty else { return }
                        apply { $0.replacingOccurrences(of: findText, with: replaceText) }
                    }
                    .disabled(findText.isEmpty)
                    if !findText.isEmpty {
                        Text("\(text.components(separatedBy: findText).count - 1) matches")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            ForEach(TextTransform.groups, id: \.0) { group in
                Card(title: group.0, icon: "wand.and.stars") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], alignment: .leading, spacing: 8) {
                        ForEach(group.1) { transform in
                            Button {
                                apply { transform.apply($0) }
                            } label: {
                                Text(transform.title).frame(maxWidth: .infinity)
                            }
                        }
                    }
                }
            }
        }
    }

    private func statLabel(_ title: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(value)").font(.headline).monospacedDigit()
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func apply(_ transform: (String) -> String) {
        let result = transform(text)
        guard result != text else { return }
        undoStack.append(text)
        if undoStack.count > 50 { undoStack.removeFirst() }
        text = result
    }
}

struct JSONFormatterView: View {
    @AppStorage("jsonInput") private var input = "{\"name\":\"MacTools\",\"tools\":[\"clicker\",\"typer\"],\"version\":1}"
    @State private var output = ""
    @State private var message = ""
    @State private var isError = false
    @State private var sortKeys = true

    var body: some View {
        ToolPage(tool: .jsonFormatter) {
            Card(title: "Input", icon: "curlybraces") {
                CodeEditor(text: $input, minHeight: 180)
                    .frame(height: 200)
                HStack {
                    Button("Format") { run(pretty: true) }
                        .buttonStyle(.borderedProminent)
                    Button("Minify") { run(pretty: false) }
                    Button("Validate") { validate() }
                    Toggle("Sort keys", isOn: $sortKeys)
                    Spacer()
                    Button("Paste") { if let s = ClipboardHelper.string { input = s } }
                    Button("Use Output as Input") { if !output.isEmpty { input = output } }
                        .disabled(output.isEmpty)
                }
                if !message.isEmpty {
                    Label(message, systemImage: isError ? "xmark.octagon.fill" : "checkmark.seal.fill")
                        .foregroundColor(isError ? Color.red : Color.green)
                }
            }
            Card(title: "Output", icon: "text.alignleft") {
                HStack {
                    Spacer()
                    CopyButton(text: output)
                }
                OutputBox(text: output, minHeight: 200, maxHeight: 500)
            }
        }
    }

    private func parse() -> Any? {
        guard let data = input.data(using: .utf8) else { return nil }
        do {
            let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            return object
        } catch {
            isError = true
            message = "Invalid JSON: " + JSONFormatterView.describe(error)
            return nil
        }
    }

    private func run(pretty: Bool) {
        guard let object = parse() else { return }
        var options: JSONSerialization.WritingOptions = [.fragmentsAllowed, .withoutEscapingSlashes]
        if pretty { options.insert(.prettyPrinted) }
        if sortKeys { options.insert(.sortedKeys) }
        if let data = try? JSONSerialization.data(withJSONObject: object, options: options),
           let string = String(data: data, encoding: .utf8) {
            output = string
            isError = false
            message = pretty ? "Formatted (\(string.count) characters)" : "Minified (\(string.count) characters)"
        }
    }

    private func validate() {
        guard let object = parse() else { return }
        isError = false
        if let dict = object as? [String: Any] {
            message = "Valid JSON object with \(dict.count) keys"
        } else if let array = object as? [Any] {
            message = "Valid JSON array with \(array.count) items"
        } else {
            message = "Valid JSON value"
        }
    }

    static func describe(_ error: Error) -> String {
        let ns = error as NSError
        if let detail = ns.userInfo["NSDebugDescription"] as? String { return detail }
        return ns.localizedDescription
    }
}

struct RegexTesterView: View {
    @AppStorage("regexPattern") private var pattern = "\\b(\\w+)@(\\w+\\.\\w+)\\b"
    @AppStorage("regexText") private var text = "Contact us at hello@example.com or support@mactools.app today."
    @AppStorage("regexReplace") private var replacement = "$1 at $2"
    @State private var caseInsensitive = false
    @State private var multiline = true
    @State private var dotAll = false

    private var regex: Result<NSRegularExpression, Error> {
        var options: NSRegularExpression.Options = []
        if caseInsensitive { options.insert(.caseInsensitive) }
        if multiline { options.insert(.anchorsMatchLines) }
        if dotAll { options.insert(.dotMatchesLineSeparators) }
        do {
            return .success(try NSRegularExpression(pattern: pattern, options: options))
        } catch {
            return .failure(error)
        }
    }

    var body: some View {
        ToolPage(tool: .regexTester) {
            Card(title: "Pattern", icon: "asterisk.circle") {
                TextField("Regular expression", text: $pattern)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                HStack(spacing: 18) {
                    Toggle("Ignore case", isOn: $caseInsensitive)
                    Toggle("^ $ match lines", isOn: $multiline)
                    Toggle(". matches newline", isOn: $dotAll)
                }
                if case .failure(let error) = regex {
                    Label("Invalid pattern: \(JSONFormatterView.describe(error))", systemImage: "xmark.octagon.fill")
                        .foregroundColor(.red)
                }
            }

            Card(title: "Test Text", icon: "text.alignleft") {
                CodeEditor(text: $text, minHeight: 120)
                    .frame(height: 140)
            }

            if case .success(let re) = regex {
                let range = NSRange(text.startIndex..<text.endIndex, in: text)
                let matches = re.matches(in: text, options: [], range: range)
                Card(title: "Matches (\(matches.count))", icon: "highlighter") {
                    Text(highlighted(matches))
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                    ForEach(Array(matches.prefix(200).enumerated()), id: \.offset) { item in
                        matchRow(item.offset, item.element)
                    }
                }
                Card(title: "Replace", icon: "arrow.2.squarepath") {
                    TextField("Replacement ($1, $2 for groups)", text: $replacement)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                    let replaced = re.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: replacement)
                    OutputBox(text: replaced, minHeight: 60, maxHeight: 200)
                    HStack {
                        Spacer()
                        CopyButton(text: replaced)
                    }
                }
            }

            Card(title: "Cheat Sheet", icon: "book") {
                let rows: [(String, String)] = [
                    (".", "any character"), ("\\d \\w \\s", "digit, word char, whitespace"),
                    ("\\D \\W \\S", "not digit / word / whitespace"), ("[abc] [^abc]", "any of / none of"),
                    ("* + ?", "0+, 1+, 0 or 1"), ("{2,5}", "between 2 and 5"), ("^ $", "start / end of line"),
                    ("\\b", "word boundary"), ("(…) (?:…)", "capture group / non-capturing"), ("a|b", "a or b"),
                    ("(?=…) (?!…)", "lookahead / negative lookahead")
                ]
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), alignment: .leading)], alignment: .leading, spacing: 4) {
                    ForEach(rows, id: \.0) { row in
                        HStack {
                            Text(row.0).font(.system(.callout, design: .monospaced)).frame(width: 110, alignment: .leading)
                            Text(row.1).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func matchRow(_ index: Int, _ match: NSTextCheckingResult) -> some View {
        var parts: [String] = []
        for g in 0..<match.numberOfRanges {
            let r = match.range(at: g)
            if r.location != NSNotFound, let swiftRange = Range(r, in: text) {
                parts.append(g == 0 ? "“\(text[swiftRange])”" : "$\(g)=“\(text[swiftRange])”")
            }
        }
        return HStack(alignment: .top) {
            Text("#\(index + 1)").foregroundStyle(.secondary).frame(width: 40, alignment: .leading)
            Text(parts.joined(separator: "  ")).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
            Spacer()
            Text("at \(match.range.location)").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func highlighted(_ matches: [NSTextCheckingResult]) -> AttributedString {
        var result = AttributedString()
        var cursor = text.startIndex
        for match in matches {
            guard let range = Range(match.range, in: text), range.lowerBound >= cursor else { continue }
            result += AttributedString(String(text[cursor..<range.lowerBound]))
            var hit = AttributedString(String(text[range]))
            hit[AttributeScopes.SwiftUIAttributes.BackgroundColorAttribute.self] = Color.yellow.opacity(0.5)
            result += hit
            cursor = range.upperBound
        }
        result += AttributedString(String(text[cursor..<text.endIndex]))
        return result
    }
}

struct DiffCheckerView: View {
    @AppStorage("diffLeft") private var left = "apples\nbananas\ncherries\ndates"
    @AppStorage("diffRight") private var right = "apples\nblueberries\ncherries\ndates\nelderberries"
    @State private var ignoreWhitespace = false
    @State private var ignoreCase = false

    var body: some View {
        ToolPage(tool: .diffChecker) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading) {
                    Text("Original").font(.headline)
                    CodeEditor(text: $left, minHeight: 180).frame(height: 200)
                }
                VStack(alignment: .leading) {
                    Text("Changed").font(.headline)
                    CodeEditor(text: $right, minHeight: 180).frame(height: 200)
                }
            }
            HStack(spacing: 18) {
                Toggle("Ignore whitespace", isOn: $ignoreWhitespace)
                Toggle("Ignore case", isOn: $ignoreCase)
                Spacer()
                Button("Swap") {
                    let l = left
                    left = right
                    right = l
                }
            }
            let lines = DiffEngine.diff(old: left, new: right, ignoreWhitespace: ignoreWhitespace, ignoreCase: ignoreCase)
            let added = lines.filter { $0.kind == .added }.count
            let removed = lines.filter { $0.kind == .removed }.count
            Card(title: "Differences: \(added) added, \(removed) removed", icon: "arrow.left.arrow.right") {
                if added == 0 && removed == 0 {
                    Label("The texts are identical", systemImage: "checkmark.seal.fill").foregroundColor(.green)
                }
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(lines) { line in
                        HStack(spacing: 6) {
                            Text(line.oldNumber.map { "\($0)" } ?? "")
                                .frame(width: 34, alignment: .trailing)
                                .foregroundStyle(.secondary)
                            Text(line.newNumber.map { "\($0)" } ?? "")
                                .frame(width: 34, alignment: .trailing)
                                .foregroundStyle(.secondary)
                            Text(symbol(line.kind)).frame(width: 14)
                            Text(line.text.isEmpty ? " " : line.text)
                            Spacer(minLength: 0)
                        }
                        .font(.system(.callout, design: .monospaced))
                        .padding(.vertical, 1)
                        .background(rowColor(line.kind))
                    }
                }
            }
        }
    }

    private func symbol(_ kind: DiffKind) -> String {
        switch kind {
        case .same: return " "
        case .added: return "+"
        case .removed: return "−"
        }
    }

    private func rowColor(_ kind: DiffKind) -> Color {
        switch kind {
        case .same: return Color.clear
        case .added: return Color.green.opacity(0.18)
        case .removed: return Color.red.opacity(0.18)
        }
    }
}
