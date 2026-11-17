import SwiftUI
import AppKit

/// What the item editor sheet is open for.
struct EditTarget: Identifiable {
    let id = UUID()
    /// nil = adding a new item of your own.
    let item: SchoolItem?
}

struct SchoolPlannerView: View {
    @ObservedObject private var planner = SchoolPlanner.shared
    @ObservedObject private var themes = ThemeManager.shared
    @ObservedObject private var christmas = ChristmasManager.shared
    @State private var tab: Tab = .todo
    @State private var search = ""
    @State private var editing: EditTarget?

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

            if tab != .setup {
                listTools
                quarterBanner
            }
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
        .sheet(item: $editing) { target in
            SchoolItemEditor(original: target.item)
                .themedRoot()
        }
    }

    // MARK: Search, add, quarter

    private var listTools: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search assignments", text: $search)
                    .textFieldStyle(.plain)
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
            .frame(maxWidth: 320)
            Button {
                editing = EditTarget(item: nil)
            } label: {
                Label("Add", systemImage: "plus")
            }
            .help("Add your own item to the list")
            if planner.hiddenCount > 0 {
                Button("Show \(planner.hiddenCount) Hidden") { planner.unhideAll() }
                    .help("Bring back everything you hid")
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var quarterBanner: some View {
        let hidden = planner.outsideQuarterCount
        if planner.settings.onlyThisQuarter || hidden > 0 {
            HStack(spacing: 8) {
                Image(systemName: "calendar")
                Text(bannerText(hidden: hidden))
                Spacer()
                if planner.settings.onlyThisQuarter {
                    Button("Show All Quarters") { planner.settings.onlyThisQuarter = false }
                        .buttonStyle(.borderless)
                } else {
                    Button("Only This Quarter") { planner.settings.onlyThisQuarter = true }
                        .buttonStyle(.borderless)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func bannerText(hidden: Int) -> String {
        let extra = hidden > 0 ? " · \(hidden) older or later item\(hidden == 1 ? "" : "s") hidden" : ""
        if !planner.settings.onlyThisQuarter { return "Showing every quarter" + extra }
        if let quarter = planner.quarter { return "Showing \(quarter.label)" + extra }
        return "Showing the last 6 weeks and everything ahead – this quarter's dates come from Infinite Campus, or set them under Setup" + extra
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
        let items = planner.items(status, matching: search)
        if status != .done && !items.isEmpty {
            HStack(spacing: 8) {
                Text("In each class:").font(.callout).foregroundStyle(.secondary)
                Picker("", selection: $planner.settings.sortByWeight) {
                    Text("Counts most first").tag(true)
                    Text("Due soonest first").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 300)
                Spacer()
            }
        }
        if items.isEmpty && !search.trimmed.isEmpty {
            Text("Nothing matches “\(search.trimmed)”.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 30)
        } else if items.isEmpty {
            emptyState(status)
        } else {
            ForEach(sections(items, status)) { section in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle()
                            .fill(themes.color(for: section.title))
                            .frame(width: 12, height: 12)
                        Text(section.title).font(.title3.bold())
                        if !section.subtitle.isEmpty {
                            Text(section.subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(section.items.count)").font(.callout).foregroundStyle(.secondary)
                    }
                    .padding(.top, 8)
                    ForEach(section.items) { item in
                        SchoolItemRow(item: item, status: status) { editing = EditTarget(item: $0) }
                    }
                }
            }
        }
    }

    /// One section per class, classes in alphabetical order. Items keep the list's order inside each class.
    private func sections(_ items: [SchoolItem], _ status: SchoolStatus) -> [ListSection] {
        let byClass = Dictionary(grouping: items) { $0.course.trimmed.isEmpty ? "Other" : $0.course.trimmed }
        return byClass.keys
            .sorted { a, b in
                if (a == "Other") != (b == "Other") { return b == "Other" }   // "Other" goes last
                return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
            }
            .map { (course: String) -> ListSection in
                let group = byClass[course] ?? []
                var subtitle = ""
                if status == .todo, let next = group.compactMap(\.dueDate).min() {
                    subtitle = "next " + SchoolDates.describe(next: next).lowercased()
                }
                return ListSection(id: "class:\(course)", title: course, subtitle: subtitle, items: group)
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
        case .mine:
            break   // items you added yourself don't come from a website
        }
    }
}

// MARK: - Rows

struct SchoolItemRow: View {
    let item: SchoolItem
    let status: SchoolStatus
    let onEdit: (SchoolItem) -> Void
    @ObservedObject private var planner = SchoolPlanner.shared
    @ObservedObject private var themes = ThemeManager.shared
    @ObservedObject private var christmas = ChristmasManager.shared
    @State private var hovering = false

    private var dueColor: Color {
        if status == .missing { return .red }
        if status == .todo, let due = item.dueDate {
            let cal = Calendar.current
            if cal.isDateInToday(due) || cal.isDateInTomorrow(due) { return .orange }
        }
        return .secondary
    }

    private var compact: Bool { planner.settings.compactRows }

    var body: some View {
        let checked = planner.isChecked(item)
        let doneAtSchool = item.status == .done && !planner.isEdited(item)
        let showsDone = checked || item.status == .done
        let ornament = christmas.showOrnaments
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(themes.color(for: item.course))
                .frame(width: 4)
            Button {
                if !checked { Jingle.shared.playIfOn(Jingle.ding) }
                planner.toggleChecked(item)
            } label: {
                Image(systemName: ornament ? (showsDone ? "gift.fill" : "gift") : (showsDone ? "checkmark.circle.fill" : "circle"))
                    .font(compact ? Font.title3 : Font.title2)
                    .foregroundColor(showsDone ? (ornament ? ChristmasManager.red : Color.green) : Color.secondary)
            }
            .buttonStyle(.plain)
            .disabled(doneAtSchool && !checked)
            .help(doneAtSchool ? "Marked done on \(item.source.shortName)"
                  : checked ? "Uncheck" : "Check off – MacTools remembers this, even after syncing")

            VStack(alignment: .leading, spacing: compact ? 2 : 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let link = item.link {
                        Button {
                            NSWorkspace.shared.open(link)
                        } label: {
                            Text(item.title)
                                .font(compact ? Font.callout.weight(.semibold) : Font.headline)
                                .strikethrough(status == .done)
                                .multilineTextAlignment(.leading)
                        }
                        .buttonStyle(.link)
                        .help(link.absoluteString)
                    } else {
                        Text(item.title)
                            .font(compact ? Font.callout.weight(.semibold) : Font.headline)
                            .strikethrough(status == .done)
                    }
                    if planner.isEdited(item) {
                        Text("Edited")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                            .help("You changed this. Edit it again to undo.")
                    }
                }
                HStack(spacing: 12) {
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
                if !item.notes.isEmpty && !compact {
                    Text(item.notes).font(.caption)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 5) {
                ImpactBadge(impact: item.impact, weight: item.weight)
                if !compact {
                    Text(item.source.shortName)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.primary.opacity(0.07)))
                }
            }
            Button {
                onEdit(item)
            } label: {
                Image(systemName: "pencil").font(.title3)
            }
            .buttonStyle(.borderless)
            .opacity(hovering ? 1 : 0.35)
            .help("Edit the due date, title, class and more")
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
        .padding(compact ? 6 : 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(hovering ? 0.08 : 0.04)))
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Edit…") { onEdit(item) }
            Button(checked ? "Uncheck" : "Check Off") { planner.toggleChecked(item) }
                .disabled(doneAtSchool && !checked)
            if let link = item.link {
                Divider()
                Button("Open in Browser") { NSWorkspace.shared.open(link) }
                Button("Open in MacTools Sign-In Browser") { SchoolBrowser.shared.open(link, message: "") }
                Button("Copy Link") { ClipboardHelper.copy(link.absoluteString) }
            }
            Divider()
            if item.source == .mine {
                Button("Delete") { planner.deleteMine(item) }
            } else {
                Button("Hide") { planner.hide(item) }
                if planner.isEdited(item) {
                    Button("Undo My Edits") { planner.undoEdits(item) }
                }
            }
        }
    }
}

// MARK: - Editor

/// Edit a synced item (your changes are kept on top of what the school site says) or add/edit one of your own.
struct SchoolItemEditor: View {
    let original: SchoolItem?
    @ObservedObject private var planner = SchoolPlanner.shared
    @Environment(\.dismiss) private var dismiss

    enum ListChoice: String, CaseIterable, Identifiable {
        case automatic, todo, missing, done
        var id: String { rawValue }
        var title: String {
            switch self {
            case .automatic: return "Automatic"
            case .todo: return "To-Do"
            case .missing: return "Missing"
            case .done: return "Done"
            }
        }
    }

    @State private var title: String
    @State private var course: String
    @State private var hasDue: Bool
    @State private var due: Date
    @State private var hasTime: Bool
    @State private var impact: GradeImpact
    @State private var list: ListChoice
    @State private var notes: String
    @State private var link: String

    private var isMine: Bool { original == nil || original?.source == .mine }

    init(original: SchoolItem?) {
        self.original = original
        let item = original
        _title = State(initialValue: item?.title ?? "")
        _course = State(initialValue: item?.course ?? "")
        let date = item?.dueDate
        _hasDue = State(initialValue: original == nil || date != nil)
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        _due = State(initialValue: date ?? Calendar.current.date(bySettingHour: 23, minute: 59, second: 0, of: tomorrow) ?? tomorrow)
        _hasTime = State(initialValue: item?.dueHasTime ?? false)
        _impact = State(initialValue: item?.impact ?? .medium)
        var choice = ListChoice.automatic
        if let item = item {
            if item.source == .mine {
                choice = ListChoice(rawValue: item.status.rawValue) ?? .todo
            } else if let status = SchoolPlanner.shared.edit(for: item)?.status {
                choice = ListChoice(rawValue: status.rawValue) ?? .automatic
            }
        } else {
            choice = .todo
        }
        _list = State(initialValue: choice)
        _notes = State(initialValue: item?.notes ?? "")
        _link = State(initialValue: item?.url ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(original == nil ? "Add to Your List" : "Edit")
                .font(.title2.bold())
                .padding([.top, .horizontal], 20)
            Form {
                TextField("Title", text: $title)
                HStack {
                    TextField("Class", text: $course)
                    Menu {
                        ForEach(planner.courseNames, id: \.self) { name in
                            Button(name) { course = name }
                        }
                    } label: {
                        Image(systemName: "list.bullet")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .disabled(planner.courseNames.isEmpty)
                }
                Toggle("Has a due date", isOn: $hasDue)
                if hasDue {
                    DatePicker("Due", selection: $due, displayedComponents: hasTime ? [.date, .hourAndMinute] : [.date])
                    Toggle("Includes a time", isOn: $hasTime)
                }
                Picker("Counts toward grade", selection: $impact) {
                    ForEach(GradeImpact.allCases) { Text($0.title).tag($0) }
                }
                Picker("List", selection: $list) {
                    ForEach(ListChoice.allCases.filter { !isMine || $0 != .automatic }) { Text($0.title).tag($0) }
                }
                TextField("Notes", text: $notes)
                TextField("Link", text: $link)
            }
            .formStyle(.grouped)
            if !isMine {
                Text("Your changes stay after every sync. The school site itself isn't changed. “Automatic” lets the school site decide the list.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
            }
            HStack {
                if let original = original {
                    if isMine {
                        Button("Delete", role: .destructive) {
                            planner.deleteMine(original)
                            dismiss()
                        }
                    } else if planner.isEdited(original) {
                        Button("Undo My Edits") {
                            planner.undoEdits(original)
                            dismiss()
                        }
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    save()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmed.isEmpty)
            }
            .padding(20)
        }
        .frame(width: 480)
    }

    private func save() {
        let dueText = hasDue ? SchoolDates.format(due, withTime: hasTime) : ""
        let status = SchoolStatus(rawValue: list.rawValue)
        if isMine {
            var item = original ?? SchoolItem(id: "mine:" + UUID().uuidString, title: "", course: "", source: .mine,
                                              status: .todo, due: "", kind: "other", impact: .medium, weight: "",
                                              points: "", url: "", notes: "")
            item.title = title.trimmed
            item.course = course.trimmed
            item.due = dueText
            item.impact = impact
            item.status = status ?? .todo
            item.notes = notes.trimmed
            item.url = link.trimmed
            planner.saveMine(item)
            return
        }
        guard let shown = original else { return }
        // Only keep what differs from what the school site says.
        let school = planner.schoolVersion(of: shown) ?? shown
        var edit = SchoolEdit()
        if title.trimmed != school.title { edit.title = title.trimmed }
        if course.trimmed != school.course { edit.course = course.trimmed }
        if dueText != school.due && !(dueText.isEmpty && school.due.isEmpty) {
            edit.due = dueText
        }
        if impact != school.impact { edit.impact = impact }
        edit.status = status
        if notes.trimmed != school.notes { edit.notes = notes.trimmed }
        if link.trimmed != school.url { edit.url = link.trimmed }
        planner.saveEdit(edit, for: shown)
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
            quarterCard
            listCard
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

    private var quarterCard: some View {
        Card(title: "This Quarter", icon: "calendar") {
            Toggle("Only show work due this quarter", isOn: $planner.settings.onlyThisQuarter)
            Picker("Quarter dates", selection: $planner.settings.quarterSource) {
                ForEach(QuarterSource.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.radioGroup)
            .disabled(!planner.settings.onlyThisQuarter)
            if planner.settings.quarterSource == .schedule {
                ForEach($planner.settings.quarters) { $quarter in
                    HStack(spacing: 8) {
                        TextField("Name", text: $quarter.name)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 110)
                        DatePicker("", selection: $quarter.start, displayedComponents: [.date])
                            .labelsHidden()
                        Text("to").foregroundStyle(.secondary)
                        DatePicker("", selection: $quarter.end, displayedComponents: [.date])
                            .labelsHidden()
                        if planner.settings.scheduledQuarter()?.id == quarter.id {
                            Text("Now").font(.caption.bold()).foregroundColor(.accentColor)
                        }
                        Spacer()
                    }
                }
                HStack {
                    Button("Add Quarter") {
                        let last = planner.settings.quarters.map(\.end).max() ?? Date()
                        let start = Calendar.current.date(byAdding: .day, value: 3, to: last) ?? last
                        let end = Calendar.current.date(byAdding: .day, value: 68, to: start) ?? start
                        planner.settings.quarters.append(SchoolQuarterDates(name: "Quarter \(planner.settings.quarters.count + 1)",
                                                                           start: start, end: end))
                    }
                    Button("Reset to 2026–27 Dates") { planner.settings.quarters = SchoolQuarterDates.defaults }
                }
                Text("Work due up to two weeks after a quarter ends still shows, in case a date is a little off.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let term = planner.saved.term, let start = SchoolDates.day(term.start), let end = SchoolDates.day(term.end) {
                Text("Infinite Campus says the current grading period is \(term.name): \(SchoolDates.monthDay(start)) – \(SchoolDates.monthDay(end)).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Infinite Campus hasn't reported a grading period yet – it does on the next sync. Until then your school's quarter dates are used.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var listCard: some View {
        Card(title: "List", icon: "list.bullet.rectangle") {
            Toggle("Compact rows", isOn: $planner.settings.compactRows)
            HStack {
                Toggle("Remind me about work due tomorrow every evening at", isOn: $planner.settings.dailyReminder)
                Picker("", selection: $planner.settings.reminderHour) {
                    ForEach(15..<23, id: \.self) { hour in
                        Text(Self.hourName(hour)).tag(hour)
                    }
                }
                .labelsHidden()
                .frame(width: 100)
                .disabled(!planner.settings.dailyReminder)
            }
            HStack {
                Button("Show \(planner.hiddenCount) Hidden Item\(planner.hiddenCount == 1 ? "" : "s")") { planner.unhideAll() }
                    .disabled(planner.hiddenCount == 0)
                Text("Right-click an item to hide it, edit it, or check it off. Colors and Light or Dark mode are under Themes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private static func hourName(_ hour: Int) -> String {
        let date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) ?? Date()
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
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
