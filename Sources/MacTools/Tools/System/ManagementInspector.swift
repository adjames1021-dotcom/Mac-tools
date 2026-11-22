import SwiftUI
import AppKit

/// Shows how and by what this Mac is managed, using only checks a standard (non-admin) user can run.
/// Read-only: it reports the management in place, it never changes or removes it.
struct ManagementSection: Identifiable {
    let title: String
    let icon: String
    let text: String
    var id: String { title }
}

enum ManagementInspector {
    /// Filename / label fragments of common MDM, monitoring, filtering and security agents.
    static let knownAgents: [(keyword: String, vendor: String)] = [
        ("jamf", "Jamf Pro (MDM)"), ("kandji", "Kandji (MDM)"), ("mosyle", "Mosyle (MDM)"),
        ("intune", "Microsoft Intune (MDM)"), ("companyportal", "Microsoft Intune Company Portal"),
        ("addigy", "Addigy (MDM)"), ("airwatch", "VMware Workspace ONE (MDM)"), ("workspace one", "VMware Workspace ONE (MDM)"),
        ("jumpcloud", "JumpCloud (MDM / directory)"), ("hexnode", "Hexnode (MDM)"), ("filewave", "FileWave (MDM)"),
        ("meraki", "Cisco Meraki Systems Manager"), ("simplemdm", "SimpleMDM"), ("munki", "Munki (software deployment)"),
        ("osquery", "osquery (inventory / monitoring)"), ("fleetdm", "Fleet (osquery monitoring)"), ("/opt/orbit", "Fleet Orbit agent"),
        ("tanium", "Tanium (endpoint management)"), ("com.absolute", "Absolute (device tracking)"),
        ("crowdstrike", "CrowdStrike Falcon (security)"), ("falcon", "CrowdStrike Falcon (security)"),
        ("sentinel", "SentinelOne (security)"), ("sophos", "Sophos (security)"), ("defender", "Microsoft Defender (security)"),
        ("carbonblack", "Carbon Black (security)"), ("cylance", "Cylance (security)"), ("malwarebytes", "Malwarebytes"),
        ("zscaler", "Zscaler (web filtering / proxy)"), ("umbrella", "Cisco Umbrella (DNS filtering)"),
        ("netskope", "Netskope (web filtering)"), ("forcepoint", "Forcepoint (web filtering)"),
        ("globalprotect", "Palo Alto GlobalProtect (VPN)"), ("lightspeed", "Lightspeed Systems (school filter / monitoring)"),
        ("goguardian", "GoGuardian (school monitoring)"), ("securly", "Securly (school filter)"),
        ("linewize", "Linewize (school filter)"),
        ("hapara", "Hapara (school monitoring)"), ("impero", "Impero (classroom monitoring)"),
        ("apple classroom", "Apple Classroom"), ("teramind", "Teramind (activity monitoring)"),
        ("activtrak", "ActivTrak (activity monitoring)"), ("hubstaff", "Hubstaff (time tracking)"),
    ]

    /// Vendors whose keyword appears in any of the given names (app names, launchd labels, folders, processes).
    static func matchAgents(in names: [String]) -> [String: [String]] {
        var found: [String: [String]] = [:]
        for name in names {
            let lower = name.lowercased()
            for (keyword, vendor) in knownAgents where lower.contains(keyword) {
                if !(found[vendor]?.contains(name) ?? false) { found[vendor, default: []].append(name) }
            }
        }
        return found
    }

    static func selfCheck() {
        let hits = matchAgents(in: ["com.jamf.management.daemon.plist", "Safari.app", "com.crowdstrike.falcond", "com.jamf.management.daemon.plist"])
        assert(hits["Jamf Pro (MDM)"] == ["com.jamf.management.daemon.plist"], "duplicate or missing Jamf match")
        assert(hits["CrowdStrike Falcon (security)"]?.count == 1)
        assert(hits.count == 2, "Safari must not match")
    }

    /// Chrome extension install locations 7 (policy download) and 9 (policy) mean an admin force-installed it.
    static func policyExtensions(_ settings: [String: Any]) -> [String] {
        settings.compactMap { id, value in
            guard let v = value as? [String: Any], let loc = v["location"] as? Int, loc == 7 || loc == 9 else { return nil }
            let name = (v["manifest"] as? [String: Any])?["name"] as? String ?? ""
            return name.isEmpty || name.hasPrefix("__MSG_") ? id : "\(name) (\(id))"
        }.sorted()
    }

    /// Restrictions read from Managed Preferences: `allow…` keys set to false, and `disable…`/`force…` keys set to true.
    static func restrictions(_ managed: [String: [String: Any]]) -> [String] {
        var out: [String] = []
        for (domain, dict) in managed {
            for (key, value) in dict {
                let k = key.lowercased()
                if k.hasPrefix("allow"), (value as? Bool) == false { out.append("BLOCKED   \(key)  (\(domain))") }
                if k.hasPrefix("disable") || k.hasPrefix("force"), (value as? Bool) == true { out.append("ENFORCED  \(key)  (\(domain))") }
                if ["disabledpreferencepanes", "hiddenpreferencepanes", "disabledsystemsettings", "pathblacklist", "pathwhitelist",
                    "mount-controls", "urlblocklist", "urlblacklist", "extensioninstallforcelist", "enforcedsoftwareupdatedelay"].contains(k) {
                    out.append("LIMITED   \(key) = \(String(describing: value).replacingOccurrences(of: "\n", with: " ").prefix(160))  (\(domain))")
                }
            }
        }
        return out.sorted()
    }

    static func selfCheckChrome() {
        let ext = policyExtensions(["a": ["location": 7, "manifest": ["name": "Filter"]], "b": ["location": 1], "c": ["location": 9]])
        assert(ext == ["Filter (a)", "c"], "policy extension parsing")
        let r = restrictions(["com.apple.applicationaccess": ["allowCamera": false, "allowAirDrop": true], "x": ["forceSafeSearch": true]])
        assert(r.count == 2 && r[0].hasPrefix("BLOCKED   allowCamera") && r[1].hasPrefix("ENFORCED"), "restriction parsing")
    }

    private static func json(_ path: String) -> [String: Any] {
        guard let data = FileManager.default.contents(atPath: path) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    static func chromeSection() -> String {
        var lines: [String] = []
        let fm = FileManager.default
        // Machine-wide policy pushed by MDM
        let policyPath = "/Library/Managed Preferences/com.google.Chrome.plist"
        if let policy = NSDictionary(contentsOfFile: policyPath) as? [String: Any] {
            lines.append("Machine policy (from MDM): \(policy.count) Chrome policies in force")
            for key in policy.keys.sorted() {
                let value = key.lowercased().contains("token") ? "(present, hidden)"
                    : String(describing: policy[key]!).replacingOccurrences(of: "\n", with: " ").prefix(200).description
                lines.append("  \(key) = \(value)")
            }
        } else {
            lines.append("Machine policy (from MDM): none")
        }
        for dir in ["/Library/Application Support/Google/Chrome Cloud Enrollment", NSHomeDirectory() + "/Library/Application Support/Google/Chrome Cloud Enrollment"] {
            if fm.fileExists(atPath: dir) { lines.append("Chrome Browser Cloud Management enrollment found: \(dir) (managed from the Google Admin console)") }
        }
        // Each profile: signed-in account, whether its organisation manages it, cloud policy and forced extensions
        let root = NSHomeDirectory() + "/Library/Application Support/Google/Chrome"
        let cache = ((json(root + "/Local State")["profile"] as? [String: Any])?["info_cache"] as? [String: Any]) ?? [:]
        if cache.isEmpty { lines.append("\nNo Chrome profiles found for this user.") }
        for dir in cache.keys.sorted() {
            let info = cache[dir] as? [String: Any] ?? [:]
            let user = info["user_name"] as? String ?? ""
            let domain = info["hosted_domain"] as? String ?? ""
            let managed = (info["is_managed"] as? Int ?? 0) != 0 || (info["is_managed"] as? Bool ?? false)
            let label = info["enterprise_label"] as? String ?? ""
            lines.append("\n── \(info["name"] as? String ?? dir)  [\(dir)]")
            lines.append("  Signed in as:  \(user.isEmpty ? "not signed in" : user)")
            if !domain.isEmpty && domain != "NO_HOSTED_DOMAIN" { lines.append("  Organisation:  \(domain) (Google Workspace account – its admin can push policies to this profile)") }
            lines.append("  Managed:       \(managed ? "YES" : "no")\(label.isEmpty ? "" : " – \(label)")")
            if fm.fileExists(atPath: "\(root)/\(dir)/Policy/User Policy") { lines.append("  Cloud user policy: downloaded from the Google Admin console (Policy/User Policy)") }
            var settings: [String: Any] = [:]
            for file in ["Preferences", "Secure Preferences"] {
                let ext = (json("\(root)/\(dir)/\(file)")["extensions"] as? [String: Any])?["settings"] as? [String: Any] ?? [:]
                settings.merge(ext) { a, _ in a }
            }
            let forced = policyExtensions(settings)
            lines.append("  Extensions:    \(settings.count) total, \(forced.count) installed by policy" + (forced.isEmpty ? "" : ":"))
            lines += forced.map { "    • \($0)" }
        }
        lines.append("\nTip: open chrome://policy and chrome://management in Chrome to see every policy and where it came from.")
        lines.append("Note: Google's own Docs/Sheets/Slides/Drive apps can show as policy-installed on some Macs.")
        return lines.joined(separator: "\n")
    }

    private static func run(_ path: String, _ args: [String]) -> String {
        let r = Shell.runSync(path, args)
        let text = r.combined
        return text.isEmpty ? "(nothing reported)" : text
    }

    private static func list(_ folder: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
    }

    static func gather() -> [ManagementSection] {
        #if DEBUG
        selfCheck(); selfCheckChrome()
        #endif
        var sections: [ManagementSection] = []

        // 1. Enrollment and directory binding
        let enrollText = run("/usr/bin/profiles", ["status", "-type", "enrollment"])
        let dep = enrollText.contains("Enrolled via DEP: Yes")
        let isAdmin = Shell.runSync("/usr/bin/id", ["-Gn"]).output.split(whereSeparator: \.isWhitespace).contains("admin")
        var enroll = enrollText
        let ad = Shell.runSync("/usr/sbin/dsconfigad", ["-show"]).combined
        enroll += "\n\nActive Directory binding:\n" + (ad.isEmpty ? "Not bound to a directory" : ad)
        if FileManager.default.fileExists(atPath: "/Library/Preferences/com.apple.mdmclient.plist") {
            enroll += "\n\nMDM client settings: /Library/Preferences/com.apple.mdmclient.plist is present"
        }
        sections.append(.init(title: "Enrollment (MDM / Apple School & Business Manager)", icon: "building.columns", text: enroll))

        // 2. Management, monitoring and security agents
        var names: [String] = []
        for folder in ["/Applications", "/Library/LaunchDaemons", "/Library/LaunchAgents", "/Library/Application Support",
                       "/Library/PrivilegedHelperTools", "/usr/local", "/opt", NSHomeDirectory() + "/Library/LaunchAgents"] {
            names += list(folder).map { folder + "/" + $0 }
        }
        names += Shell.runSync("/bin/ps", ["-axo", "comm="]).output.split(separator: "\n").map { "running: " + String($0) }
        let agents = matchAgents(in: names)
        let agentText = agents.isEmpty
            ? "No known management or monitoring agent found by name. (A custom or renamed agent would not show here; check the profiles and extensions below.)"
            : agents.keys.sorted().map { vendor in "● \(vendor)\n" + agents[vendor]!.map { "    " + $0 }.joined(separator: "\n") }.joined(separator: "\n\n")
        sections.append(.init(title: "Management & monitoring software found", icon: "eye", text: agentText))

        // 3. Configuration profiles with every payload (works without admin, unlike `profiles show`)
        var profiles = Shell.runSync("/usr/sbin/system_profiler", ["SPConfigurationProfileDataType"]).output
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if profiles.isEmpty { profiles = "No configuration profiles installed." }
        sections.append(.init(title: "Configuration profiles & payloads", icon: "doc.badge.gearshape", text: profiles))

        // 4. Settings actually enforced right now (what the profiles push into Managed Preferences)
        let managed = "/Library/Managed Preferences"
        var managedText: [String] = []
        var managedDicts: [String: [String: Any]] = [:]
        if let walker = FileManager.default.enumerator(atPath: managed) {
            for case let rel as String in walker where rel.hasSuffix(".plist") {
                managedText.append("── \(rel)\n" + run("/usr/bin/plutil", ["-p", managed + "/" + rel]))
                managedDicts[String(rel.dropLast(6))] = NSDictionary(contentsOfFile: managed + "/" + rel) as? [String: Any] ?? [:]
            }
        }
        sections.append(.init(title: "Enforced settings (Managed Preferences)", icon: "lock.doc",
                              text: managedText.isEmpty ? "No managed preferences are being enforced." : managedText.joined(separator: "\n\n")))

        // 5. Extensions that can see network traffic, files or processes
        var ext = run("/usr/bin/systemextensionsctl", ["list"])
        let kexts = Shell.runSync("/usr/bin/kmutil", ["showloaded", "--list-only"]).output
            .split(separator: "\n").filter { !$0.contains("com.apple") }.joined(separator: "\n")
        ext += "\n\nThird-party kernel extensions loaded:\n" + (kexts.isEmpty ? "(none)" : kexts)
        sections.append(.init(title: "System & kernel extensions", icon: "puzzlepiece.extension", text: ext))

        // 6. Network control: proxy, VPN, DNS
        let net = "Proxy settings:\n" + run("/usr/sbin/scutil", ["--proxy"])
            + "\n\nVPN / network services:\n" + run("/usr/sbin/scutil", ["--nc", "list"])
            + "\n\nDNS servers:\n" + Shell.runSync("/usr/sbin/scutil", ["--dns"]).output
                .split(separator: "\n").filter { $0.contains("nameserver") || $0.contains("domain") }
                .map { $0.trimmingCharacters(in: .whitespaces) }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
                .joined(separator: "\n")
        sections.append(.init(title: "Network control (proxy, VPN, DNS)", icon: "network.badge.shield.half.filled", text: net))

        // 7. Extra root certificates – these allow HTTPS inspection by a filter
        let certs = Shell.runSync("/usr/bin/security", ["find-certificate", "-a", "/Library/Keychains/System.keychain"]).output
            .split(separator: "\n").filter { $0.contains("\"labl\"") }
            .map { $0.replacingOccurrences(of: "\"labl\"<blob>=", with: "").trimmingCharacters(in: CharacterSet(charactersIn: " \"")) }
            .filter { !$0.hasPrefix("com.apple.") && !$0.hasPrefix("Apple ") }
        sections.append(.init(title: "Certificates added to the System keychain", icon: "checkmark.seal",
                              text: certs.isEmpty ? "No extra certificates. (A web filter that inspects HTTPS normally installs one here.)"
                                                  : certs.joined(separator: "\n") + "\n\nA certificate from a filter or your organisation lets it read HTTPS traffic in browsers that trust it."))

        // 8. Security baseline
        let baseline = [
            "SIP:        " + run("/usr/bin/csrutil", ["status"]),
            "Gatekeeper: " + run("/usr/sbin/spctl", ["--status"]),
            "FileVault:  " + run("/usr/bin/fdesetup", ["status"]),
            "Firewall:   " + run("/usr/libexec/ApplicationFirewall/socketfilterfw", ["--getglobalstate"]),
            "Admins:     " + run("/usr/bin/dscl", [".", "-read", "/Groups/admin", "GroupMembership"]).replacingOccurrences(of: "GroupMembership: ", with: ""),
            "You:        " + NSUserName() + (isAdmin ? " (administrator)" : " (standard user)"),
        ].joined(separator: "\n")
        sections.append(.init(title: "Security & accounts", icon: "shield.lefthalf.filled", text: baseline))

        // 9. What you can and can't do – harmless checks only (nothing is written, installed or changed)
        let fm = FileManager.default
        func can(_ ok: Bool, _ what: String) -> String { (ok ? "✅ CAN     " : "⛔ CAN'T   ") + what }
        let issuer = Shell.runSync("/usr/bin/curl", ["-sv", "--max-time", "8", "-o", "/dev/null", "https://www.google.com"]).error
            .split(separator: "\n").first { $0.contains("issuer:") }.map { $0.components(separatedBy: "issuer:").last!.trimmingCharacters(in: .whitespaces) } ?? ""
        let intercepted = !issuer.isEmpty && !issuer.contains("Google Trust Services")
        let blocked = restrictions(managedDicts)
        var probes = [
            can(isAdmin, "Use an administrator account (install system software, change security settings)"),
            can(fm.isWritableFile(atPath: "/Applications"), "Install apps by dragging them into /Applications"),
            can(fm.isWritableFile(atPath: NSHomeDirectory() + "/Applications") || !fm.fileExists(atPath: NSHomeDirectory() + "/Applications"), "Keep apps in your own ~/Applications folder"),
            can(fm.isWritableFile(atPath: "/Library/LaunchDaemons"), "Add system-wide background services without a password"),
            can(Shell.runSync("/usr/sbin/spctl", ["--status"]).combined.contains("disabled"), "Open apps from anywhere (Gatekeeper off)"),
            can(true, "Run apps from a USB stick (this app is running)"),
        ]
        if enrollText.contains("MDM enrollment: Yes") {
            probes.append(can(isAdmin && !dep, "Remove the MDM enrollment yourself (needs admin; impossible when enrolled via DEP)"))
        }
        probes += [
            issuer.isEmpty ? "❔ HTTPS check: couldn't reach google.com (offline, or blocked)"
                : intercepted ? "⚠️ HTTPS to google.com is signed by \"\(issuer)\" – a filter is decrypting your web traffic"
                              : "✅ HTTPS to google.com is not being intercepted (issuer: \(issuer))",
        ]
        probes += blocked.isEmpty ? ["\nNo restrictions found in Managed Preferences."] : ["\nRestrictions set by the organisation:"] + blocked.map { "  " + $0 }
        sections.append(.init(title: "What you can and can't do", icon: "hand.raised", text: probes.joined(separator: "\n")))

        // 10. Chrome
        let chrome = chromeSection()
        sections.append(.init(title: "Chrome profiles & policies", icon: "globe", text: chrome))

        // Verdict: how managed this Mac is, and how it's done
        let mdm = enrollText.contains("MDM enrollment: Yes")
        let hasProfiles = !profiles.hasPrefix("No configuration")
        var how: [String] = []
        if dep { how.append("Enrolled automatically through Apple School/Business Manager (DEP) – the device is tied to the organisation and re-enrolls after an erase") }
        else if mdm { how.append("Enrolled in MDM by installing an enrollment profile" + (enrollText.contains("User Approved") ? " (user approved)" : "")) }
        if !agents.isEmpty { how.append("Software: " + agents.keys.sorted().joined(separator: ", ")) }
        if hasProfiles { how.append("Configuration profiles installed (see below)") }
        if !blocked.isEmpty { how.append("\(blocked.count) restriction(s) enforced through Managed Preferences") }
        if intercepted || !certs.isEmpty { how.append("Web traffic: extra root certificate(s)" + (intercepted ? " and HTTPS interception is active" : "")) }
        if !ad.isEmpty { how.append("Bound to Active Directory") }
        if chrome.contains("Managed:       YES") || chrome.contains("Machine policy (from MDM): ") && !chrome.contains("Machine policy (from MDM): none") { how.append("Chrome is managed (machine policy and/or a managed Google account)") }
        if !isAdmin { how.append("You are a standard user, so system changes need an admin password") }
        let level: String
        switch (dep, mdm, hasProfiles || !agents.isEmpty || !managedDicts.isEmpty) {
        case (true, _, _): level = "Level 3 – Fully managed & supervised"
        case (false, true, _): level = "Level 2 – MDM managed"
        case (false, false, true): level = "Level 1 – Partly managed (profiles or agents, no MDM)"
        default: level = how.isEmpty ? "Level 0 – Not managed" : "Level 0 – Mac not enrolled, but some parts are managed"
        }
        sections.insert(.init(title: "Verdict: \(level)", icon: "checklist",
                              text: how.isEmpty ? "Nothing on this Mac points to an organisation managing it." : how.map { "• " + $0 }.joined(separator: "\n")), at: 0)
        return sections
    }
}

struct ManagementInspectorView: View {
    @State private var sections: [ManagementSection] = []
    @State private var loading = false
    @State private var status = ""

    private var report: String {
        "MacTools management report – \(Host.current().localizedName ?? "") – \(Date())\n\n"
            + sections.map { "==================== \($0.title) ====================\n\($0.text)" }.joined(separator: "\n\n")
    }

    var body: some View {
        ToolPage(tool: .managementInspector) {
            HStack {
                Button(loading ? "Inspecting…" : "Inspect This Mac") { reload() }.disabled(loading)
                if loading { ProgressView().controlSize(.small) }
                Spacer()
                Button("Copy Report") { ClipboardHelper.copy(report) }.disabled(sections.isEmpty)
                Button("Save Report") { save() }.disabled(sections.isEmpty)
            }
            Text("Read-only. Uses only checks a standard user can run, so no password is needed. It shows the management in place; it doesn't change or remove it.")
                .font(.caption).foregroundStyle(.secondary)
            if !status.isEmpty { Text(status).font(.caption).foregroundColor(.accentColor) }
            ForEach(sections) { section in
                Card(title: section.title, icon: section.icon) {
                    OutputBox(text: section.text, minHeight: 40, maxHeight: 320)
                }
            }
        }
        .onAppear { if sections.isEmpty { reload() } }
    }

    private func reload() {
        loading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = ManagementInspector.gather()
            DispatchQueue.main.async { sections = result; loading = false }
        }
    }

    private func save() {
        #if LITE
        let dir = Portable.reportsDirectory ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        #else
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        #endif
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = dir.appendingPathComponent("Management-\(stamp).txt")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try report.write(to: url, atomically: true, encoding: .utf8)
            status = "Saved to \(url.path)"
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            status = "Couldn't save: \(error.localizedDescription)"
        }
    }
}
