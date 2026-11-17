import SwiftUI
import AppKit
import WebKit

// MARK: - Scrape types

struct ScrapeJob {
    enum Kind { case classroom, classroomClasses, classroomStream, campus, page }
    let kind: Kind
    let source: SchoolSource
    let label: String
    let url: URL
}

struct ScrapedPage {
    let source: SchoolSource
    let label: String
    let url: String
    let text: String
    let links: [String]
    let truncated: Bool
}

struct ScrapeReport {
    var pages: [ScrapedPage] = []
    /// Sites that need the user to sign in, with what to tell them.
    var signIn: [SchoolSource: String] = [:]
    var warnings: [String] = []
    /// The current grading period, if Infinite Campus reported one.
    var term: SchoolTerm?
}

struct ScrapeIssue: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - Shared web setup

enum SchoolWeb {
    /// Google refuses sign-ins from browsers it doesn't recognise, so the built-in browser introduces itself as Safari.
    static let userAgent: String = {
        let plist = NSDictionary(contentsOfFile: "/Applications/Safari.app/Contents/Info.plist")
        let version = (plist?["CFBundleShortVersionString"] as? String) ?? "18.0"
        return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(version) Safari/605.1.15"
    }()

    /// Every web view uses the default (on-disk) website data store, so cookies – and with them your sign-ins – are
    /// shared between the sign-in window and the sync, and kept when MacTools quits.
    static func makeWebView(frame: NSRect) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore.default()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        let webView = WKWebView(frame: frame, configuration: configuration)
        webView.customUserAgent = userAgent
        return webView
    }

    static func normalizedURL(_ text: String) -> URL? {
        var value = text.trimmed
        guard !value.isEmpty else { return nil }
        if !value.contains("://") { value = "https://" + value }
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", url.host != nil else { return nil }
        return url
    }

    static func source(for url: URL, campusHost: String?) -> SchoolSource {
        let host = url.host?.lowercased() ?? ""
        if host.hasSuffix("classroom.google.com") { return .classroom }
        if host == campusHost?.lowercased() || host.contains("infinitecampus") { return .campus }
        return .other
    }

    static func classroomHome(account: Int) -> URL {
        URL(string: "https://classroom.google.com/u/\(max(0, account))/a/not-turned-in/all")!
    }

    /// Deletes all cookies and website data (signs out of every site in the built-in browser).
    static func signOutEverywhere(completion: @escaping () -> Void) {
        WKWebsiteDataStore.default().removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: Date(timeIntervalSince1970: 0)
        ) {
            completion()
        }
    }
}

// MARK: - Infinite Campus address lookup

/// Where a district's Infinite Campus sign-in lives, worked out from whatever Infinite Campus address was pasted
/// (the bare site, the sign-in page, the Google sign-in link, a portal page…).
struct CampusSite: Codable, Equatable {
    /// The address this was worked out from (re-checked when the address changes).
    var input: String
    /// e.g. https://district.infinitecampus.org
    var origin: String
    /// The district's app name, e.g. "msad35".
    var appName: String
    /// The student sign-in page.
    var loginURL: String
    /// The district's "Google Single Sign-On" link, or "" when it has none.
    var ssoURL: String
}

enum CampusResolver {
    private static let stateCodes: Set<String> = [
        "al", "ak", "az", "ar", "ca", "co", "ct", "de", "dc", "fl", "ga", "hi", "id", "il", "in", "ia", "ks", "ky", "la",
        "me", "md", "ma", "mi", "mn", "ms", "mo", "mt", "ne", "nv", "nh", "nj", "nm", "ny", "nc", "nd", "oh", "ok", "or",
        "pa", "ri", "sc", "sd", "tn", "tx", "ut", "vt", "va", "wa", "wv", "wi", "wy",
    ]

    /// First capture group of `pattern` in `text`.
    static func capture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    /// Likely app names, best guess first: one named in the address itself, then the first part of the host name
    /// without its state code (hosted districts look like "<appname><state>.infinitecampus.org").
    static func appNameCandidates(for url: URL) -> [String] {
        var names: [String] = []
        if let name = capture(#"/campus/portal/(?:students|parents)/([^/.]+)\.jsp"#, in: url.path) { names.append(name) }
        if let name = capture(#"/campus/SSO/([^/]+)"#, in: url.path) { names.append(name) }
        if let name = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name.lowercased() == "appname" })?.value { names.append(name) }
        if let label = url.host?.split(separator: ".").first.map({ String($0).lowercased() }) {
            if label.count > 3, stateCodes.contains(String(label.suffix(2))) { names.append(String(label.dropLast(2))) }
            names.append(label)
        }
        var seen = Set<String>()
        return names.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    /// Finds the student sign-in page (and Google sign-in link) for any Infinite Campus address.
    static func resolve(_ text: String, completion: @escaping (Result<CampusSite, Error>) -> Void) {
        guard let url = SchoolWeb.normalizedURL(text), let host = url.host, let scheme = url.scheme else {
            completion(.failure(ScrapeIssue("That doesn't look like a web address.")))
            return
        }
        let origin = "\(scheme)://\(host)"
        attempt(origin: origin, input: text.trimmed, names: appNameCandidates(for: url), completion: completion)
    }

    private static func attempt(origin: String, input: String, names: [String], completion: @escaping (Result<CampusSite, Error>) -> Void) {
        guard let name = names.first else {
            completion(.failure(ScrapeIssue("Couldn't find your district's sign-in page from that address. Paste the address of the Infinite Campus page where you sign in.")))
            return
        }
        let rest = Array(names.dropFirst())
        let login = "\(origin)/campus/portal/students/\(name).jsp"
        guard let loginURL = URL(string: login) else {
            self.attempt(origin: origin, input: input, names: rest, completion: completion)
            return
        }
        var request = URLRequest(url: loginURL, timeoutInterval: 20)
        request.setValue(SchoolWeb.userAgent, forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let html = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            DispatchQueue.main.async {
                guard status == 200, html.range(of: "name=\"appName\"", options: .caseInsensitive) != nil else {
                    CampusResolver.attempt(origin: origin, input: input, names: rest, completion: completion)
                    return
                }
                let appName = CampusResolver.capture(#"name="appName"\s+value="([^"]+)""#, in: html) ?? name
                completion(.success(CampusSite(input: input, origin: origin, appName: appName, loginURL: login,
                                               ssoURL: CampusResolver.ssoLink(in: html, base: "\(origin)/campus/") ?? "")))
            }
        }.resume()
    }

    /// The "Google Single Sign-On" link on a sign-in page (or the first single-sign-on option, if there are several).
    static func ssoLink(in html: String, base: String) -> String? {
        let decoded = { (href: String) in href.replacingOccurrences(of: "&amp;", with: "&") }
        var found: [(href: String, label: String)] = []
        if let href = capture(#"id="samlLoginLink"[^>]*href="([^"]+)""#, in: html)
            ?? capture(#"href="([^"]+)"[^>]*id="samlLoginLink""#, in: html) {
            found.append((decoded(href), "link"))
        }
        if let regex = try? NSRegularExpression(pattern: #"<option[^>]*value="([^"]*SSO/[^"]*)"[^>]*>([^<]*)"#, options: [.caseInsensitive]) {
            for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
                guard let href = Range(match.range(at: 1), in: html), let label = Range(match.range(at: 2), in: html) else { continue }
                found.append((decoded(String(html[href])), String(html[label])))
            }
        }
        if found.isEmpty, let href = capture(#"href="([^"]*/campus/SSO/[^"]*)""#, in: html) {
            found.append((decoded(href), "link"))
        }
        let pick = found.first(where: { $0.label.localizedCaseInsensitiveContains("google") }) ?? found.first
        guard let href = pick?.href, let url = URL(string: href, relativeTo: URL(string: base)) else { return nil }
        return url.absoluteURL.absoluteString
    }
}

// MARK: - Scraper

/// Loads school pages in a hidden browser window (signed in with your saved cookies) and reads them.
final class SchoolScraper: NSObject {
    static let shared = SchoolScraper()

    private struct PageResult: Decodable {
        let url: String
        let host: String
        let title: String
        let text: String
        let links: [String]
        let truncated: Bool
        let hasPassword: Bool
    }

    private struct CampusResult: Decodable {
        let url: String
        let host: String
        let loggedIn: Bool
        let apiWorked: Bool
        let lines: [String]
        let categories: [String]
        let students: [String]
        let pageText: String
        let hasPassword: Bool
        let submittedLogin: Bool
        let ssoLinks: [String]
        let term: SchoolTerm?
    }

    private enum Outcome {
        case page(ScrapedPage)
        case signIn(String)
        case failed(String)
        /// More pages to read (one per class Stream, found on the Classroom home page).
        case more([ScrapeJob])
    }

    private var webView: WKWebView?
    private var window: NSWindow?
    private var onLoad: (() -> Void)?
    private var loadToken = 0
    private var runToken = 0

    private var jobs: [ScrapeJob] = []
    private var index = 0
    private var report = ScrapeReport()
    private var settings = SchoolSettings()
    private var credentials: (user: String, password: String)?
    /// Reports (message, pages done, pages in total) – the total can grow as class Streams are found.
    private var progress: ((String, Int, Int) -> Void)?
    private var completion: ((ScrapeReport) -> Void)?

    func run(jobs: [ScrapeJob], settings: SchoolSettings, credentials: (user: String, password: String)?,
             progress: @escaping (String, Int, Int) -> Void, completion: @escaping (ScrapeReport) -> Void) {
        runToken += 1
        self.jobs = jobs
        index = 0
        report = ScrapeReport()
        self.settings = settings
        self.credentials = credentials
        self.progress = progress
        self.completion = completion
        prepareWindow(visible: settings.showBrowserWhileSyncing)
        next()
    }

    func cancel() {
        runToken += 1
        loadToken += 1
        onLoad = nil
        completion = nil
        progress = nil
        webView?.stopLoading()
        window?.orderOut(nil)
    }

    private func next() {
        guard index < jobs.count else {
            finish()
            return
        }
        let job = jobs[index]
        index += 1
        if report.signIn[job.source] != nil {
            next()   // already know this site needs a sign-in
            return
        }
        progress?("Reading \(job.source.shortName): \(job.label)…", index - 1, jobs.count)
        let token = runToken
        scrape(job) { [weak self] outcome in
            guard let self = self, token == self.runToken else { return }
            switch outcome {
            case .page(let page):
                self.report.pages.append(page)
            case .signIn(let message):
                self.report.signIn[job.source] = message
            case .failed(let message):
                self.report.warnings.append("\(job.source.rawValue) – \(job.label): \(message)")
            case .more(let found):
                self.jobs.append(contentsOf: found)
            }
            self.next()
        }
    }

    private func finish() {
        let completion = self.completion
        self.completion = nil
        progress = nil
        window?.orderOut(nil)
        webView?.loadHTMLString("", baseURL: nil)
        completion?(report)
    }

    private func scrape(_ job: ScrapeJob, completion: @escaping (Outcome) -> Void) {
        load(job.url) { [weak self] in
            guard let self = self else { return }
            switch job.kind {
            case .classroom: self.readClassroom(job, maxChars: 100_000, scrollRounds: 18, completion: completion)
            case .classroomStream: self.readClassroom(job, maxChars: 25_000, scrollRounds: 3, completion: completion)
            case .classroomClasses: self.readClasses(job, completion: completion)
            case .campus: self.readCampus(job, step: .first, completion: completion)
            case .page: self.readPage(job, completion: completion)
            }
        }
    }

    // MARK: Readers

    private func readClassroom(_ job: ScrapeJob, maxChars: Int, scrollRounds: Int, completion: @escaping (Outcome) -> Void) {
        let args: [String: Any] = ["mode": "classroom", "maxChars": maxChars, "maxLinks": 400, "scrollRounds": scrollRounds]
        evaluate(SchoolJS.readPage, arguments: args, timeout: 75, as: PageResult.self) { result in
            switch result {
            case .failure(let error):
                completion(.failed(error.localizedDescription))
            case .success(let page):
                guard page.host == "classroom.google.com", !page.hasPassword else {
                    let shown = page.host.isEmpty ? "a sign-in page" : page.host
                    completion(.signIn("Google Classroom needs you to sign in (it opened \(shown) instead)."))
                    return
                }
                completion(.page(ScrapedPage(source: job.source, label: job.label, url: page.url,
                                             text: page.text, links: page.links, truncated: page.truncated)))
            }
        }
    }

    /// Reads the class cards on the Classroom home page and queues each class's Stream.
    private func readClasses(_ job: ScrapeJob, completion: @escaping (Outcome) -> Void) {
        let args: [String: Any] = ["mode": "classes", "maxChars": 2_000, "maxLinks": 60, "scrollRounds": 2]
        evaluate(SchoolJS.readPage, arguments: args, timeout: 60, as: PageResult.self) { result in
            switch result {
            case .failure(let error):
                completion(.failed(error.localizedDescription))
            case .success(let page):
                guard page.host == "classroom.google.com", !page.hasPassword else {
                    completion(.signIn("Google Classroom needs you to sign in."))
                    return
                }
                var streams: [ScrapeJob] = []
                for link in page.links {
                    guard let split = link.range(of: " -> ", options: .backwards),
                          let url = URL(string: String(link[split.upperBound...])) else { continue }
                    // Class cards read "Class name  Section  Teacher"; the first part is enough for a label.
                    let name = String(link[..<split.lowerBound]).trimmed
                    let short = name.count > 60 ? String(name.prefix(60)) + "…" : name
                    streams.append(ScrapeJob(kind: .classroomStream, source: .classroom,
                                             label: "Class Stream ▸ \(short.isEmpty ? url.lastPathComponent : short)", url: url))
                    if streams.count >= 20 { break }
                }
                if streams.isEmpty {
                    completion(.failed("No classes were found on the Classroom home page."))
                } else {
                    completion(.more(streams))
                }
            }
        }
    }

    private func readPage(_ job: ScrapeJob, completion: @escaping (Outcome) -> Void) {
        let args: [String: Any] = ["mode": "page", "maxChars": 60_000, "maxLinks": 300, "scrollRounds": 4]
        evaluate(SchoolJS.readPage, arguments: args, timeout: 60, as: PageResult.self) { result in
            switch result {
            case .failure(let error):
                completion(.failed(error.localizedDescription))
            case .success(let page):
                if page.hasPassword && page.text.count < 4000 {
                    completion(.signIn("\(page.host) showed a sign-in page."))
                    return
                }
                let label = page.title.trimmed.isEmpty ? job.label : "\(job.label): \(page.title.trimmed)"
                completion(.page(ScrapedPage(source: job.source, label: label, url: page.url,
                                             text: page.text, links: page.links, truncated: page.truncated)))
            }
        }
    }

    private enum CampusStep { case first, onSignInPage, afterSignIn }

    /// Reads Infinite Campus. If it has signed you out, signs back in – with Google (single sign-on, using the Google
    /// sign-in the browser remembers) or with the saved username and password – then reads again.
    private func readCampus(_ job: ScrapeJob, step: CampusStep, completion: @escaping (Outcome) -> Void) {
        let expectedHost = job.url.host ?? ""
        let site = settings.campusSite
        let usesGoogle = settings.campusSignIn == .google
        var args: [String: Any] = [
            "lookbackDays": max(1, settings.doneLookbackDays),
            "expectedHost": expectedHost,
            "username": "",
            "password": "",
            "tryLogin": false,
            "onlyThisQuarter": settings.onlyThisQuarter,
            "quarterStart": "",
            "quarterEnd": "",
        ]
        if settings.onlyThisQuarter, settings.quarterManual, let start = settings.quarterStart, let end = settings.quarterEnd {
            args["quarterStart"] = SchoolDates.dayString(start)
            args["quarterEnd"] = SchoolDates.dayString(end)
        }
        if !usesGoogle, step != .afterSignIn, let credentials = credentials {
            args["username"] = credentials.user
            args["password"] = credentials.password
            args["tryLogin"] = true
        }
        evaluate(SchoolJS.readCampus, arguments: args, timeout: 90, as: CampusResult.self) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let error):
                completion(.failed(error.localizedDescription))
                return
            case .success(let campus):
                if campus.loggedIn {
                    if let term = campus.term { self.report.term = term }
                    completion(.page(Self.campusPage(campus, job: job, link: site?.loginURL ?? job.url.absoluteString)))
                    return
                }
                if step == .afterSignIn {
                    completion(.signIn(usesGoogle
                        ? "Google sign-in didn't get you into Infinite Campus. Click Sign In… and sign in with your school Google account."
                        : "Infinite Campus didn't accept the saved username and password. Sign in again, or update them under Setup."))
                    return
                }
                if campus.submittedLogin {
                    // We filled in the saved username and password; wait for the portal to load, then read again.
                    self.progress?("Signing in to Infinite Campus…", self.index - 1, self.jobs.count)
                    self.waitForNavigation(timeout: 20) { [weak self] in
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            self?.readCampus(job, step: .afterSignIn, completion: completion)
                        }
                    }
                    return
                }
                if usesGoogle, let sso = URL(string: site?.ssoURL ?? "").flatMap({ $0.host == nil ? nil : $0 })
                    ?? campus.ssoLinks.compactMap({ URL(string: $0) }).first {
                    self.progress?("Signing in to Infinite Campus with Google…", self.index - 1, self.jobs.count)
                    self.followSignIn(sso, returningTo: expectedHost) { [weak self] landed in
                        if landed {
                            self?.readCampus(job, step: .afterSignIn, completion: completion)
                        } else {
                            completion(.signIn("Infinite Campus signs in through Google, and Google needs you to sign in or pick your school account. Click Sign In…, then sync again."))
                        }
                    }
                    return
                }
                if !usesGoogle, step == .first, self.credentials != nil, let login = URL(string: site?.loginURL ?? ""),
                   login.host != nil, !campus.hasPassword {
                    // Signed out and not on the sign-in page: open it so the saved login can be filled in.
                    self.load(login) { [weak self] in
                        self?.readCampus(job, step: .onSignInPage, completion: completion)
                    }
                    return
                }
                if usesGoogle {
                    completion(.signIn("Couldn't find the Google sign-in link for your Infinite Campus. Click Sign In… and sign in there."))
                } else if campus.host != expectedHost {
                    completion(.signIn("Infinite Campus needs you to sign in (it opened \(campus.host.isEmpty ? "another page" : campus.host))."))
                } else {
                    completion(.signIn("Infinite Campus needs you to sign in."))
                }
            }
        }
    }

    /// Opens a single-sign-on link and waits for the hand-offs (Infinite Campus → Google → back) to finish.
    /// Calls back with true once the browser is back on `host`, or false if it stopped somewhere else
    /// (for example Google asking you to sign in or pick an account).
    private func followSignIn(_ url: URL, returningTo host: String, then: @escaping (Bool) -> Void) {
        let token = runToken
        let deadline = Date().addingTimeInterval(40)
        load(url) { [weak self] in
            self?.waitForSignIn(host: host, deadline: deadline, token: token, lastURL: "", stillSince: Date(), then: then)
        }
    }

    private func waitForSignIn(host: String, deadline: Date, token: Int, lastURL: String, stillSince: Date,
                               then: @escaping (Bool) -> Void) {
        guard token == runToken, let webView = webView else { return }
        let url = webView.url
        let current = url?.absoluteString ?? ""
        if !webView.isLoading, url?.host == host, url?.path.contains("/SSO/") == false {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self = self, token == self.runToken else { return }
                then(true)
            }
            return
        }
        let now = Date()
        let still = (webView.isLoading || current != lastURL) ? now : stillSince
        // Sitting on the same page elsewhere for a while means it's waiting for you.
        if now > deadline || now.timeIntervalSince(still) > 6 {
            then(false)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.waitForSignIn(host: host, deadline: deadline, token: token, lastURL: current, stillSince: still, then: then)
        }
    }

    private static func campusPage(_ campus: CampusResult, job: ScrapeJob, link: String) -> ScrapedPage {
        var text = ""
        if campus.apiWorked {
            if campus.students.count > 1 { text += "STUDENTS: " + campus.students.joined(separator: ", ") + "\n" }
            text += "ASSIGNMENTS (one per line; times are the school's local time):\n"
            text += campus.lines.isEmpty ? "(none in this date range)\n" : campus.lines.joined(separator: "\n") + "\n"
            if !campus.categories.isEmpty {
                text += "\nGRADE CATEGORIES (how much each category counts in its class):\n" + campus.categories.joined(separator: "\n") + "\n"
            }
        } else {
            text += "(Infinite Campus's assignment list wasn't available, so this is the text of the page instead.)\n" + campus.pageText
        }
        let limit = 120_000
        return ScrapedPage(source: job.source, label: job.label, url: link,
                           text: String(text.prefix(limit)), links: [], truncated: text.count > limit)
    }

    // MARK: Browser plumbing

    /// Runs a page script (an async JavaScript function body that returns a JSON string) and decodes its result.
    private func evaluate<T: Decodable>(_ body: String, arguments: [String: Any], timeout: TimeInterval, retries: Int = 1,
                                        as type: T.Type, completion: @escaping (Result<T, Error>) -> Void) {
        guard let webView = webView else {
            completion(.failure(ScrapeIssue("The browser isn't ready.")))
            return
        }
        let token = runToken
        var finished = false
        let finish: (Result<T, Error>) -> Void = { result in
            guard !finished else { return }
            finished = true
            completion(result)
        }
        webView.callAsyncJavaScript(body, arguments: arguments, in: nil, in: .defaultClient) { [weak self] result in
            switch result {
            case .success(let value):
                guard let json = value as? String else {
                    finish(.failure(ScrapeIssue("The page didn't return anything readable.")))
                    return
                }
                do {
                    finish(.success(try JSONDecoder().decode(T.self, from: Data(json.utf8))))
                } catch {
                    finish(.failure(ScrapeIssue("The page's data couldn't be read.")))
                }
            case .failure(let error):
                // Usually the page navigated (a redirect) while the script ran: wait a moment and try again.
                guard retries > 0, !finished else {
                    finish(.failure(ScrapeIssue("The page script failed: \(error.localizedDescription)")))
                    return
                }
                finished = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    guard let self = self, token == self.runToken else { return }
                    self.evaluate(body, arguments: arguments, timeout: timeout, retries: retries - 1, as: type, completion: completion)
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            finish(.failure(ScrapeIssue("The page took too long to load.")))
        }
    }

    private func load(_ url: URL, then: @escaping () -> Void) {
        guard let webView = webView else {
            then()
            return
        }
        waitForNavigation(timeout: 45, then: then)
        webView.load(URLRequest(url: url))
    }

    /// Calls `then` once the current page finishes loading (or after `timeout`, carrying on with whatever loaded).
    private func waitForNavigation(timeout: TimeInterval, then: @escaping () -> Void) {
        loadToken += 1
        let token = loadToken
        onLoad = then
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self = self, self.loadToken == token, let done = self.onLoad else { return }
            self.onLoad = nil
            done()
        }
    }

    fileprivate func navigationEnded() {
        guard let done = onLoad else { return }
        onLoad = nil
        let token = loadToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self = self, self.loadToken == token else { return }
            done()
        }
    }

    fileprivate func navigationFailed(_ error: Error) {
        // A cancelled load was replaced by a redirect or a newer load; wait for that one instead.
        if (error as NSError).code == NSURLErrorCancelled { return }
        navigationEnded()
    }

    private func prepareWindow(visible: Bool) {
        if webView == nil {
            let view = SchoolWeb.makeWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 900))
            view.navigationDelegate = self
            let window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "School To-Do – Syncing"
            window.isReleasedWhenClosed = false
            window.isExcludedFromWindowsMenu = true
            window.contentView = view
            window.center()
            webView = view
            self.window = window
        }
        guard let window = window else { return }
        if visible {
            window.alphaValue = 1
            window.ignoresMouseEvents = false
            window.collectionBehavior = [.moveToActiveSpace]
            window.orderFront(nil)
        } else {
            // On screen but fully transparent and click-through, so pages load at full speed without being seen.
            window.alphaValue = 0
            window.ignoresMouseEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
            window.orderFrontRegardless()
        }
    }
}

extension SchoolScraper: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        navigationEnded()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        navigationFailed(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        navigationFailed(error)
    }
}

// MARK: - Sign-in browser

/// A small browser window for signing in to Google and Infinite Campus. It shares cookies with the sync.
final class SchoolBrowser: NSObject, ObservableObject {
    static let shared = SchoolBrowser()

    @Published private(set) var address = ""
    @Published private(set) var pageTitle = ""
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var loading = false
    @Published var message = ""

    private(set) lazy var webView: WKWebView = {
        let view = SchoolWeb.makeWebView(frame: NSRect(x: 0, y: 0, width: 1100, height: 760))
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        return view
    }()

    private var window: NSWindow?
    private var popups: [NSWindow] = []

    func open(_ url: URL?, message: String) {
        self.message = message
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 820),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "Sign In – School To-Do"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SchoolBrowserView(browser: self))
            window.delegate = self
            window.center()
            self.window = window
        }
        if let url = url { webView.load(URLRequest(url: url)) }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func go(to text: String) {
        if let url = SchoolWeb.normalizedURL(text) { webView.load(URLRequest(url: url)) }
    }

    func back() { webView.goBack() }
    func forward() { webView.goForward() }
    func reload() { webView.reload() }
    func close() { window?.close() }

    fileprivate func refresh() {
        address = webView.url?.absoluteString ?? ""
        pageTitle = webView.title ?? ""
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        loading = webView.isLoading
    }

    fileprivate func openPopup(configuration: WKWebViewConfiguration) -> WKWebView {
        // Sign-in pop-ups (e.g. "Sign in with Google") must use the configuration WebKit hands us so they can talk back to the page.
        let popup = WKWebView(frame: NSRect(x: 0, y: 0, width: 520, height: 680), configuration: configuration)
        popup.customUserAgent = SchoolWeb.userAgent
        popup.uiDelegate = self
        let window = NSWindow(contentRect: popup.frame, styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Sign In"
        window.isReleasedWhenClosed = false
        window.contentView = popup
        window.center()
        window.makeKeyAndOrderFront(nil)
        popups.append(window)
        return popup
    }

    fileprivate func closePopup(_ webView: WKWebView) {
        guard let window = popups.first(where: { $0.contentView === webView }) else { return }
        window.close()
        popups.removeAll { $0 === window }
    }

    fileprivate func mainWindowClosed() {
        for popup in popups { popup.close() }
        popups.removeAll()
        SchoolPlanner.shared.signInWindowClosed()
    }

    fileprivate var mainWindow: NSWindow? { window }
}

extension SchoolBrowser: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { refresh() }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { refresh() }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { refresh() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { refresh() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { refresh() }
}

extension SchoolBrowser: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        openPopup(configuration: configuration)
    }

    func webViewDidClose(_ webView: WKWebView) {
        closePopup(webView)
    }
}

extension SchoolBrowser: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === mainWindow else { return }
        mainWindowClosed()
    }
}

struct SchoolBrowserView: View {
    @ObservedObject var browser: SchoolBrowser
    @ObservedObject private var planner = SchoolPlanner.shared
    @State private var typed = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { browser.back() } label: { Image(systemName: "chevron.left") }
                    .disabled(!browser.canGoBack)
                    .help("Back")
                Button { browser.forward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!browser.canGoForward)
                    .help("Forward")
                Button { browser.reload() } label: { Image(systemName: browser.loading ? "xmark" : "arrow.clockwise") }
                    .help("Reload")
                TextField("Address", text: $typed)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { browser.go(to: typed) }
                Button("Sync This Page Too") {
                    planner.addExtraPage(browser.webView.url)
                }
                .help("Also read this page every time School To-Do syncs (for example your Infinite Campus assignments page).")
                .disabled(browser.address.isEmpty || planner.settings.extraPages.contains(browser.address))
                Button("Done") { browser.close() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(8)
            if !browser.message.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                    Text(browser.message)
                    Spacer()
                }
                .font(.callout)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.accentColor.opacity(0.12))
            }
            Divider()
            HostedNSView(view: browser.webView)
        }
        .frame(minWidth: 700, minHeight: 500)
        .onAppear { typed = browser.address }
        .onChange(of: browser.address) { typed = $0 }
    }
}

// MARK: - Page scripts

/// JavaScript run inside the school pages (in an isolated script world, so the page can't interfere with it).
/// Each is the body of an async function and returns a JSON string.
enum SchoolJS {
    static let shared = #"""
    const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
    const visible = (el) => { const box = el.getBoundingClientRect(); return box.width > 0 && box.height > 0; };
    const textOf = (doc, depth) => {
      let out = doc.body ? (doc.body.innerText || '') : '';
      if (depth < 3) {
        for (const frame of doc.querySelectorAll('iframe, frame')) {
          try { const inner = frame.contentDocument; if (inner) out += '\n' + textOf(inner, depth + 1); } catch (e) {}
        }
      }
      return out;
    };
    const anchorsOf = (doc, depth, list) => {
      list.push(...doc.querySelectorAll('a[href]'));
      if (depth < 3) {
        for (const frame of doc.querySelectorAll('iframe, frame')) {
          try { if (frame.contentDocument) anchorsOf(frame.contentDocument, depth + 1, list); } catch (e) {}
        }
      }
      return list;
    };
    const tidy = (text) => text.replace(/[ \t]+\n/g, '\n').replace(/\n{3,}/g, '\n\n');
    """#

    /// Waits for a page to finish rendering (opening collapsed sections and scrolling to load more), then returns
    /// its text and links. Arguments: mode ("classroom", "classes" or "page"), maxChars, maxLinks, scrollRounds.
    static let readPage = shared + #"""
    const expand = () => {
      let clicked = 0;
      // Collapsed sections ("No due date", "This week", "Later"…).
      for (const el of document.querySelectorAll('[aria-expanded="false"]')) {
        if (clicked >= 25) break;
        if (el.closest('header, nav, [role="navigation"], [role="banner"], [role="menu"], [role="dialog"], [role="listbox"]')) continue;
        if (el.hasAttribute('aria-haspopup') || !visible(el)) continue;
        el.click();
        clicked += 1;
      }
      // "View all" / "Show more" buttons that load the rest of a list (buttons only, so the page doesn't navigate away).
      for (const el of document.querySelectorAll('button, [role="button"]')) {
        if (clicked >= 40) break;
        if (el.getAttribute('data-mt-clicked') || !visible(el)) continue;
        const label = (el.innerText || el.getAttribute('aria-label') || '').replace(/\s+/g, ' ').trim();
        if (!/^(view all|show all|show more|view more|load more|see all|see more|more)$/i.test(label)) continue;
        el.setAttribute('data-mt-clicked', '1');
        el.click();
        clicked += 1;
      }
    };
    const scrollDown = () => {
      window.scrollTo(0, document.documentElement.scrollHeight);
      for (const el of document.querySelectorAll('main, [role="main"], div, section')) {
        if (el.scrollHeight > el.clientHeight + 40) {
          const overflow = getComputedStyle(el).overflowY;
          if (overflow === 'auto' || overflow === 'scroll') el.scrollTop = el.scrollHeight;
        }
      }
    };
    const started = Date.now();
    let last = -1, stable = 0, rounds = 0;
    while (Date.now() - started < 30000) {
      await sleep(700);
      if (rounds < scrollRounds) { expand(); scrollDown(); }
      rounds += 1;
      const length = textOf(document, 0).length;
      stable = (length === last && length > 150) ? stable + 1 : 0;
      last = length;
      if (stable >= 3 && Date.now() - started > 3500) break;
    }
    window.scrollTo(0, 0);
    const text = tidy(textOf(document, 0));
    const links = [];
    const seen = new Set();
    for (const a of anchorsOf(document, 0, [])) {
      const href = a.href;
      if (!href || !href.startsWith('http') || seen.has(href)) continue;
      if (mode === 'classroom' || mode === 'classes') {
        let path = '';
        try { path = new URL(href).pathname; } catch (e) { continue; }
        // classroom: links to one assignment or post (/c/<class>/a/<id>/details, /c/<class>/p/<id>, …)
        // classes: links to a class's Stream (/u/0/c/<class>)
        const pattern = mode === 'classroom' ? /\/c\/[^\/]+\/[a-z]+\/[^\/]+/ : /^(\/u\/[0-9]+)?\/c\/[^\/]+\/?$/;
        if (!pattern.test(path)) continue;
      }
      const label = (a.innerText || a.getAttribute('aria-label') || a.title || '').replace(/\s+/g, ' ').trim();
      if (!label) continue;
      seen.add(href);
      links.push(label.slice(0, 220) + ' -> ' + href);
      if (links.length >= maxLinks) break;
    }
    return JSON.stringify({
      url: location.href,
      host: location.host,
      title: document.title || '',
      text: text.slice(0, maxChars),
      truncated: text.length > maxChars,
      links: links,
      hasPassword: !!document.querySelector('input[type="password"]')
    });
    """#

    /// Reads assignments and grade categories through the Infinite Campus portal's own data feeds (the same ones its
    /// web pages use), signed in with the browser's cookies. If the user isn't signed in and a saved username and
    /// password were passed, fills in the sign-in form on the expected host only.
    /// Arguments: lookbackDays, expectedHost, username, password, tryLogin, onlyThisQuarter, quarterStart, quarterEnd.
    static let readCampus = shared + #"""
    const out = { url: location.href, host: location.host, loggedIn: false, apiWorked: false, lines: [], categories: [],
                  students: [], pageText: '', hasPassword: false, submittedLogin: false, ssoLinks: [], term: null };
    const DAY = 86400000;
    // Grading periods appear in the grades feed as objects with a name and start/end dates. The current one is the
    // period containing today that looks most like a quarter (Q2, T1, "Quarter 2"…), then the shortest (a quarter
    // rather than the semester or year). Progress-report and exam windows are ignored. Between periods: the next one.
    const quarterLike = (name) => /^(q|t|qtr|term|tri|mp)\s*\d|quarter|trimester|marking period|grading period|\bterm\b/i.test(name);
    const notAPeriod = (name) => /progress|report|interim|mid-?term|midterm|exam|final|week/i.test(name);
    const termOf = (json) => {
      const terms = [];
      const walk = (node, depth) => {
        if (!node || typeof node !== 'object' || depth > 10) return;
        if (Array.isArray(node)) { for (const child of node) walk(child, depth + 1); return; }
        const name = node.termName || node.name;
        const start = node.startDate ? Date.parse(node.startDate) : NaN;
        const end = node.endDate ? Date.parse(node.endDate) : NaN;
        if (name && !notAPeriod(String(name)) && !isNaN(start) && !isNaN(end) && end - start >= 35 * DAY) {
          terms.push({ name: String(name), start: start, end: end,
                       startText: String(node.startDate).slice(0, 10), endText: String(node.endDate).slice(0, 10) });
        }
        for (const key in node) { const child = node[key]; if (child && typeof child === 'object') walk(child, depth + 1); }
      };
      walk(json, 0);
      const now = Date.now();
      const rank = (t) => (quarterLike(t.name) ? 0 : 1);
      const current = terms.filter((t) => t.start <= now && now <= t.end + DAY)
        .sort((a, b) => (rank(a) - rank(b)) || ((a.end - a.start) - (b.end - b.start)));
      if (current.length) return current[0];
      const upcoming = terms.filter((t) => t.start > now).sort((a, b) => a.start - b.start);
      return upcoming[0] || null;
    };
    const getJSON = async (path) => {
      try {
        const response = await fetch(path, { credentials: 'include', headers: { 'Accept': 'application/json' } });
        const type = response.headers.get('content-type') || '';
        if (!response.ok || !type.includes('json')) return null;
        return await response.json();
      } catch (e) { return null; }
    };
    const flagNames = ['missing', 'late', 'turnedIn', 'incomplete', 'dropped', 'exempt', 'cheated'];
    const describe = (a, who) => {
      const parts = ['[' + (a.courseName || a.sectionName || 'Unknown class') + '] ' + (a.assignmentName || a.name || 'Untitled')];
      if (a.dueDate) parts.push('due ' + String(a.dueDate).replace('T', ' ').slice(0, 16));
      if (a.assignedDate) parts.push('assigned ' + String(a.assignedDate).slice(0, 10));
      const flags = flagNames.filter((f) => a[f] === true).map((f) => f === 'turnedIn' ? 'turned in' : f);
      if (flags.length) parts.push('flags: ' + flags.join(', '));
      const score = (a.scorePoints !== undefined && a.scorePoints !== null && a.scorePoints !== '') ? a.scorePoints : a.score;
      if (score !== undefined && score !== null && score !== '') {
        parts.push('score ' + score + (a.totalPoints ? ' / ' + a.totalPoints : ''));
      } else if (a.totalPoints) {
        parts.push(a.totalPoints + ' pts possible');
      }
      if (a.scorePercentage) parts.push(a.scorePercentage + '%');
      for (const key of Object.keys(a)) {
        if (/categor|group|weight|multiplier/i.test(key) && !/id$/i.test(key)) {
          const value = a[key];
          if (value !== null && value !== undefined && value !== '' && typeof value !== 'object') parts.push(key + ' ' + value);
        }
      }
      if (a.comments) parts.push('comment: ' + String(a.comments).replace(/\s+/g, ' ').slice(0, 160));
      if (who) parts.push('student ' + who);
      return parts.join(' | ');
    };
    const categoryLines = (json, who) => {
      const lines = [];
      const seen = new Set();
      const walk = (node, course, depth) => {
        if (!node || typeof node !== 'object' || depth > 12) return;
        if (Array.isArray(node)) { for (const child of node) walk(child, course, depth + 1); return; }
        const here = node.courseName || node.sectionName || course;
        const name = node.name || node.groupName || node.categoryName;
        const weight = node.weight;
        if (here && name && weight !== undefined && weight !== null && weight !== '' && typeof weight !== 'object') {
          const line = here + ': ' + name + ' = ' + weight + (node.isWeighted === false ? ' (not weighted)' : '') + (who ? ' (' + who + ')' : '');
          if (!seen.has(line)) { seen.add(line); lines.push(line); }
        }
        for (const key in node) { const child = node[key]; if (child && typeof child === 'object') walk(child, here, depth + 1); }
      };
      walk(json, '', 0);
      return lines.slice(0, 300);
    };
    const setValue = (input, value) => {
      input.focus();
      const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
      setter.call(input, value);
      input.dispatchEvent(new Event('input', { bubbles: true }));
      input.dispatchEvent(new Event('change', { bubbles: true }));
    };

    await sleep(1500);   // the portal is a single-page app; let it settle
    out.hasPassword = !!document.querySelector('input[type="password"]');
    if (location.host === expectedHost) {
      const students = await getJSON('/campus/api/portal/students');
      if (Array.isArray(students)) {
        out.loggedIn = true;
        const cutoff = Date.now() - lookbackDays * 86400000;
        const several = students.length > 1;
        for (const student of students.slice(0, 6)) {
          const name = [student.firstName, student.lastName].filter(Boolean).join(' ');
          out.students.push(name);
          const id = student.personID;
          if (id === undefined || id === null) continue;
          const grades = await getJSON('/campus/resources/portal/grades?personID=' + encodeURIComponent(id));
          if (grades) out.categories.push(...categoryLines(grades, several ? name : ''));
          const found = grades ? termOf(grades) : null;
          if (found && !out.term) out.term = { name: found.name, start: found.startText, end: found.endText };
          // Only this quarter: your own dates if given, otherwise the grading period found above.
          let range = null;
          if (onlyThisQuarter && quarterStart && quarterEnd) {
            range = { start: Date.parse(quarterStart), end: Date.parse(quarterEnd) + DAY };
          } else if (onlyThisQuarter && found) {
            // Plus two weeks after the quarter, for work that's already been handed out.
            range = { start: found.start, end: found.end + 15 * DAY };
          }
          const list = await getJSON('/campus/api/portal/assignment/listView?personID=' + encodeURIComponent(id));
          if (Array.isArray(list)) {
            out.apiWorked = true;
            const rows = [];
            for (const a of list) {
              if (!a || typeof a !== 'object') continue;
              const due = a.dueDate ? Date.parse(a.dueDate) : NaN;
              if (range && !isNaN(due) && (due < range.start || due >= range.end)) continue;   // another quarter
              if (!a.missing && !isNaN(due) && due < cutoff) continue;   // old, not missing: leave out
              rows.push({ due: isNaN(due) ? Infinity : due, line: describe(a, several ? name : '') });
            }
            rows.sort((x, y) => x.due - y.due);
            out.lines.push(...rows.slice(0, 600).map((r) => r.line));
          }
        }
      }
    }
    if (!out.loggedIn && tryLogin && out.hasPassword && location.host === expectedHost && username && password) {
      const pass = Array.from(document.querySelectorAll('input[type="password"]')).find(visible);
      let user = document.querySelector('input[name="username"], input#username, input[autocomplete="username"]');
      if (!user && pass) {
        const fields = Array.from(document.querySelectorAll('input')).filter((i) =>
          visible(i) && ['text', 'email', ''].includes((i.getAttribute('type') || '').toLowerCase()) &&
          (i.compareDocumentPosition(pass) & Node.DOCUMENT_POSITION_FOLLOWING));
        user = fields.pop() || null;
      }
      if (user && pass) {
        setValue(user, username);
        setValue(pass, password);
        const form = pass.form;
        const button = (form && form.querySelector('button[type="submit"], input[type="submit"], button:not([type])')) ||
          document.querySelector('#signinbtn, button[type="submit"], input[type="submit"]');
        setTimeout(() => {
          if (button) { button.click(); }
          else if (form && form.requestSubmit) { form.requestSubmit(); }
          else if (form) { form.submit(); }
        }, 300);
        out.submittedLogin = true;
      }
    }
    out.ssoLinks = Array.from(document.querySelectorAll('a[href*="/SSO/"]')).map((a) => a.href).slice(0, 5);
    out.pageText = tidy(textOf(document, 0)).slice(0, 60000);
    return JSON.stringify(out);
    """#
}
