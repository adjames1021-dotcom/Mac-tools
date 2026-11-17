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
    /// Added by hand in MacTools.
    case mine = "Added by you"

    var shortName: String {
        switch self {
        case .classroom: return "Classroom"
        case .campus: return "Campus"
        case .both: return "Classroom + Campus"
        case .other: return "Web"
        case .mine: return "Added by you"
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
    /// The keys of the item as the school site described it, kept when your edits are shown on top
    /// (so check-offs and edits stay attached even after you rename it). Also fixed for items you add.
    var originalKeys: MemoryKeys? = nil
    /// When the work was posted or assigned (YYYY-MM-DD), if a site showed it.
    var posted: String? = nil
    /// Made from a Class Stream announcement ("test Friday") rather than an assignment.
    var fromStream: Bool? = nil
}

/// The keys an item's check-off, edits and hiding are remembered under.
struct MemoryKeys: Codable, Hashable {
    /// The Classroom link to this exact piece of work, when there is one (the most reliable).
    var link: String?
    /// Class + title + original due day.
    var dated: String
    /// Title + original due day (survives a re-spelled class name).
    var titleDate: String
    /// Class + title (survives a moved due date; only trusted when no other item has the same name).
    var courseTitle: String

    var all: [String] { [link, dated, titleDate].compactMap { $0 } }

    /// Keys for an item you added yourself: fixed, so renaming it doesn't lose its check-off.
    static func mine(_ id: String) -> MemoryKeys {
        MemoryKeys(link: nil, dated: "m:" + id, titleDate: "m:" + id, courseTitle: "m:" + id)
    }
}

/// Your changes to a synced item. Nil fields keep what the school site says.
struct SchoolEdit: Codable, Equatable {
    var title: String?
    var course: String?
    var due: String?
    var impact: GradeImpact?
    var status: SchoolStatus?
    var notes: String?
    var url: String?

    var isEmpty: Bool {
        title == nil && course == nil && due == nil && impact == nil && status == nil && notes == nil && url == nil
    }

    func applied(to item: SchoolItem) -> SchoolItem {
        var out = item
        if let title = title { out.title = title }
        if let course = course { out.course = course }
        if let due = due { out.due = due }
        if let impact = impact { out.impact = impact }
        if let status = status { out.status = status }
        if let notes = notes { out.notes = notes }
        if let url = url { out.url = url }
        return out
    }
}

/// Everything you changed by hand: edits, hidden items and items you added. Saved in its own file so syncing never touches it.
struct SchoolChanges: Codable {
    /// Memory key → your edit.
    var edits: [String: SchoolEdit] = [:]
    /// Memory key → when you hid it.
    var hidden: [String: Date] = [:]
    var mine: [SchoolItem] = []

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        edits = (try? c.decodeIfPresent([String: SchoolEdit].self, forKey: .edits)) ?? [:]
        hidden = (try? c.decodeIfPresent([String: Date].self, forKey: .hidden)) ?? [:]
        mine = (try? c.decodeIfPresent([SchoolItem].self, forKey: .mine)) ?? []
    }
}

/// A grading period (e.g. "Q2"), with dates as YYYY-MM-DD.
struct SchoolTerm: Codable, Equatable {
    var name: String
    var start: String
    var end: String
}

extension SchoolItem {
    var postedDate: Date? { posted.flatMap { SchoolDates.day($0) } }

    /// Whether running past the due date makes it missing. Google Classroom does that itself (and so do your own
    /// items); Infinite Campus can't see work handed in on paper, and Stream announcements simply expire.
    var missesWhenLate: Bool {
        fromStream != true && (source == .classroom || source == .both || source == .mine)
    }

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

    /// The keys check-offs, edits and hiding are remembered under, so they survive a moved due date,
    /// a re-spelled class name or a changed link – and your own edits.
    var keys: MemoryKeys {
        originalKeys ?? MemoryKeys(link: itemLinkKey, dated: datedKey, titleDate: titleDateKey, courseTitle: courseTitleKey)
    }

    var memoryKeys: [String] { keys.all }
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

    private static let monthDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f
    }()

    /// The start of a YYYY-MM-DD day.
    static func day(_ text: String) -> Date? {
        let t = text.trimmed
        guard t.count >= 10 else { return nil }
        return dateOnly.date(from: String(t.prefix(10))).map { Calendar.current.startOfDay(for: $0) }
    }

    static func dayString(_ date: Date) -> String { dateOnly.string(from: date) }

    /// The stored form of a due date: "YYYY-MM-DDTHH:MM", or "YYYY-MM-DD" without a time.
    static func format(_ date: Date, withTime includeTime: Bool) -> String {
        includeTime ? withTime.string(from: date) : dateOnly.string(from: date)
    }

    /// "Nov 4"
    static func monthDay(_ date: Date) -> String { monthDayFormatter.string(from: date) }

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

    /// "Due tomorrow", "Due Friday"… for a bare date (used in class headers).
    static func describe(next date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Due today" }
        if cal.isDateInTomorrow(date) { return "Due tomorrow" }
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: cal.startOfDay(for: date)).day ?? 0
        if days > 1 && days < 7 { return "Due " + weekday.string(from: date) }
        return "Due " + shortDate.string(from: date)
    }

    static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: Date())
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

enum CampusSignIn: String, Codable, CaseIterable, Identifiable {
    case google, password

    var id: String { rawValue }

    var title: String {
        switch self {
        case .google: return "With Google (school account)"
        case .password: return "With a username and password"
        }
    }
}

struct SchoolSettings: Codable, Equatable {
    var classroomEnabled = true
    var classroomStreams = true
    var classroomAccount = 0
    var campusEnabled = false
    var campusURL = ""
    var campusSignIn = CampusSignIn.google
    /// The district's sign-in page and Google sign-in link, looked up from `campusURL`.
    var campusSite: CampusSite?
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
    /// Only show work due in the current grading period.
    var onlyThisQuarter = true
    /// Use your own quarter dates instead of the ones from Infinite Campus.
    var quarterManual = false
    var quarterStart: Date?
    var quarterEnd: Date?
    var compactRows = false
    var dailyReminder = false
    var reminderHour = 19

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
        campusSignIn = (try? c.decodeIfPresent(CampusSignIn.self, forKey: .campusSignIn)) ?? d.campusSignIn
        campusSite = try? c.decodeIfPresent(CampusSite.self, forKey: .campusSite)
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
        onlyThisQuarter = try c.decodeIfPresent(Bool.self, forKey: .onlyThisQuarter) ?? d.onlyThisQuarter
        quarterManual = try c.decodeIfPresent(Bool.self, forKey: .quarterManual) ?? d.quarterManual
        quarterStart = try? c.decodeIfPresent(Date.self, forKey: .quarterStart)
        quarterEnd = try? c.decodeIfPresent(Date.self, forKey: .quarterEnd)
        compactRows = try c.decodeIfPresent(Bool.self, forKey: .compactRows) ?? d.compactRows
        dailyReminder = try c.decodeIfPresent(Bool.self, forKey: .dailyReminder) ?? d.dailyReminder
        reminderHour = try c.decodeIfPresent(Int.self, forKey: .reminderHour) ?? d.reminderHour
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
    /// The current grading period, as Infinite Campus reported it.
    var term: SchoolTerm?

    init(items: [SchoolItem] = [], lastSync: Date? = nil, warnings: [String] = [], payloadHash: String = "",
         servedBy: String = "", answerLength: Int = 0, term: SchoolTerm? = nil) {
        self.items = items
        self.lastSync = lastSync
        self.warnings = warnings
        self.payloadHash = payloadHash
        self.servedBy = servedBy
        self.answerLength = answerLength
        self.term = term
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decodeIfPresent([SchoolItem].self, forKey: .items) ?? []
        lastSync = try c.decodeIfPresent(Date.self, forKey: .lastSync)
        warnings = try c.decodeIfPresent([String].self, forKey: .warnings) ?? []
        payloadHash = try c.decodeIfPresent(String.self, forKey: .payloadHash) ?? ""
        servedBy = try c.decodeIfPresent(String.self, forKey: .servedBy) ?? ""
        answerLength = try c.decodeIfPresent(Int.self, forKey: .answerLength) ?? 0
        term = try? c.decodeIfPresent(SchoolTerm.self, forKey: .term)
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
    private static let changesFile = "school-todo-changes.json"
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
    /// Your edits, hidden items and added items.
    @Published private(set) var changes: SchoolChanges
    @Published private(set) var phase: Phase = .idle
    /// 0…1 while syncing, for the progress bar. Eases forward inside each step so it never sits still.
    @Published private(set) var progress: Double = 0
    @Published private(set) var notice = ""
    /// Sources whose sign-in has expired, with what to tell the user.
    @Published private(set) var needsSignIn: [SchoolSource: String] = [:]
    /// The exact text sent to the AI last time (shown under Setup for troubleshooting).
    @Published private(set) var lastPayload = ""
    @Published private(set) var keyStatus: [AIProvider: Bool] = [:]
    @Published private(set) var campusLookup: CampusLookup = .idle

    enum CampusLookup: Equatable {
        case idle
        case looking
        case failed(String)
    }

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
        changes = DataStore.load(SchoolChanges.self, from: Self.changesFile) ?? SchoolChanges()
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
            self?.remindIfDue()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            self?.autoSyncIfDue()
            self?.remindIfDue()
        }
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

    // MARK: Infinite Campus address

    /// The looked-up sign-in details, if they belong to the address currently entered.
    var campusSite: CampusSite? {
        guard let site = settings.campusSite, site.input == settings.campusURL.trimmed else { return nil }
        return site
    }

    /// Works out the district's sign-in page and Google sign-in link from whatever Infinite Campus address was entered.
    func lookUpCampus(force: Bool = false, completion: ((CampusSite?) -> Void)? = nil) {
        if !force, let site = campusSite {
            completion?(site)
            return
        }
        let input = settings.campusURL.trimmed
        guard !input.isEmpty else {
            completion?(nil)
            return
        }
        campusLookup = .looking
        CampusResolver.resolve(input) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let site):
                if self.settings.campusURL.trimmed == input {
                    self.settings.campusSite = site
                    // No Google sign-in on this district's page: it must be a username and password.
                    if site.ssoURL.isEmpty && self.settings.campusSignIn == .google { self.settings.campusSignIn = .password }
                }
                self.campusLookup = .idle
                completion?(site)
            case .failure(let error):
                self.campusLookup = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                completion?(nil)
            }
        }
    }

    // MARK: Quarter

    /// A grading period with real dates.
    struct Quarter: Equatable {
        let name: String
        let start: Date
        let end: Date

        var label: String { "\(name) (\(SchoolDates.monthDay(start)) – \(SchoolDates.monthDay(end)))" }
    }

    /// This quarter: your own dates if you set them, otherwise the grading period Infinite Campus reported.
    var quarter: Quarter? {
        let cal = Calendar.current
        if settings.quarterManual, let start = settings.quarterStart, let end = settings.quarterEnd, start <= end {
            return Quarter(name: "This quarter", start: cal.startOfDay(for: start),
                           end: cal.date(bySettingHour: 23, minute: 59, second: 59, of: end) ?? end)
        }
        guard let term = saved.term, let start = SchoolDates.day(term.start), let endDay = SchoolDates.day(term.end) else { return nil }
        return Quarter(name: term.name, start: start, end: cal.date(bySettingHour: 23, minute: 59, second: 59, of: endDay) ?? endDay)
    }

    /// The quarter the lists are limited to, when "only this quarter" is on.
    var activeQuarter: Quarter? { settings.onlyThisQuarter ? quarter : nil }

    // MARK: Lists

    /// Everything there is: synced items with your edits on top, plus the items you added.
    var allItems: [SchoolItem] {
        saved.items.map { (item: SchoolItem) -> SchoolItem in
            var shown = edit(for: item)?.applied(to: item) ?? item
            shown.originalKeys = item.keys
            return shown
        } + changes.mine
    }

    /// Finds what's remembered for an item (a check-off, edit or hide): by its Classroom link, or by class + title +
    /// due day. Title + due day (for a re-spelled class name) only counts when no other item shares it. Class + title
    /// alone is never used: it made checking off one "Homework" check off next week's "Homework" too.
    private func lookup<Value>(_ store: [String: Value], _ item: SchoolItem) -> Value? {
        let keys = item.keys
        if let link = keys.link, let value = store[link] { return value }
        if let value = store[keys.dated] { return value }
        if (titleCounts[keys.titleDate] ?? 0) <= 1, let value = store[keys.titleDate] { return value }
        return nil
    }

    func edit(for item: SchoolItem) -> SchoolEdit? { item.source == .mine ? nil : lookup(changes.edits, item) }
    func isEdited(_ item: SchoolItem) -> Bool { edit(for: item) != nil }
    func isChecked(_ item: SchoolItem) -> Bool { lookup(checked, item) != nil }
    func isHidden(_ item: SchoolItem) -> Bool { lookup(changes.hidden, item) != nil }

    /// What the item counts as right now: your check-off wins, then a list you picked by hand,
    /// and otherwise unfinished work past its due date is missing.
    func status(of item: SchoolItem, now: Date = Date()) -> SchoolStatus {
        if isChecked(item) { return .done }
        if edit(for: item)?.status != nil { return item.status }
        if item.status == .todo, item.missesWhenLate, let due = item.dueDate, due < now { return .missing }
        return item.status
    }

    /// True when the student checked it off but the school site doesn't show it as done (yet).
    func checkedOnlyByYou(_ item: SchoolItem) -> Bool { item.status != .done && isChecked(item) }

    /// The dates the lists stick to when "only this quarter" is on: the quarter (plus two weeks after it, for work
    /// that's already been handed out), or – until the quarter is known – the last six weeks and everything ahead.
    var window: (start: Date, end: Date?)? {
        guard settings.onlyThisQuarter else { return nil }
        if let quarter = quarter {
            return (quarter.start, quarter.end.addingTimeInterval(14 * 86400))
        }
        return (Calendar.current.startOfDay(for: Date()).addingTimeInterval(-42 * 86400), nil)
    }

    /// Not hidden, not an expired announcement, and inside the quarter (when that's on). Work with no due date is
    /// judged by when it was posted; your own items always show.
    private func isShown(_ item: SchoolItem) -> Bool {
        if isHidden(item) { return false }
        if item.source == .mine { return true }
        let today = Calendar.current.startOfDay(for: Date())
        if item.fromStream == true, item.status != .done, let due = item.dueDate, due < today { return false }
        guard let window = window else { return true }
        if let due = item.dueDate {
            return due >= window.start && (window.end.map { due <= $0 } ?? true)
        }
        if let posted = item.postedDate { return posted >= window.start }
        return true
    }

    func items(_ status: SchoolStatus, matching search: String = "") -> [SchoolItem] {
        let now = Date()
        let query = search.trimmed
        let list = allItems.filter { item in
            guard isShown(item), self.status(of: item, now: now) == status else { return false }
            return query.isEmpty || item.title.localizedCaseInsensitiveContains(query)
                || item.course.localizedCaseInsensitiveContains(query) || item.notes.localizedCaseInsensitiveContains(query)
        }
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

    func count(_ status: SchoolStatus) -> Int { items(status).count }

    var hiddenCount: Int { allItems.filter { isHidden($0) }.count }

    /// Items left out because they're from another quarter, too old, or expired announcements.
    var outsideQuarterCount: Int {
        allItems.filter { !isHidden($0) && !isShown($0) }.count
    }

    /// Class names in use, for the editor's class menu.
    var courseNames: [String] {
        Array(Set(allItems.map { $0.course.trimmed }.filter { !$0.isEmpty }))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
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

    // MARK: Your changes

    /// The item as the school site describes it, without your edits.
    func schoolVersion(of item: SchoolItem) -> SchoolItem? {
        saved.items.first { $0.id == item.id }
    }

    /// Saves your changes to a synced item (an empty edit removes them).
    func saveEdit(_ edit: SchoolEdit, for item: SchoolItem) {
        for key in item.memoryKeys {
            if edit.isEmpty { changes.edits.removeValue(forKey: key) } else { changes.edits[key] = edit }
        }
        saveChanges()
    }

    func undoEdits(_ item: SchoolItem) { saveEdit(SchoolEdit(), for: item) }

    /// Adds or updates an item you made yourself.
    func saveMine(_ item: SchoolItem) {
        var item = item
        item.source = .mine
        if item.originalKeys == nil { item.originalKeys = .mine(item.id) }
        if let index = changes.mine.firstIndex(where: { $0.id == item.id }) {
            changes.mine[index] = item
        } else {
            changes.mine.append(item)
        }
        saveChanges()
    }

    func deleteMine(_ item: SchoolItem) {
        changes.mine.removeAll { $0.id == item.id }
        for key in item.memoryKeys { checked.removeValue(forKey: key) }
        DataStore.save(checked, to: Self.checkedFile)
        saveChanges()
    }

    func hide(_ item: SchoolItem) {
        let now = Date()
        for key in item.memoryKeys { changes.hidden[key] = now }
        saveChanges()
    }

    func unhideAll() {
        changes.hidden = [:]
        saveChanges()
    }

    private func saveChanges() {
        DataStore.save(changes, to: Self.changesFile)
    }

    // MARK: Reminders

    /// Once a day after the chosen hour: a notification about work due tomorrow and anything missing.
    private func remindIfDue() {
        guard settings.dailyReminder else { return }
        let cal = Calendar.current
        let now = Date()
        guard cal.component(.hour, from: now) >= settings.reminderHour else { return }
        let today = SchoolDates.dayString(now)
        guard UserDefaults.standard.string(forKey: "schoolTodoLastReminder") != today else { return }
        UserDefaults.standard.set(today, forKey: "schoolTodoLastReminder")
        let tomorrow = items(.todo).filter { $0.dueDate.map { cal.isDateInTomorrow($0) } ?? false }
        let missing = count(.missing)
        guard !tomorrow.isEmpty || missing > 0 else { return }
        var parts: [String] = []
        if !tomorrow.isEmpty {
            let names = tomorrow.prefix(3).map { $0.course.isEmpty ? $0.title : "\($0.title) (\($0.course))" }.joined(separator: ", ")
            parts.append("Due tomorrow: " + names + (tomorrow.count > 3 ? " and \(tomorrow.count - 3) more" : ""))
        }
        if missing > 0 { parts.append("\(missing) missing") }
        Shell.notify(title: "School To-Do", parts.joined(separator: " · "))
    }

    /// The list as a Markdown checklist, for pasting into notes.
    func markdown() -> String {
        var out = ""
        for status in SchoolStatus.allCases {
            let list = items(status)
            guard !list.isEmpty else { continue }
            out += "## \(status.title)\n"
            let byClass = Dictionary(grouping: list) { $0.course.trimmed.isEmpty ? "Other" : $0.course.trimmed }
            for course in byClass.keys.sorted(by: { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }) {
                out += "\n### \(course)\n"
                for item in byClass[course] ?? [] {
                    let box = status == .done ? "[x]" : "[ ]"
                    let title = item.link.map { "[\(item.title)](\($0.absoluteString))" } ?? item.title
                    var details = [SchoolDates.describe(item)]
                    if !item.weight.isEmpty { details.append(item.weight) }
                    out += "- \(box) \(title) – \(details.joined(separator: " · "))\n"
                }
            }
            out += "\n"
        }
        return out.isEmpty ? "Nothing on the list yet." : out
    }

    private func recountTitles() {
        var counts: [String: Int] = [:]
        for item in saved.items { counts[item.titleDateKey, default: 0] += 1 }
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
        if settings.campusEnabled && !settings.campusURL.trimmed.isEmpty && campusSite == nil {
            phase = .working("Finding your Infinite Campus sign-in page…")
            lookUpCampus { [weak self] site in
                guard let self = self, self.isSyncing else { return }
                if site == nil, case .failed(let message) = self.campusLookup {
                    preWarnings.append("Infinite Campus: \(message)")
                }
                self.startScraping(key: key, force: force, automatic: automatic, warnings: preWarnings)
            }
            return
        }
        startScraping(key: key, force: force, automatic: automatic, warnings: preWarnings)
    }

    private func startScraping(key: String, force: Bool, automatic: Bool, warnings: [String]) {
        let jobs = makeJobs()
        var settingsNow = settings
        settingsNow.campusSite = campusSite   // only if it was looked up for the address entered now
        SchoolScraper.shared.run(
            jobs: jobs,
            settings: settingsNow,
            credentials: campusCredentials,
            progress: { [weak self] text, done, total in self?.scrapeProgress(text, done: done, total: total) },
            completion: { [weak self] report in
                var report = report
                report.warnings.insert(contentsOf: warnings, at: 0)
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
        // Start on the site's (blank) landing page: it's on the right site for reading data, and unlike the
        // sign-in page it doesn't disturb a session that's still signed in.
        if settings.campusEnabled,
           let url = campusSite.flatMap({ URL(string: $0.origin + "/") }) ?? SchoolWeb.normalizedURL(settings.campusURL) {
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
        // The grading period to stick to: your own dates, or the one Infinite Campus just reported.
        var promptQuarter: Quarter?
        if settings.onlyThisQuarter {
            if let term = report.term, !settings.quarterManual, let start = SchoolDates.day(term.start), let end = SchoolDates.day(term.end) {
                promptQuarter = Quarter(name: term.name, start: start, end: end)
            } else {
                promptQuarter = quarter
            }
        }
        let system = SchoolPrompt.system(lookbackDays: settings.doneLookbackDays, knownCourses: courses,
                                         quarter: promptQuarter.map { (name: $0.name, start: $0.start, end: $0.end) })
        lastPayload = payload
        let day = String(ISO8601DateFormatter().string(from: Date()).prefix(10))
        let hash = SHA256.hash(data: Data((payload + system + settings.model + day).utf8))
            .map { String(format: "%02x", $0) }.joined()
        if !force && hash == saved.payloadHash && !saved.items.isEmpty {
            saved.lastSync = Date()
            saved.warnings = report.warnings
            if let term = report.term { saved.term = term }
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
            item.posted = raw.posted.trimmed.isEmpty ? nil : raw.posted.trimmed
            item.fromStream = raw.fromStream
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
            answerLength: output.characters,
            term: report.term ?? saved.term
        )
        persist()
        phase = .idle
        endProgress(success: true)
        Jingle.shared.playIfOn(Jingle.chorus)
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
