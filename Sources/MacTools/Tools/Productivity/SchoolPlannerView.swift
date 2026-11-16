import SwiftUI
import AppKit

struct SchoolPlannerView: View {
    @ObservedObject private var planner = SchoolPlanner.shared
    @State private var tab: Tab = .todo

    enum Tab: String, CaseIterable, Identifiable {
        case todo, missing, done, setup
        var id: String { rawValue }
    }

    var body: some View {
        ToolPage(tool: .schoolPlanner) {
            syncCard
            signInBanners
            if !planner.saved.warnings.isEmpty {
                DisclosureGroup("Notes from the last sync (\(planner.saved.warnings.count))") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(planner.saved.warnings, id: \.self) { warning in
                            Label(warning, systemImage: "info.circle").font(.caption)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            Picker("", selection: $tab) {
                Text("To-Do (\(planner.count(.todo)))").tag(Tab.todo)
                Text("Missing (\(planner.count(.missing)))").tag(Tab.missing)
                Text("Done (\(planner.count(.done)))").tag(Tab.done)
                Text("Setup").tag(Tab.setup)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch tab {
            case .todo: list(.todo)
            case .missing: list(.missing)
            case .done: list(.done)
            case .setup: SchoolSetupView()
            }
        }
        .onAppear {
            if !planner.hasKey(planner.settings.provider) { tab = .setup }
        }
    }

    // MARK: Sync

    private var statusLine: String {
        switch planner.phase {
        case .working(let message): return message
        case .failed: return "The last sync didn't finish."
        case .idle:
            if !planner.notice.isEmpty { return planner.notice }
            return planner.saved.lastSync == nil ? "Not synced yet." : "Up to date."
        }
    }

    private var syncCard: some View {
        Card(title: "Sync", icon: "arrow.triangle.2.circlepath") {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusLine).font(.callout)
                    if let last = planner.saved.lastSync {
                        Text("Last synced \(SchoolDates.relative(last))" + (planner.saved.servedBy.isEmpty ? "" : " · sorted by \(planner.saved.servedBy)"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if planner.isSyncing {
                    Button("Stop") { planner.cancel() }
                } else {
                    Button {
                        planner.sync()
                    } label: {
                        Label("Sync Now", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("r", modifiers: [.command])
                    Menu {
                        Button("Sync and Re-sort Everything") { planner.sync(force: true) }
                        Button("Copy List as Markdown") { ClipboardHelper.copy(planner.markdown()) }
                        Divider()
                        Button("Open Sign-In Browser…") {
                            SchoolBrowser.shared.open(nil, message: "Sign in to your school sites here. MacTools remembers the sign-in.")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
            if planner.isSyncing || planner.progress > 0 {
                ProgressView(value: planner.progress)
                    .progressViewStyle(.linear)
                    .animation(.easeInOut(duration: 0.25), value: planner.progress)
            }
            if case .failed(let message) = planner.phase {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundColor(.orange)
            }
        }
    }

    @ViewBuilder
    private var signInBanners: some View {
        ForEach(planner.needsSignIn.keys.sorted { $0.rawValue < $1.rawValue }, id: \.self) { source in
            HStack(spacing: 10) {
                Image(systemName: "person.crop.circle.badge.exclamationmark")
                    .font(.title2)
                    .foregroundColor(.orange)
                Text(planner.needsSignIn[source] ?? "Sign in to \(source.rawValue).")
                Spacer()
                Button("Sign In…") { SchoolSignIn.open(source) }
                    .buttonStyle(.borderedProminent)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.12)))
        }
    }

    // MARK: Lists

    private struct ListSection: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let items: [SchoolItem]
    }

    @ViewBuilder
    private func list(_ status: SchoolStatus) -> some View {
        let items = planner.items(status)
        if status != .done {
            HStack {
                Picker("", selection: $planner.settings.sortByWeight) {
                    Text("Biggest grade impact first").tag(true)
                    Text("Soonest due first").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 380)
                Spacer()
            }
        }
        if items.isEmpty {
            emptyState(status)
        } else {
            ForEach(sections(items, status)) { section in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(section.title).font(.headline)
                        if !section.subtitle.isEmpty {
                            Text(section.subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(section.items.count)").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)
                    ForEach(section.items) { item in
                        SchoolItemRow(item: item, status: status)
                    }
                }
            }
        }
    }

    private func sections(_ items: [SchoolItem], _ status: SchoolStatus) -> [ListSection] {
        if status == .done {
            return [ListSection(id: "done", title: "Done in the last \(planner.settings.doneLookbackDays) days",
                                subtitle: "Turned in, graded or checked off by you", items: items)]
        }
        if planner.settings.sortByWeight {
            return GradeImpact.allCases.compactMap { impact in
                let group = items.filter { $0.impact == impact }
                return group.isEmpty ? nil : ListSection(id: impact.rawValue, title: impact.title, subtitle: impact.explanation, items: group)
            }
        }
        let now = Date()
        return DueGroup.allCases.compactMap { due in
            let group = items.filter { DueGroup.of($0.dueDate, now: now) == due }
            return group.isEmpty ? nil : ListSection(id: "due\(due.rawValue)", title: due.title, subtitle: "", items: group)
        }
    }

    @ViewBuilder
    private func emptyState(_ status: SchoolStatus) -> some View {
        VStack(spacing: 10) {
            Image(systemName: status == .done ? "tray" : "party.popper")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            if planner.saved.lastSync == nil {
                Text("Your list is empty until the first sync.").font(.headline)
                HStack {
                    Button("Set Up") { tab = .setup }
                    Button("Sync Now") { planner.sync() }
                        .buttonStyle(.borderedProminent)
                        .disabled(planner.isSyncing)
                }
            } else {
                switch status {
                case .todo: Text("Nothing left to do. Nice!").font(.headline)
                case .missing: Text("No missing work.").font(.headline)
                case .done: Text("Nothing finished in the last \(planner.settings.doneLookbackDays) days.").font(.headline)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

extension GradeImpact {
    var explanation: String {
        switch self {
        case .major: return "Tests, big projects and the most heavily weighted categories"
        case .high: return "Essays, projects and high-point work"
        case .medium: return "Quizzes, labs and mid-weight work"
        case .low: return "Homework, classwork and readings"
        case .minimal: return "Practice and completion-only work"
        }
    }
}

/// Opens the sign-in browser at the right page for a site.
enum SchoolSignIn {
    static func open(_ source: SchoolSource) {
        let planner = SchoolPlanner.shared
        switch source {
        case .classroom, .both:
            SchoolBrowser.shared.open(SchoolWeb.classroomHome(account: planner.settings.classroomAccount),
                                      message: "Sign in with your school Google account. When your Classroom To-do page shows, click Done.")
        case .campus:
            // Look up the district's sign-in page first, so a bare address like https://district.infinitecampus.org works.
            planner.lookUpCampus { site in
                let typed = SchoolWeb.normalizedURL(planner.settings.campusURL)
                if planner.settings.campusSignIn == .google, let sso = site.flatMap({ URL(string: $0.ssoURL) }), sso.host != nil {
                    SchoolBrowser.shared.open(sso, message: "Pick or sign in to your school Google account. When your Infinite Campus portal shows, click Done.")
                } else if let login = site.flatMap({ URL(string: $0.loginURL) }) ?? typed {
                    let google = planner.settings.campusSignIn == .google
                    SchoolBrowser.shared.open(login, message: google
                        ? "Click your district's Google sign-in button, sign in with your school account, then click Done."
                        : "Sign in to Infinite Campus. When your portal shows, click Done.")
                }
            }
        case .other:
            SchoolBrowser.shared.open(planner.settings.extraPages.first.flatMap { SchoolWeb.normalizedURL($0) },
                                      message: "Sign in to the page, then click Done.")
        }
    }
}

// MARK: - Rows

struct SchoolItemRow: View {
    let item: SchoolItem
    let status: SchoolStatus
    @ObservedObject private var planner = SchoolPlanner.shared
    @State private var hovering = false

    private var dueColor: Color {
        if status == .missing { return .red }
        if status == .todo, let due = item.dueDate {
            let cal = Calendar.current
            if cal.isDateInToday(due) || cal.isDateInTomorrow(due) { return .orange }
        }
        return .secondary
    }

    var body: some View {
        let checked = planner.isChecked(item)
        let doneAtSchool = item.status == .done
        let showsDone = checked || doneAtSchool
        HStack(alignment: .top, spacing: 10) {
            Button {
                planner.toggleChecked(item)
            } label: {
                Image(systemName: showsDone ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundColor(showsDone ? .green : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(doneAtSchool && !checked)
            .help(doneAtSchool ? "Marked done on \(item.source.shortName)"
                  : checked ? "Uncheck" : "Check off – MacTools remembers this, even after syncing")

            VStack(alignment: .leading, spacing: 4) {
                if let link = item.link {
                    Button {
                        NSWorkspace.shared.open(link)
                    } label: {
                        Text(item.title)
                            .font(.headline)
                            .strikethrough(status == .done)
                            .multilineTextAlignment(.leading)
                    }
                    .buttonStyle(.link)
                    .help(link.absoluteString)
                } else {
                    Text(item.title)
                        .font(.headline)
                        .strikethrough(status == .done)
                }
                HStack(spacing: 12) {
                    Label(item.course.isEmpty ? "No class" : item.course, systemImage: "book.closed")
                    Label(SchoolDates.describe(item), systemImage: "calendar")
                        .foregroundColor(dueColor)
                    if !item.points.isEmpty {
                        Label(item.points, systemImage: "number")
                    }
                    if !item.kind.isEmpty && item.kind != "other" {
                        Text(item.kind.capitalized)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if planner.checkedOnlyByYou(item) {
                    Text("Checked off by you").font(.caption).foregroundColor(.green)
                }
                if !item.notes.isEmpty {
                    Text(item.notes).font(.caption)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 5) {
                ImpactBadge(impact: item.impact, weight: item.weight)
                Text(item.source.shortName)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
            }
            if let link = item.link {
                Button {
                    NSWorkspace.shared.open(link)
                } label: {
                    Image(systemName: "arrow.up.right.square").font(.title3)
                }
                .buttonStyle(.borderless)
                .help("Open in your browser")
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(hovering ? 0.08 : 0.04)))
        .onHover { hovering = $0 }
        .contextMenu {
            if let link = item.link {
                Button("Open in Browser") { NSWorkspace.shared.open(link) }
                Button("Open in MacTools Sign-In Browser") { SchoolBrowser.shared.open(link, message: "") }
                Button("Copy Link") { ClipboardHelper.copy(link.absoluteString) }
                Divider()
            }
            Button(checked ? "Uncheck" : "Check Off") { planner.toggleChecked(item) }
                .disabled(doneAtSchool && !checked)
        }
    }
}

/// Five bars showing how much a piece of work counts, plus the AI's explanation (e.g. "Tests = 40% of grade").
struct ImpactBadge: View {
    let impact: GradeImpact
    let weight: String

    var body: some View {
        HStack(spacing: 5) {
            HStack(spacing: 2) {
                ForEach(1...5, id: \.self) { level in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(level <= impact.rank ? impact.color : Color.primary.opacity(0.12))
                        .frame(width: 5, height: 11)
                }
            }
            Text(weight.isEmpty ? impact.title : weight)
                .font(.caption2)
                .lineLimit(1)
                .foregroundStyle(.secondary)
        }
        .help(impact.title + (weight.isEmpty ? "" : " – \(weight)"))
    }
}

// MARK: - Setup

struct SchoolSetupView: View {
    @ObservedObject private var planner = SchoolPlanner.shared
    @State private var keyText = ""
    @State private var keyMessage = ""
    @State private var campusUser = ""
    @State private var campusPassword = ""
    @State private var campusMessage = ""
    @State private var newPage = ""
    @State private var confirmSignOut = false
    @State private var confirmForget = false

    private var provider: AIProvider { planner.settings.provider }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            aiCard
            classroomCard
            campusCard
            extraPagesCard
            syncingCard
            if !planner.lastPayload.isEmpty {
                Card(title: "Last Data Sent to the AI", icon: "doc.text.magnifyingglass") {
                    DisclosureGroup("Show what was read from your school sites") {
                        OutputBox(text: planner.lastPayload, minHeight: 200, maxHeight: 420)
                        CopyButton(text: planner.lastPayload)
                    }
                }
            }
        }
        .onAppear {
            if planner.settings.rememberCampusLogin { campusUser = planner.campusUsername }
        }
        .onChange(of: planner.settings.provider) { _ in
            keyText = ""
            keyMessage = ""
        }
        .onChange(of: planner.settings.rememberCampusLogin) { on in
            if !on {
                planner.forgetCampusLogin()
                campusUser = ""
                campusPassword = ""
                campusMessage = "Saved login removed."
            }
        }
        .confirmationDialog("Sign out of Google Classroom, Infinite Campus and every other site in the MacTools browser?",
                            isPresented: $confirmSignOut) {
            Button("Sign Out", role: .destructive) {
                SchoolWeb.signOutEverywhere { campusMessage = "Signed out of all school sites." }
            }
        }
        .confirmationDialog("Forget everything you've checked off?", isPresented: $confirmForget) {
            Button("Forget Check-offs", role: .destructive) { planner.clearCheckOffs() }
        }
    }

    private var aiCard: some View {
        Card(title: "AI That Organizes Your List", icon: "sparkles") {
            Picker("Use", selection: $planner.settings.provider) {
                ForEach(AIProvider.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 420)

            HStack {
                SecureField(planner.hasKey(provider) ? "Saved – paste a new key to replace it" : "\(provider.companyName) API key (\(provider.keyPlaceholder))",
                            text: $keyText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 380)
                    .onSubmit(saveKey)
                Button("Save Key", action: saveKey)
                    .disabled(keyText.trimmed.isEmpty)
                if planner.hasKey(provider) {
                    Button("Remove") {
                        planner.setAPIKey("", for: provider)
                        keyMessage = "Key removed."
                    }
                }
                Link("Get a key", destination: provider.keyPage)
            }
            HStack(spacing: 6) {
                Image(systemName: planner.hasKey(provider) ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .foregroundColor(planner.hasKey(provider) ? .green : .orange)
                Text(keyMessage.isEmpty ? (planner.hasKey(provider) ? "Key saved in your Mac's keychain." : "No key yet.") : keyMessage)
            }
            .font(.caption)

            switch provider {
            case .claude:
                Picker("Model", selection: $planner.settings.claudeModel) {
                    ForEach(SchoolModels.claude) { model in Text(model.name).tag(model.id) }
                }
                .frame(maxWidth: 420)
            case .openAI:
                HStack {
                    Text("Model")
                    TextField(SchoolModels.openAIDefault, text: $planner.settings.openAIModel)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                    Button("Default") { planner.settings.openAIModel = SchoolModels.openAIDefault }
                }
                Text("Any OpenAI chat model that supports structured output. The default is \(SchoolModels.openAIDefault).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("Each sync sends the text of your school pages to \(provider.companyName) to sort into your list, and uses your API credit. Syncs that find nothing new are skipped for free.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func saveKey() {
        let value = keyText.trimmed
        guard !value.isEmpty else { return }
        if planner.setAPIKey(value, for: provider) {
            keyText = ""
            keyMessage = "Key saved in your Mac's keychain."
        } else {
            keyMessage = "The keychain refused to save the key."
        }
    }

    private var classroomCard: some View {
        Card(title: "Google Classroom", icon: "graduationcap") {
            Toggle("Read my Google Classroom To-do list (assigned, missing and done)", isOn: $planner.settings.classroomEnabled)
            Toggle("Also read each class's Stream for announcements that need doing", isOn: $planner.settings.classroomStreams)
                .disabled(!planner.settings.classroomEnabled)
            HStack {
                Stepper("Google account: \(planner.settings.classroomAccount)", value: $planner.settings.classroomAccount, in: 0...9)
                Text("0 is the first account you signed in with. Change it if Classroom opens the wrong account.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!planner.settings.classroomEnabled)
            HStack {
                Button("Sign In to Google…") { SchoolSignIn.open(.classroom) }
                Text("You only need to do this once – the sign-in is remembered.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var campusHost: String {
        SchoolWeb.normalizedURL(planner.settings.campusURL)?.host ?? "your Infinite Campus site"
    }

    private var campusCard: some View {
        Card(title: "Infinite Campus", icon: "building.columns") {
            Toggle("Read my Infinite Campus assignments and grade categories", isOn: $planner.settings.campusEnabled)
            HStack {
                TextField("https://yourdistrict.infinitecampus.org", text: $planner.settings.campusURL)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { planner.lookUpCampus(force: true) }
                Button("Check") { planner.lookUpCampus(force: true) }
                    .disabled(SchoolWeb.normalizedURL(planner.settings.campusURL) == nil || planner.campusLookup == .looking)
            }
            campusStatus
            Picker("Sign in", selection: $planner.settings.campusSignIn) {
                ForEach(CampusSignIn.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.radioGroup)
            HStack {
                Button("Sign In to Infinite Campus…") { SchoolSignIn.open(.campus) }
                    .disabled(SchoolWeb.normalizedURL(planner.settings.campusURL) == nil)
                Spacer()
            }
            switch planner.settings.campusSignIn {
            case .google:
                Text("Sign in once with your school Google account. Infinite Campus signs you out whenever MacTools quits, so each sync quietly signs you back in through Google – no typing needed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .password:
                Toggle("Remember my username and password, and sign me in automatically", isOn: $planner.settings.rememberCampusLogin)
                if planner.settings.rememberCampusLogin {
                    HStack {
                        TextField("Username", text: $campusUser)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 180)
                        SecureField("Password", text: $campusPassword)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 180)
                        Button("Save Login") {
                            if planner.setCampusLogin(username: campusUser, password: campusPassword) {
                                campusPassword = ""
                                campusMessage = "Saved in your Mac's keychain."
                            } else {
                                campusMessage = "The keychain refused to save the login."
                            }
                        }
                        .disabled(campusUser.trimmed.isEmpty || campusPassword.isEmpty)
                    }
                    Text("Only typed into \(campusHost), and only when it asks you to sign in.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if !campusMessage.isEmpty {
                Text(campusMessage).font(.caption).foregroundColor(.green)
            }
        }
    }

    @ViewBuilder
    private var campusStatus: some View {
        switch planner.campusLookup {
        case .looking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Finding your district's sign-in page…")
            }
            .font(.caption)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundColor(.orange)
        case .idle:
            if let site = planner.campusSite {
                Label("Found \(site.appName): \(site.loginURL)" + (site.ssoURL.isEmpty ? " (no Google sign-in on this page)" : " · Google sign-in available"),
                      systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundColor(.green)
                    .lineLimit(2)
            } else {
                Text("Paste any Infinite Campus address – just the site (like https://yourdistrict.infinitecampus.org) is enough.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var extraPagesCard: some View {
        Card(title: "Extra Pages", icon: "doc.badge.plus") {
            Text("Any other school page to read on every sync. Tip: open it in the sign-in browser and click “Sync This Page Too”.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(planner.settings.extraPages, id: \.self) { page in
                HStack {
                    Text(page).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Spacer()
                    Button {
                        planner.removeExtraPage(page)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Stop reading this page")
                }
                .font(.callout)
            }
            HStack {
                TextField("https://…", text: $newPage)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addPage)
                Button("Add", action: addPage)
                    .disabled(SchoolWeb.normalizedURL(newPage) == nil)
            }
        }
    }

    private func addPage() {
        guard let url = SchoolWeb.normalizedURL(newPage) else { return }
        planner.addExtraPage(url)
        newPage = ""
    }

    private var syncingCard: some View {
        Card(title: "Syncing", icon: "clock.arrow.circlepath") {
            Picker("Sync automatically", selection: $planner.settings.autoSyncHours) {
                Text("Off").tag(0)
                Text("Every hour").tag(1)
                Text("Every 2 hours").tag(2)
                Text("Every 4 hours").tag(4)
                Text("Every 8 hours").tag(8)
                Text("Once a day").tag(24)
            }
            .frame(maxWidth: 320)
            Text("Runs in the background while MacTools is open (it keeps running in the menu bar).")
                .font(.caption)
                .foregroundStyle(.secondary)
            Stepper("Keep done work for \(planner.settings.doneLookbackDays) days", value: $planner.settings.doneLookbackDays, in: 1...90)
            Toggle("Notify me about new assignments", isOn: $planner.settings.notifyNewWork)
            Toggle("Show the browser while syncing", isOn: $planner.settings.showBrowserWhileSyncing)
            HStack {
                Button("Forget My Check-offs…") { confirmForget = true }
                Button("Sign Out of All School Sites…") { confirmSignOut = true }
            }
        }
    }
}
