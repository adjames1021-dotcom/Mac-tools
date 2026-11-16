import Foundation

// MARK: - Prompt

enum SchoolPrompt {
    /// JSON schema the AI's answer must follow (used for structured output by both providers).
    static let schema: Any = {
        let json = """
        {
          "type": "object",
          "properties": {
            "items": {
              "type": "array",
              "items": {
                "type": "object",
                "properties": {
                  "title": {"type": "string"},
                  "course": {"type": "string"},
                  "source": {"type": "string", "enum": ["Google Classroom", "Infinite Campus", "Both", "Other"]},
                  "status": {"type": "string", "enum": ["todo", "missing", "done"]},
                  "due": {"type": "string"},
                  "kind": {"type": "string", "enum": ["test", "quiz", "project", "essay", "lab", "assignment", "homework", "reading", "classwork", "other"]},
                  "impact": {"type": "string", "enum": ["major", "high", "medium", "low", "minimal"]},
                  "weight": {"type": "string"},
                  "points": {"type": "string"},
                  "url": {"type": "string"},
                  "notes": {"type": "string"}
                },
                "required": ["title", "course", "source", "status", "due", "kind", "impact", "weight", "points", "url", "notes"],
                "additionalProperties": false
              }
            },
            "warnings": {"type": "array", "items": {"type": "string"}}
          },
          "required": ["items", "warnings"],
          "additionalProperties": false
        }
        """
        return (try? JSONSerialization.jsonObject(with: Data(json.utf8))) ?? [String: Any]()
    }()

    static func system(lookbackDays: Int, knownCourses: [String]) -> String {
        let today = DateFormatter()
        today.locale = Locale(identifier: "en_US_POSIX")
        today.dateFormat = "EEEE, MMMM d, yyyy 'at' HH:mm"
        let courseHint = knownCourses.isEmpty ? "" :
            " Class names used last time (reuse these exact spellings when they match): " + knownCourses.joined(separator: "; ") + "."
        return """
        You turn text scraped from a student's school websites (Google Classroom and Infinite Campus) into one clean, consistent list of schoolwork.

        Today is \(today.string(from: Date())). The student's time zone is \(TimeZone.current.identifier).

        Reading the input
        - Each section starts with "### SOURCE:" naming the site and page. Page text is raw and includes menus, navigation and other noise; ignore anything that isn't schoolwork.
        - Google Classroom: the "Assigned" page lists work not turned in yet, "Missing" lists work past due and not turned in, and "Done" lists work turned in or returned. A label next to an item ("Missing", "Turned in", "Done late", "Graded", "Returned", "Assigned") beats the page it was on.
        - Google Classroom "Class Stream" pages show a class's recent posts, newest first: teacher announcements and notices of new assignments or materials, each with the date it was posted.
        - Infinite Campus: ASSIGNMENTS lines are one assignment each, with flags such as missing, late, turned in, incomplete, dropped and exempt, plus points and scores. GRADE CATEGORIES lines say how much each category counts in a class (for example "Tests = 40").

        Building the list
        - One entry per piece of schoolwork. When the same work appears in both Google Classroom and Infinite Campus (same class, essentially the same title), output it once with source "Both" and combine what each site says: the Classroom link, the Infinite Campus points, category and flags.
        - status: "missing" if it's marked missing, or its due date has passed and it isn't turned in, done or graded; "done" if it's turned in, marked done, graded or returned with a score, exempt or dropped; otherwise "todo". A turned-in or graded signal beats "missing", and "missing" beats "todo".
        - title: the work's own name, without the class name or status words.
        - course: a short class name, spelled the same way everywhere (e.g. "AP Biology", "English 10"). Drop section numbers, period codes and teacher names unless two classes would otherwise look the same.\(courseHint)
        - due: "YYYY-MM-DDTHH:MM" when a time is known, "YYYY-MM-DD" when only the date is known, "" when there's no due date. Work out relative dates ("Tomorrow", "Due Friday", "Yesterday") from today's date. When a date has no year, pick the year that puts it closest to today.
        - impact: how much this work can move the class grade, so the student knows what to do first. Use real data when you have it: the weight of its grade category (a test in a category worth 40% outweighs homework in a category worth 10%) and its points (100 points outweighs 10 points in the same class). Without data, judge by what it is: tests, exams, major projects and essays are "major" or "high"; quizzes and labs are "medium"; homework, classwork and readings are "low"; practice, ungraded or completion-only work is "minimal".
        - weight: a few words explaining the impact, e.g. "Tests = 40% of grade", "100 pts", "Quiz (estimated)". Add "(estimated)" whenever you judged from the kind of work instead of real weights or points.
        - points: the possible points (e.g. "20 pts"), or the score for graded work (e.g. "18/20"); "" if unknown.
        - url: a link to this exact piece of work, copied character for character from the LINKS lists. When it appears in several places, prefer the Google Classroom item link. If no link belongs to this item, use the PAGE URL of the section it came from. Never invent a URL.
        - notes: at most one short sentence that helps the student, e.g. "Turned in late" or "Teacher comment: redo #4"; usually "".
        - For done work, only include items due (or turned in) in the last \(max(1, lookbackDays)) days; leave older done work out.
        - Class Streams: turn an announcement into an entry only when it asks the student to do, study, bring, sign or submit something (e.g. "Test on chapter 5 this Friday", "Return the permission slip by Monday"). Work out its due date from the post date, pick the matching kind, put "From the class stream" in notes, and use the post's link as url. An assignment posted to the stream that also appears on the To-do pages is the same entry, not a new one. Skip posts more than three weeks old unless they name a date that's still ahead.
        - Leave out general news, class materials with nothing to do, and calendar events that aren't schoolwork.

        warnings: short notes about problems in the input, e.g. "The Infinite Campus page looked like a sign-in page"; [] if none.
        """
    }

    /// Everything scraped this sync, as one message.
    static func render(_ pages: [ScrapedPage]) -> String {
        var out = "Here is everything scraped from the student's school sites. Build the list.\n"
        for page in pages {
            out += "\n### SOURCE: \(page.source.rawValue) — \(page.label)\nPAGE URL: \(page.url)\n"
            if page.truncated { out += "(This page was very long, so only its first part is included.)\n" }
            out += "CONTENT:\n<<<\n\(page.text)\n>>>\n"
            if !page.links.isEmpty {
                out += "LINKS (label -> url):\n" + page.links.map { "- " + $0 }.joined(separator: "\n") + "\n"
            }
        }
        return out
    }
}

// MARK: - Client

struct AIItem: Decodable {
    let title: String
    let course: String
    let source: String
    let status: String
    let due: String
    let kind: String
    let impact: String
    let weight: String
    let points: String
    let url: String
    let notes: String
}

struct AIOutput {
    var items: [AIItem]
    var warnings: [String]
    var servedBy: String
    var characters: Int
}

enum AIError: LocalizedError {
    case http(provider: AIProvider, status: Int, message: String, type: String)
    case network(String)
    case refused(String)
    case cutOff
    case unreadable

    var errorDescription: String? {
        switch self {
        case let .http(provider, status, message, type):
            let detail = message.isEmpty ? "" : " (\(message))"
            switch status {
            case 401:
                return "\(provider.companyName) didn't accept the API key. Check it under Setup."
            case 403:
                return "\(provider.companyName) refused the request\(detail)."
            case 404:
                return "\(provider.companyName) doesn't recognise the model name. Pick another model under Setup\(detail)."
            case 429 where type == "insufficient_quota":
                return "Your OpenAI account is out of credit. Add billing at platform.openai.com, or switch to Claude under Setup."
            case 429:
                return "\(provider.companyName) is rate-limiting requests right now. Try again in a minute."
            case 529:
                return "\(provider.companyName)'s API is overloaded right now. Try again shortly."
            case 400:
                return "\(provider.companyName) rejected the request\(detail)."
            case 0:
                return "\(provider.companyName) reported an error\(detail)."
            default:
                return "\(provider.companyName) API error \(status)\(detail)."
            }
        case .network(let message):
            return "Couldn't reach the AI service: \(message)"
        case .refused(let message):
            return "The AI declined to organize this content" + (message.isEmpty ? "." : ": \(message)") + " Try syncing again, or remove an extra page under Setup."
        case .cutOff:
            return "The list was too long to finish. Lower “Keep done work for” under Setup and sync again."
        case .unreadable:
            return "The AI's answer couldn't be read. Try syncing again."
        }
    }
}

/// Sends the scraped pages to Claude or ChatGPT with a streaming request and parses the structured list it returns.
final class AIOrganizer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let provider: AIProvider
    private let apiKey: String
    private let model: String
    private let system: String
    private let payload: String

    // Used on the main thread only.
    private var progress: ((Int) -> Void)?
    private var completion: ((Result<AIOutput, Error>) -> Void)?
    private var session: URLSession?
    private var attempt = 0
    private var lastProgress = Date.distantPast

    // Used on the session's delegate queue only (reset before each attempt).
    private var lineBuffer = Data()
    private var errorBody = Data()
    private var text = ""
    private var received = 0
    private var refusal = ""
    private var stopReason = ""
    private var servedBy = ""
    private var streamError: (message: String, type: String)?

    init(provider: AIProvider, apiKey: String, model: String, system: String, payload: String) {
        self.provider = provider
        self.apiKey = apiKey
        self.model = model
        self.system = system
        self.payload = payload
    }

    func start(progress: @escaping (Int) -> Void, completion: @escaping (Result<AIOutput, Error>) -> Void) {
        self.progress = progress
        self.completion = completion
        send()
    }

    func cancel() {
        completion = nil
        progress = nil
        session?.invalidateAndCancel()
        session = nil
    }

    private var supportsServerFallback: Bool {
        model.hasPrefix("claude-opus-5") || model.hasPrefix("claude-sonnet-5-5") || model.hasPrefix("claude-fable-5")
    }

    private func makeRequest() -> URLRequest? {
        var request: URLRequest
        var body: [String: Any]
        switch provider {
        case .claude:
            guard let url = URL(string: "https://api.anthropic.com/v1/messages") else { return nil }
            request = URLRequest(url: url)
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
            let format: [String: Any] = ["type": "json_schema", "schema": SchoolPrompt.schema]
            let outputConfig: [String: Any] = ["effort": "medium", "format": format]
            let message: [String: Any] = ["role": "user", "content": payload]
            body = [
                "model": model,
                "max_tokens": 64000,
                "stream": true,
                "system": system,
                "output_config": outputConfig,
                "messages": [message],
            ]
            if supportsServerFallback {
                // If a safety check declines the request, the API retries it on a fallback model by itself.
                request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
                body["fallbacks"] = "default"
            }
        case .openAI:
            guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else { return nil }
            request = URLRequest(url: url)
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            let jsonSchema: [String: Any] = ["name": "school_todo_list", "strict": true, "schema": SchoolPrompt.schema]
            let responseFormat: [String: Any] = ["type": "json_schema", "json_schema": jsonSchema]
            let messages: [[String: Any]] = [
                ["role": "system", "content": system],
                ["role": "user", "content": payload],
            ]
            body = [
                "model": model,
                "stream": true,
                "messages": messages,
                "response_format": responseFormat,
            ]
        }
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("text/event-stream", forHTTPHeaderField: "accept")
        request.timeoutInterval = 300
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        request.httpBody = data
        return request
    }

    private func send() {
        lineBuffer = Data()
        errorBody = Data()
        text = ""
        received = 0
        refusal = ""
        stopReason = ""
        servedBy = model
        streamError = nil
        guard let request = makeRequest() else {
            deliver(.failure(AIError.unreadable))
            return
        }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 1800
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
        self.session = session
        session.dataTask(with: request).resume()
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let status = (dataTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            errorBody.append(data)
            return
        }
        lineBuffer.append(data)
        while let newline = lineBuffer.firstIndex(of: 0x0A) {
            let line = String(decoding: lineBuffer[lineBuffer.startIndex..<newline], as: UTF8.self)
            lineBuffer.removeSubrange(lineBuffer.startIndex...newline)
            handle(line)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        session.finishTasksAndInvalidate()
        if !lineBuffer.isEmpty {
            handle(String(decoding: lineBuffer, as: UTF8.self))
            lineBuffer = Data()
        }
        if let error = error {
            if (error as NSError).code == NSURLErrorCancelled { return }
            retryOrFail(AIError.network(error.localizedDescription), retryable: received == 0)
            return
        }
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        if status != 200 {
            let details = Self.errorDetails(errorBody)
            let retryable = [408, 409, 429, 500, 502, 503, 504, 529].contains(status) && details.type != "insufficient_quota"
            retryOrFail(AIError.http(provider: provider, status: status, message: details.message, type: details.type), retryable: retryable)
            return
        }
        if let streamError = streamError {
            let retryable = received == 0 && ["overloaded_error", "api_error", "server_error", "rate_limit_error"].contains(streamError.type)
            retryOrFail(AIError.http(provider: provider, status: 0, message: streamError.message, type: streamError.type), retryable: retryable)
            return
        }
        finishParsing()
    }

    // MARK: Parsing

    private func handle(_ raw: String) {
        var line = raw
        if line.hasSuffix("\r") { line.removeLast() }
        guard line.hasPrefix("data:") else { return }
        let json = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard json != "[DONE]", let data = json.data(using: .utf8),
              let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        switch provider {
        case .claude: handleClaude(event)
        case .openAI: handleOpenAI(event)
        }
    }

    private func handleClaude(_ event: [String: Any]) {
        switch event["type"] as? String {
        case "message_start":
            if let message = event["message"] as? [String: Any], let name = message["model"] as? String { servedBy = name }
        case "content_block_start":
            // A "fallback" block means another model took over after a safety decline; its text continues the answer.
            if let block = event["content_block"] as? [String: Any], block["type"] as? String == "fallback",
               let to = block["to"] as? [String: Any], let name = to["model"] as? String {
                servedBy = name
            }
        case "content_block_delta":
            if let delta = event["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
               let piece = delta["text"] as? String {
                append(piece)
            }
        case "message_delta":
            if let delta = event["delta"] as? [String: Any], let reason = delta["stop_reason"] as? String { stopReason = reason }
        case "error":
            let error = event["error"] as? [String: Any]
            streamError = ((error?["message"] as? String) ?? "", (error?["type"] as? String) ?? "")
        default:
            break
        }
    }

    private func handleOpenAI(_ event: [String: Any]) {
        if let error = event["error"] as? [String: Any] {
            streamError = ((error["message"] as? String) ?? "", (error["type"] as? String) ?? (error["code"] as? String) ?? "")
            return
        }
        if let name = event["model"] as? String { servedBy = name }
        guard let choices = event["choices"] as? [[String: Any]], let choice = choices.first else { return }
        if let delta = choice["delta"] as? [String: Any] {
            if let piece = delta["content"] as? String { append(piece) }
            if let piece = delta["refusal"] as? String { refusal += piece }
        }
        if let reason = choice["finish_reason"] as? String { stopReason = reason }
    }

    private func append(_ piece: String) {
        text += piece
        received += piece.count
        let count = received
        DispatchQueue.main.async {
            guard Date().timeIntervalSince(self.lastProgress) > 0.25 else { return }
            self.lastProgress = Date()
            self.progress?(count)
        }
    }

    private struct Answer: Decodable {
        let items: [AIItem]
        let warnings: [String]
    }

    private func finishParsing() {
        if !refusal.isEmpty || stopReason == "refusal" || stopReason == "content_filter" {
            deliver(.failure(AIError.refused(refusal.trimmed)))
            return
        }
        if stopReason == "max_tokens" || stopReason == "length" {
            deliver(.failure(AIError.cutOff))
            return
        }
        var json = text.trimmed
        // Structured output should be bare JSON, but tolerate a code fence around it.
        if !json.hasPrefix("{"), let start = json.firstIndex(of: "{"), let end = json.lastIndex(of: "}"), start < end {
            json = String(json[start...end])
        }
        guard let answer = try? JSONDecoder().decode(Answer.self, from: Data(json.utf8)) else {
            deliver(.failure(AIError.unreadable))
            return
        }
        deliver(.success(AIOutput(items: answer.items, warnings: answer.warnings, servedBy: servedBy, characters: received)))
    }

    private static func errorDetails(_ data: Data) -> (message: String, type: String) {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let error = object["error"] as? [String: Any] else {
            let text = String(decoding: data.prefix(300), as: UTF8.self).trimmed
            return (text, "")
        }
        let type = (error["type"] as? String) ?? ""
        let code = (error["code"] as? String) ?? ""
        return ((error["message"] as? String) ?? "", code == "insufficient_quota" ? code : type)
    }

    // MARK: Finishing

    private func retryOrFail(_ error: Error, retryable: Bool) {
        DispatchQueue.main.async {
            guard self.completion != nil else { return }
            guard retryable && self.attempt < 2 else {
                self.deliver(.failure(error))
                return
            }
            self.attempt += 1
            let delay: Double = self.attempt == 1 ? 4 : 12
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard self.completion != nil else { return }
                self.send()
            }
        }
    }

    private func deliver(_ result: Result<AIOutput, Error>) {
        DispatchQueue.main.async {
            guard let completion = self.completion else { return }
            self.completion = nil
            self.progress = nil
            self.session = nil
            completion(result)
        }
    }
}
