import SwiftUI
import AppKit
import CryptoKit

// MARK: - Model

enum SchoolStatus: String, Codable, CaseIterable, Identifiable {
    case todo, missing, done

    var id: String { rawValue }

    var title: String {
        switch self {
        case .todo: return "To-Do"
        case .missing: return "Missing"
        case .done: return "Done"
        }
    }

    var icon: String {
        switch self {
        case .todo: return "checklist"
        case .missing: return "exclamationmark.triangle"
        case .done: return "checkmark.seal"
        }
    }
}

enum SchoolSource: String, Codable, CaseIterable {
    case classroom = "Google Classroom"
    case campus = "Infinite Campus"
    case both = "Both"
    case other = "Other"

    var shortName: String {
        switch self {
        case .classroom: return "Classroom"
        case .campus: return "Campus"
        case .both: return "Classroom + Campus"
        case .other: return "Web"
        }
    }
}

/// How much a piece of work can move the class grade (decided by the AI from category weights, points and kind of work).
enum GradeImpact: String, Codable, CaseIterable, Identifiable {
    case major, high, medium, low, minimal

    var id: String { rawValue }

    var rank: Int {
        switch self {
        case .major: return 5
        case .high: return 4
        case .medium: return 3
        case .low: return 2
        case .minimal: return 1
        }
    }

    var title: String {
        switch self {
        case .major: return "Counts the most"
        case .high: return "Counts a lot"
        case .medium: return "Counts some"
        case .low: return "Counts a little"
        case .minimal: return "Barely counts"
        }
    }

    var color: Color {
        switch self {
        case .major: return .red
        case .high: return .orange
        case .medium: return .yellow
        case .low: return .blue
        case .minimal: return .gray
        }
    }
}

/// One piece of schoolwork, as organised by the AI.
struct SchoolItem: Codable, Hashable, Identifiable {
    var id: String
    var title: String
    var course: String
    var source: SchoolSource
    var status: SchoolStatus
    var due: String
    var kind: String
    var impact: GradeImpact
    var weight: String
    var points: String
    var url: String
    var notes: String
}

extension SchoolItem {
    /// The due date, or nil when there isn't one. A date without a time counts as the end of that day.
    var dueDate: Date? { SchoolDates.parse(due) }
    var dueHasTime: Bool { due.trimmed.count >= 16 }
    var dueDay: String { String(due.trimmed.prefix(10)) }

    var link: URL? {
        let text = url.trimmed
        guard text.hasPrefix("http"), let url = URL(string: text) else { return nil }
        return url
    }

    static func normalize(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// A Google Classroom link that points at this one piece of work (stable across syncs), not a list page.
    var itemLinkKey: String? {
        guard let url = link, url.host?.contains("classroom.google.com") == true else { return nil }
        var path = url.path
        if let range = path.range(of: "^/u/[0-9]+", options: .regularExpression) { path.removeSubrange(range) }
        guard path.range(of: "^/c/[^/]+/[a-z]+/[^/]+", options: .regularExpression) != nil else { return nil }
        return "u:" + path
    }

    var courseTitleKey: String { "c:" + Self.normalize(course) + "|" + Self.normalize(title) }
    var datedKey: String { courseTitleKey + "|" + dueDay }
    var titleDateKey: String { "n:" + Self.normalize(title) + "|" + dueDay }

    /// Every key a check-off is remembered under, so it survives a moved due date,
    /// a re-spelled class name or a changed link.
    var memoryKeys: [String] {
        [itemLinkKey, datedKey, titleDateKey, courseTitleKey].compactMap { $0 }
    }
}

enum SchoolDates {
    private static let withTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return f
    }()

    private static let dateOnly: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    private static let weekday: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEE")
        return f
    }()

    private static let shortDate: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEMMMd")
        return f
    }()

    static func parse(_ text: String) -> Date? {
        let t = text.trimmed
        if t.count >= 16, let date = withTime.date(from: String(t.prefix(16))) { return date }
        if t.count >= 10, let date = dateOnly.date(from: String(t.prefix(10))) {
            return Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: date)
        }
        return nil
    }

    static func describe(_ item: SchoolItem, now: Date = Date()) -> String {
        guard let date = item.dueDate else { return "No due date" }
        let cal = Calendar.current
        let at = item.dueHasTime ? " at " + time.string(from: date) : ""
        if cal.isDateInToday(date) { return "Due today" + at }
        if cal.isDateInTomorrow(date) { return "Due tomorrow" + at }
        if cal.isDateInYesterday(date) { return "Was due yesterday" + at }
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: date)).day ?? 0
        if days > 1 && days < 7 { return "Due " + weekday.string(from: date) + at }
        return (days < 0 ? "Was due " : "Due ") + shortDate.string(from: date) + at
    }

    static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: Date())
    }
}

/// Due-date buckets used when the list is sorted by date.
enum DueGroup: Int, CaseIterable, Identifiable {
    case overdue, today, tomorrow, thisWeek, later, noDate

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .overdue: return "Past Due"
        case .today: return "Due Today"
        case .tomorrow: return "Due Tomorrow"
        case .thisWeek: return "This Week"
        case .later: return "Later"
        case .noDate: return "No Due Date"
        }
    }

    static func of(_ date: Date?, now: Date = Date()) -> DueGroup {
        guard let date = date else { return .noDate }
        let cal = Calendar.current
        if date < now && !cal.isDateInToday(date) { return .overdue }
        if cal.isDateInToday(date) { return .today }
        if cal.isDateInTomorrow(date) { return .tomorrow }
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: date)).day ?? 0
        return days < 7 ? .thisWeek : .later
    }
}

// MARK: - Settings & saved data

enum AIProvider: String, Codable, CaseIterable, Identifiable {
    case claude, openAI

    var id: String { rawValue }

    var title: String {
        switch self {
        case .claude: return "Claude (Anthropic)"
        case .openAI: return "ChatGPT (OpenAI)"
        }
    }

    var keyAccount: String {
        switch self {
        case .claude: return "school-todo-anthropic-api-key"
        case .openAI: return "school-todo-openai-api-key"
        }
    }

    var keyPlaceholder: String {
        switch self {
        case .claude: return "sk-ant-…"
        case .openAI: return "sk-…"
        }
    }

    var keyPage: URL {
        switch self {
        case .claude: return URL(string: "https://console.anthropic.com/settings/keys")!
        case .openAI: return URL(string: "https://platform.openai.com/api-keys")!
        }
    }

    var companyName: String {
        switch self {
        case .claude: return "Anthropic"
        case .openAI: return "OpenAI"
        }
    }
}

struct SchoolModelChoice: Identifiable {
    let id: String
    let name: String
}

enum SchoolModels {
    static let claudeDefault = "claude-opus-5-5"
    static let openAIDefault = "gpt-5.6"

    static let claude: [SchoolModelChoice] = [
        SchoolModelChoice(id: "claude-opus-5-5", name: "Claude Opus 5.5 – most accurate"),
        SchoolModelChoice(id: "claude-sonnet-5-5", name: "Claude Sonnet 5.5 – faster, about half the price"),
        SchoolModelChoice(id: "claude-haiku-5-5", name: "Claude Haiku 5.5 – fastest and cheapest"),
    ]
}

struct SchoolSettings: Codable, Equatable {
    var classroomEnabled = true
    var classroomStreams = true
    var classroomAccount = 0
    var campusEnabled = false
    var campusURL = ""
    var rememberCampusLogin = false
    var provider = AIProvider.claude
    var claudeModel = SchoolModels.claudeDefault
    var openAIModel = SchoolModels.openAIDefault
    var doneLookbackDays = 14
    var autoSyncHours = 0
    var extraPages: [String] = []
    var showBrowserWhileSyncing = false
    var notifyNewWork = true
    var sortByWeight = true

    var model: String {
        let id = (provider == .claude ? claudeModel : openAIModel).trimmed
        return id.isEmpty ? (provider == .claude ? SchoolModels.claudeDefault : SchoolModels.openAIDefault) : id
    }

    init() {}

    // Reads older settings files that are missing newer fields.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SchoolSettings()
        classroomEnabled = try c.decodeIfPresent(Bool.self, forKey: .classroomEnabled) ?? d.classroomEnabled
        classroomStreams = try c.decodeIfPresent(Bool.self, forKey: .classroomStreams) ?? d.classroomStreams
        classroomAccount = try c.decodeIfPresent(Int.self, forKey: .classroomAccount) ?? d.classroomAccount
        campusEnabled = try c.decodeIfPresent(Bool.self, forKey: .campusEnabled) ?? d.campusEnabled
        campusURL = try c.decodeIfPresent(String.self, forKey: .campusURL) ?? d.campusURL
        rememberCampusLogin = try c.decodeIfPresent(Bool.self, forKey: .rememberCampusLogin) ?? d.rememberCampusLogin
        provider = (try? c.decodeIfPresent(AIProvider.self, forKey: .provider)) ?? d.provider
        claudeModel = try c.decodeIfPresent(String.self, forKey: .claudeModel) ?? d.claudeModel
        openAIModel = try c.decodeIfPresent(String.self, forKey: .openAIModel) ?? d.openAIModel
        doneLookbackDays = try c.decodeIfPresent(Int.self, forKey: .doneLookbackDays) ?? d.doneLookbackDays
        autoSyncHours = try c.decodeIfPresent(Int.self, forKey: .autoSyncHours) ?? d.autoSyncHours
        extraPages = try c.decodeIfPresent([String].self, forKey: .extraPages) ?? d.extraPages
        showBrowserWhileSyncing = try c.decodeIfPresent(Bool.self, forKey: .showBrowserWhileSyncing) ?? d.showBrowserWhileSyncing
        notifyNewWork = try c.decodeIfPresent(Bool.self, forKey: .notifyNewWork) ?? d.notifyNewWork
        sortByWeight = try c.decodeIfPresent(Bool.self, forKey: .sortByWeight) ?? d.sortByWeight
    }
}

struct SchoolSaved: Codable {
    var items: [SchoolItem] = []
    var lastSync: Date?
    var warnings: [String] = []
    var payloadHash = ""
    var servedBy = ""
    /// Length of the AI's last answer, used to estimate progress next time.
    var answerLength = 0

    init(items: [SchoolItem] = [], lastSync: Date? = nil, warnings: [String] = [], payloadHash: String = "",
         servedBy: String = "", answerLength: Int = 0) {
        self.items = items
        self.lastSync = lastSync
        self.warnings = warnings
        self.payloadHash = payloadHash
        self.servedBy = servedBy
        self.answerLength = answerLength
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decodeIfPresent([SchoolItem].self, forKey: .items) ?? []
        lastSync = try c.decodeIfPresent(Date.self, forKey: .lastSync)
        warnings = try c.decodeIfPresent([String].self, forKey: .warnings) ?? []
        payloadHash = try c.decodeIfPresent(String.self, forKey: .payloadHash) ?? ""
        servedBy = try c.decodeIfPresent(String.self, forKey: .servedBy) ?? ""
        answerLength = try c.decodeIfPresent(Int.self, forKey: .answerLength) ?? 0
    }
}

// MARK: - Planner

/// Keeps the school to-do list: runs the scrape → AI → list pipeline, remembers check-offs and syncs on a timer.
final class SchoolPlanner: ObservableObject {
    static let shared = SchoolPlanner()

    enum Phase: Equatable {
        case idle
        case working(String)
        case failed(String)
    }

    private static let settingsKey = "schoolTodoSettings"
    private static let listFile = "school-todo.json"
    private static let checkedFile = "school-todo-checked.json"
    private static let campusUserAccount = "school-todo-campus-username"
    private static let campusPasswordAccount = "school-todo-campus-password"

    @Published var settings: SchoolSettings {
        didSet { if settings != oldValue { Prefs.save(Self.settingsKey, settings) } }
    }
    @Published private(set) var saved: SchoolSaved {
        didSet { recountTitles() }
    }
    /// Check-offs: memory key → when it was checked. Kept in its own file so it survives anything else changing.
    @Published private(set) var checked: [String: Date]
    @Published private(set) var phase: Phase = .idle
    /// 0…1 while syncing, for the progress bar. Eases forward inside each step so it never sits still.
    @Published private(set) var progress: Double = 0
    @Published private(set) var notice = ""
    /// Sources whose sign-in has expired, with what to tell the user.
    @Published private(set) var needsSignIn: [SchoolSource: String] = [:]
    /// The exact text sent to the AI last time (shown under Setup for troubleshooting).
    @Published private(set) var lastPayload = ""
    @Published private(set) var keyStatus: [AIProvider: Bool] = [:]

    var isSyncing: Bool {
        if case .working = phase { return true }
        return false
    }

    private var keyCache: [AIProvider: String] = [:]
    private var titleCounts: [String: Int] = [:]
    private var timer: Timer?
    private var lastAttempt: Date?
    private var organizer: AIOrganizer?
    private var notifiedSignIn = Set<SchoolSource>()
    private var progressGoal: Double = 0
    private var progressTimer: Timer?

    private init() {
        settings = Prefs.load(Self.settingsKey, default: SchoolSettings())
        saved = DataStore.load(SchoolSaved.self, from: Self.listFile) ?? SchoolSaved()
        checked = DataStore.load([String: Date].self, from: Self.checkedFile) ?? [:]
        // Remember whether keys exist without touching the keychain at launch.
        for provider in AIProvider.allCases {
            keyStatus[provider] = UserDefaults.standard.bool(forKey: "schoolTodoHasKey.\(provider.rawValue)")
        }
        recountTitles()
    }

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.autoSyncIfDue()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.autoSyncIfDue() }
    }

    // MARK: Keys and logins

    func hasKey(_ provider: AIProvider) -> Bool { keyStatus[provider] ?? false }

    func apiKey(_ provider: AIProvider) -> String? {
        if let key = keyCache[provider] { return key }
        let key = Keychain.string(provider.keyAccount)
        keyCache[provider] = key
        return key
    }

    @discardableResult
    func setAPIKey(_ key: String, for provider: AIProvider) -> Bool {
        let value = key.trimmed
        guard Keychain.set(value.isEmpty ? nil : value, for: provider.keyAccount) else { return false }
        keyCache[provider] = value.isEmpty ? nil : value
        keyStatus[provider] = !value.isEmpty
        UserDefaults.standard.set(!value.isEmpty, forKey: "schoolTodoHasKey.\(provider.rawValue)")
        return true
    }

    var campusUsername: String { Keychain.string(Self.campusUserAccount) ?? "" }

    @discardableResult
    func setCampusLogin(username: String, password: String) -> Bool {
        let ok1 = Keychain.set(username.trimmed, for: Self.campusUserAccount)
        let ok2 = Keychain.set(password, for: Self.campusPasswordAccount)
        return ok1 && ok2
    }

    func forgetCampusLogin() {
        Keychain.set(nil, for: Self.campusUserAccount)
        Keychain.set(nil, for: Self.campusPasswordAccount)
    }

    private var campusCredentials: (user: String, password: String)? {
        guard settings.rememberCampusLogin,
              let user = Keychain.string(Self.campusUserAccount), !user.isEmpty,
              let password = Keychain.string(Self.campusPasswordAccount), !password.isEmpty else { return nil }
        return (user, password)
    }

    // MARK: Lists

    /// What the item counts as right now: your check-off wins, and unfinished work past its due date is missing.
    func status(of item: SchoolItem, now: Date = Date()) -> SchoolStatus {
        if isChecked(item) { return .done }
        if item.status == .todo, let due = item.dueDate, due < now { return .missing }
        return item.status
    }

    func isChecked(_ item: SchoolItem) -> Bool {
        if let key = item.itemLinkKey, checked[key] != nil { return true }
        if checked[item.datedKey] != nil || checked[item.titleDateKey] != nil { return true }
        // Course + title alone only counts when it's unambiguous (e.g. not a daily "Warm-up").
        return checked[item.courseTitleKey] != nil && (titleCounts[item.courseTitleKey] ?? 0) <= 1
    }

    /// True when the student checked it off but the school site doesn't show it as done (yet).
    func checkedOnlyByYou(_ item: SchoolItem) -> Bool { item.status != .done && isChecked(item) }

    func items(_ status: SchoolStatus) -> [SchoolItem] {
        let now = Date()
        let list = saved.items.filter { self.status(of: $0, now: now) == status }
        let far = Date.distantFuture
        switch status {
        case .done:
            return list.sorted { ($0.dueDate ?? .distantPast) > ($1.dueDate ?? .distantPast) }
        case .todo, .missing:
            return list.sorted { a, b in
                if settings.sortByWeight && a.impact.rank != b.impact.rank { return a.impact.rank > b.impact.rank }
                let da = a.dueDate ?? far, db = b.dueDate ?? far
                if da != db { return status == .missing ? da > db : da < db }
                if a.impact.rank != b.impact.rank { return a.impact.rank > b.impact.rank }
                return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
            }
        }
    }

    func count(_ status: SchoolStatus) -> Int {
        let now = Date()
        return saved.items.filter { self.status(of: $0, now: now) == status }.count
    }

    func toggleChecked(_ item: SchoolItem) {
        if isChecked(item) {
            for key in item.memoryKeys { checked.removeValue(forKey: key) }
        } else {
            let now = Date()
            for key in item.memoryKeys { checked[key] = now }
        }
        // Forget check-offs older than a school year.
        let cutoff = Date().addingTimeInterval(-400 * 86400)
        checked = checked.filter { $0.value > cutoff }
        DataStore.save(checked, to: Self.checkedFile)
    }

    func clearCheckOffs() {
        checked = [:]
        DataStore.save(checked, to: Self.checkedFile)
    }

    /// The list as a Markdown checklist, for pasting into notes.
    func markdown() -> String {
        var out = ""
        for status in SchoolStatus.allCases {
            let list = items(status)
            guard !list.isEmpty else { continue }
            out += "## \(status.title)\n"
            for item in list {
                let box = status == .done ? "[x]" : "[ ]"
                let title = item.link.map { "[\(item.title)](\($0.absoluteString))" } ?? item.title
                var details = [item.course, SchoolDates.describe(item)]
                if !item.weight.isEmpty { details.append(item.weight) }
                out += "- \(box) \(title) – \(details.joined(separator: " · "))\n"
            }
            out += "\n"
        }
        return out.isEmpty ? "Nothing on the list yet." : out
    }

    private func recountTitles() {
        var counts: [String: Int] = [:]
        for item in saved.items { counts[item.courseTitleKey, default: 0] += 1 }
        titleCounts = counts
    }

    // MARK: Extra pages

    func addExtraPage(_ url: URL?) {
        guard let text = url?.absoluteString, text.hasPrefix("http"), !settings.extraPages.contains(text) else { return }
        settings.extraPages.append(text)
    }

    func removeExtraPage(_ text: String) {
        settings.extraPages.removeAll { $0 == text }
    }

    // MARK: Syncing

    private var hasSources: Bool {
        settings.classroomEnabled || (settings.campusEnabled && !settings.campusURL.trimmed.isEmpty) || !settings.extraPages.isEmpty
    }

    private func autoSyncIfDue() {
        guard settings.autoSyncHours > 0, hasKey(settings.provider), hasSources, !isSyncing else { return }
        let interval = Double(settings.autoSyncHours) * 3600
        if let last = saved.lastSync, Date().timeIntervalSince(last) < interval { return }
        if let attempt = lastAttempt, Date().timeIntervalSince(attempt) < min(interval, 3600) { return }
        sync(automatic: true)
    }

    /// Called when the sign-in browser closes: carry on if a sync was waiting for a sign-in.
    func signInWindowClosed() {
        guard !isSyncing, hasKey(settings.provider), hasSources else { return }
        if !needsSignIn.isEmpty || saved.lastSync == nil { sync() }
    }

    func cancel() {
        SchoolScraper.shared.cancel()
        organizer?.cancel()
        organizer = nil
        phase = .idle
        endProgress(success: false)
        notice = "Sync stopped."
    }

    // MARK: Progress bar

    /// Moves the bar to at least `value` and lets it drift towards `stepEnd` while the current step runs.
    private func setProgress(_ value: Double, stepEnd: Double) {
        progress = min(1, max(progress, value))
        progressGoal = min(0.99, max(stepEnd, progress))
        if progressTimer == nil {
            progressTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                let gap = self.progressGoal - self.progress
                if gap > 0.0005 { self.progress += gap * 0.025 }
            }
        }
    }

    private func endProgress(success: Bool) {
        progressTimer?.invalidate()
        progressTimer = nil
        progressGoal = 0
        if success {
            progress = 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self = self, !self.isSyncing else { return }
                self.progress = 0
            }
        } else {
            progress = 0
        }
    }

    /// Scraping takes the first 60% of the bar, split evenly between the pages.
    private func scrapeProgress(_ message: String, done: Int, total: Int) {
        guard isSyncing else { return }
        phase = .working(total > 1 ? "\(message) (\(min(done + 1, total)) of \(total))" : message)
        let share = 0.58 / Double(max(1, total))
        setProgress(0.02 + share * Double(done), stepEnd: 0.02 + share * Double(done + 1))
    }

    private func fail(_ message: String) {
        phase = .failed(message)
        endProgress(success: false)
    }

    func sync(force: Bool = false, automatic: Bool = false) {
        guard !isSyncing else { return }
        lastAttempt = Date()
        notice = ""
        let provider = settings.provider
        guard let key = apiKey(provider), !key.isEmpty else {
            fail("Add your \(provider.companyName) API key under Setup first.")
            return
        }
        let jobs = makeJobs()
        var preWarnings: [String] = []
        if settings.campusEnabled && settings.campusURL.trimmed.isEmpty {
            preWarnings.append("Infinite Campus is on, but its address is empty – add it under Setup.")
        }
        guard !jobs.isEmpty else {
            fail("Turn on Google Classroom or Infinite Campus under Setup first.")
            return
        }
        phase = .working("Opening your school sites…")
        progress = 0
        setProgress(0.01, stepEnd: 0.02)
        let settingsNow = settings
        SchoolScraper.shared.run(
            jobs: jobs,
            settings: settingsNow,
            credentials: campusCredentials,
            progress: { [weak self] text, done, total in self?.scrapeProgress(text, done: done, total: total) },
            completion: { [weak self] report in
                var report = report
                report.warnings.insert(contentsOf: preWarnings, at: 0)
                self?.scrapeFinished(report, key: key, settings: settingsNow, force: force, automatic: automatic)
            }
        )
    }

    private func makeJobs() -> [ScrapeJob] {
        var jobs: [ScrapeJob] = []
        if settings.classroomEnabled {
            let n = max(0, settings.classroomAccount)
            let pages = [
                ("To-do ▸ Assigned (not turned in yet)", "a/not-turned-in/all"),
                ("To-do ▸ Missing", "a/missing/all"),
                ("To-do ▸ Done (turned in)", "a/turned-in/all"),
            ]
            for (label, path) in pages {
                if let url = URL(string: "https://classroom.google.com/u/\(n)/\(path)") {
                    jobs.append(ScrapeJob(kind: .classroom, source: .classroom, label: label, url: url))
                }
            }
            // The home page lists your classes; each class's Stream is then read for announcements with things to do.
            if settings.classroomStreams, let url = URL(string: "https://classroom.google.com/u/\(n)/h") {
                jobs.append(ScrapeJob(kind: .classroomClasses, source: .classroom, label: "Your classes", url: url))
            }
        }
        if settings.campusEnabled, let url = SchoolWeb.normalizedURL(settings.campusURL) {
            jobs.append(ScrapeJob(kind: .campus, source: .campus, label: "Assignments and grade categories", url: url))
        }
        let campusHost = SchoolWeb.normalizedURL(settings.campusURL)?.host
        for page in settings.extraPages {
            if let url = SchoolWeb.normalizedURL(page) {
                jobs.append(ScrapeJob(kind: .page, source: SchoolWeb.source(for: url, campusHost: campusHost), label: "Extra page", url: url))
            }
        }
        return jobs
    }

    private func scrapeFinished(_ report: ScrapeReport, key: String, settings: SchoolSettings, force: Bool, automatic: Bool) {
        needsSignIn = report.signIn
        if automatic {
            for source in report.signIn.keys where !notifiedSignIn.contains(source) {
                Shell.notify(title: "School To-Do", "Sign in to \(source.rawValue) again to keep your list up to date.")
            }
        }
        notifiedSignIn = Set(report.signIn.keys)

        guard isSyncing else { return }   // stopped while the pages were loading
        guard !report.pages.isEmpty else {
            if report.signIn.isEmpty {
                fail("Couldn't read any school pages. " + report.warnings.joined(separator: " "))
            } else {
                fail("Sign in to " + report.signIn.keys.map(\.rawValue).sorted().joined(separator: " and ") + " to sync.")
            }
            return
        }

        let courses = Array(Set(saved.items.map(\.course).filter { !$0.isEmpty })).sorted()
        let payload = SchoolPrompt.render(report.pages)
        let system = SchoolPrompt.system(lookbackDays: settings.doneLookbackDays, knownCourses: courses)
        lastPayload = payload
        let day = String(ISO8601DateFormatter().string(from: Date()).prefix(10))
        let hash = SHA256.hash(data: Data((payload + system + settings.model + day).utf8))
            .map { String(format: "%02x", $0) }.joined()
        if !force && hash == saved.payloadHash && !saved.items.isEmpty {
            saved.lastSync = Date()
            saved.warnings = report.warnings
            persist()
            phase = .idle
            endProgress(success: true)
            notice = "Nothing changed since the last sync."
            return
        }

        let provider = settings.provider
        let name = provider == .claude ? "Claude" : "ChatGPT"
        let pageWord = report.pages.count == 1 ? "page" : "pages"
        phase = .working("\(name) is reading \(report.pages.count) \(pageWord) and sorting your work…")
        // Reading/thinking takes 60–80% of the bar; writing the answer takes the rest.
        setProgress(0.6, stepEnd: 0.8)
        let expected = Double(max(4_000, saved.answerLength, saved.items.count * 380))
        let organizer = AIOrganizer(provider: provider, apiKey: key, model: settings.model, system: system, payload: payload)
        self.organizer = organizer
        organizer.start(progress: { [weak self] chars in
            guard let self = self, self.isSyncing else { return }
            self.phase = .working("\(name) is writing your list… (\(chars.formatted()) characters)")
            let done = 0.8 + 0.18 * min(1, Double(chars) / expected)
            self.setProgress(done, stepEnd: min(0.99, done + 0.04))
        }, completion: { [weak self] result in
            guard let self = self else { return }
            self.organizer = nil
            switch result {
            case .success(let output):
                self.apply(output, report: report, hash: hash)
            case .failure(let error):
                self.fail((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        })
    }

    private func apply(_ output: AIOutput, report: ScrapeReport, hash: String) {
        var items: [SchoolItem] = []
        var used: [String: Int] = [:]
        for raw in output.items {
            var item = SchoolItem(
                id: "",
                title: raw.title.trimmed,
                course: raw.course.trimmed,
                source: SchoolSource(rawValue: raw.source) ?? .other,
                status: SchoolStatus(rawValue: raw.status) ?? .todo,
                due: raw.due.trimmed,
                kind: raw.kind,
                impact: GradeImpact(rawValue: raw.impact) ?? .medium,
                weight: raw.weight.trimmed,
                points: raw.points.trimmed,
                url: raw.url.trimmed,
                notes: raw.notes.trimmed
            )
            guard !item.title.isEmpty else { continue }
            let base = item.itemLinkKey ?? item.datedKey
            let n = (used[base] ?? 0) + 1
            used[base] = n
            item.id = n == 1 ? base : "\(base)#\(n)"
            items.append(item)
        }
        // Keep what we had from sites we couldn't read this time, instead of dropping it.
        let unread = Set(report.signIn.keys)
        if !unread.isEmpty {
            let ids = Set(items.map(\.id))
            items += saved.items.filter { unread.contains($0.source) && !ids.contains($0.id) }
        }

        let oldIDs = Set(saved.items.map(\.id))
        let fresh = items.filter { !oldIDs.contains($0.id) && $0.status != .done }
        saved = SchoolSaved(
            items: items,
            lastSync: Date(),
            warnings: report.warnings + output.warnings,
            payloadHash: hash,
            servedBy: output.servedBy,
            answerLength: output.characters
        )
        persist()
        phase = .idle
        endProgress(success: true)
        notice = "Synced \(items.count) item\(items.count == 1 ? "" : "s")."
        if settings.notifyNewWork && !oldIDs.isEmpty && !fresh.isEmpty {
            let message = fresh.count == 1
                ? "New: \(fresh[0].title) (\(fresh[0].course))"
                : "\(fresh.count) new assignments on your list."
            Shell.notify(title: "School To-Do", message)
        }
    }

    private func persist() {
        DataStore.save(saved, to: Self.listFile)
    }
}
