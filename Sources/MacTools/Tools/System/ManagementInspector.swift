import SwiftUI
import AppKit

/// Shows how and by what this Mac is managed, using only checks a standard (non-admin) user can run.
/// Read-only: it reports the management in place, it never changes or removes it.
struct ManagementSection: Identifiable {
    let title: String
    let icon: String
    let text: String
    var simple = false
    var id: String { title }
}

/// What the plain-English summary is built from.
struct ManagementFacts {
    var dep = false, mdm = false, profiles = false, adBound = false, isAdmin = true
    var intercepted = false, extraCerts = 0
    var vendors: [String] = []
    var restrictions: [(key: String, value: Any)] = []
    var chromeOrgs: [String] = [], chromeForced = 0, chromeMachinePolicy = false
    var servers: [String] = [], profileOrgs: [String] = []
    var mdmRights: [String]? = nil                    // nil when the MDM's AccessRights couldn't be read
    var privacy: [String] = [], escrow = false, webFilter = false
    var screenSharing = false, ssh = false, liveSessions: [String] = [], remoteTools: [String] = []
    var hiddenAdmins: [String] = [], networkAccount = false, managedAppleID = false, loginMessage = ""
    var managedBrowsers: [String] = []
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
        ("veriato", "Veriato (activity monitoring)"), ("interguard", "InterGuard (activity monitoring)"),
        ("netsupport", "NetSupport (classroom monitoring)"), ("lanschool", "LanSchool (classroom monitoring)"),
        ("dyknow", "Dyknow (classroom monitoring)"),
        ("blocksi", "Blocksi (school filter)"), ("smoothwall", "Smoothwall (school filter)"), ("iboss", "iboss (web filtering)"),
        ("contentkeeper", "ContentKeeper (web filtering)"), ("cloudflare warp", "Cloudflare WARP / Zero Trust (web filtering)"),
        ("forticlient", "FortiClient (VPN / web filtering)"), ("anyconnect", "Cisco Secure Client / AnyConnect (VPN)"),
        ("secureclient", "Cisco Secure Client / AnyConnect (VPN)"), ("/opt/cisco", "Cisco Secure Client / AnyConnect (VPN)"),
        ("qustodio", "Qustodio (parental control)"), ("net nanny", "Net Nanny (parental control)"),
        ("netnanny", "Net Nanny (parental control)"), ("mobicip", "Mobicip (parental control)"),
        ("ninjarmm", "NinjaOne (IT management)"), ("kaseya", "Kaseya (IT management)"), ("datto", "Datto RMM (IT management)"),
        ("ateraagent", "Atera (IT management)"), ("ltechagent", "ConnectWise Automate (IT management)"),
        ("manageengine", "ManageEngine (IT management)"), ("ivanti", "Ivanti (IT management)"),
        ("besagent", "HCL BigFix (IT management)"), ("lansweeper", "Lansweeper (inventory)"),
        ("self service", "Self Service (your organisation's app catalogue)"), ("managed software center", "Munki Managed Software Center"),
        ("nomad.app", "NoMAD (network sign-in)"), ("trusourcelabs", "NoMAD (network sign-in)"),
        ("xcreds", "XCreds (network sign-in)"), ("okta", "Okta (sign-in / device trust)"),
        // Remote control: often installed by IT, but people also install these themselves.
        ("teamviewer", "TeamViewer (remote control)"), ("anydesk", "AnyDesk (remote control)"),
        ("splashtop", "Splashtop (remote control)"), ("logmein", "LogMeIn / GoTo (remote control)"),
        ("screenconnect", "ConnectWise ScreenConnect (remote control)"),
        ("connectwisecontrol", "ConnectWise ScreenConnect (remote control)"), ("bomgar", "BeyondTrust Remote Support (remote control)"),
        ("beyondtrust", "BeyondTrust Remote Support (remote control)"), ("realvnc", "RealVNC (remote control)"),
        ("vnc server", "VNC Server (remote control)"), ("chromoting", "Chrome Remote Desktop (remote control)"),
        ("chromeremotedesktop", "Chrome Remote Desktop (remote control)"), ("rustdesk", "RustDesk (remote control)"),
    ]

    /// Vendors in knownAgents ending in this are remote-control apps, which don't by themselves mean the Mac is managed.
    static let remoteControlTag = " (remote control)"

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
    static let limitKeys: Set<String> = ["disabledpreferencepanes", "hiddenpreferencepanes", "disabledsystemsettings", "pathblacklist",
        "pathwhitelist", "mount-controls", "urlblocklist", "urlblacklist", "extensioninstallforcelist", "enforcedsoftwareupdatedelay"]

    static func restrictionItems(_ managed: [String: [String: Any]]) -> [(kind: String, key: String, domain: String, value: Any)] {
        var out: [(kind: String, key: String, domain: String, value: Any)] = []
        for (domain, dict) in managed {
            for (key, value) in dict {
                let k = key.lowercased()
                if k.hasPrefix("allow"), (value as? Bool) == false { out.append(("BLOCKED ", key, domain, value)) }
                if k.hasPrefix("disable") || k.hasPrefix("force"), (value as? Bool) == true { out.append(("ENFORCED", key, domain, value)) }
                if limitKeys.contains(k) { out.append(("LIMITED ", key, domain, value)) }
            }
        }
        return out.sorted { ($0.kind, $0.key) < ($1.kind, $1.key) }
    }

    static func restrictions(_ managed: [String: [String: Any]]) -> [String] {
        restrictionItems(managed).map { r in
            r.kind == "LIMITED "
                ? "\(r.kind)  \(r.key) = \(String(describing: r.value).replacingOccurrences(of: "\n", with: " ").prefix(160))  (\(r.domain))"
                : "\(r.kind)  \(r.key)  (\(r.domain))"
        }
    }

    /// Everyday words for the restriction keys people meet most; anything else is de-camel-cased.
    static func friendly(_ key: String) -> String {
        let known: [String: String] = [
            "allowcamera": "Use the camera", "allowscreenshot": "Take screenshots or record the screen", "allowairdrop": "Use AirDrop",
            "allowerasecontentandsettings": "Erase the Mac yourself", "allowicloudsignin": "Sign in to iCloud",
            "allowcloudkeychainsync": "Sync passwords with iCloud Keychain", "allowpasswordsharing": "Share passwords",
            "allowautounlock": "Unlock with your Apple Watch", "allowfingerprintforunlock": "Unlock with Touch ID",
            "allowdictation": "Use dictation", "allowmusicservice": "Use Apple Music", "allowgamecenter": "Use Game Center",
            "allowaccountmodification": "Add or change accounts", "allowexplicitcontent": "See explicit content",
            "disabledpreferencepanes": "Open some System Settings pages", "hiddenpreferencepanes": "See some System Settings pages",
            "disabledsystemsettings": "Open some System Settings pages", "mount-controls": "Use some USB drives or disks",
            "pathblacklist": "Open some apps", "pathwhitelist": "Open apps that aren't on an approved list",
            "urlblocklist": "Visit some websites", "urlblacklist": "Visit some websites",
            "extensioninstallforcelist": "Remove the browser extensions they added",
            "enforcedsoftwareupdatedelay": "Get macOS updates as soon as they come out",
            "forcesafesearch": "Turn off SafeSearch", "forcegooglesafesearch": "Turn off Google SafeSearch",
        ]
        if let k = known[key.lowercased()] { return k }
        var words = key
        for prefix in ["allow", "disable", "force"] where words.lowercased().hasPrefix(prefix) { words = String(words.dropFirst(prefix.count)) }
        let spaced = words.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
        let verb = key.lowercased().hasPrefix("allow") ? "Use: " : "Change: "
        return verb + spaced.prefix(1).uppercased() + spaced.dropFirst()
    }

    /// The plain-English version of the report, for someone who has never heard of MDM.
    static func plainSummary(_ f: ManagementFacts) -> [ManagementSection] {
        var out: [ManagementSection] = []
        let org = f.chromeOrgs.first ?? "your school or work"
        let otherParts = !f.vendors.isEmpty || f.profiles || !f.restrictions.isEmpty || f.intercepted || f.adBound
            || f.networkAccount || f.managedAppleID || !f.hiddenAdmins.isEmpty || !f.managedBrowsers.isEmpty

        let short: String
        if f.dep {
            short = "An organisation (usually a school or employer) fully controls this Mac. It was registered to them when it was bought, so they manage it even if it's wiped and set up again."
        } else if f.mdm {
            short = "An organisation (usually a school or employer) controls this Mac. Someone signed it up to their management system, which lets them change settings and apps from far away."
        } else if otherParts {
            short = "This Mac isn't signed up to an organisation's management system, but some settings or software on it are controlled by someone else."
        } else if !f.chromeOrgs.isEmpty {
            short = "Nobody else controls this Mac itself. But when you use Chrome signed in with your \(org) account, \(org) sets the rules for that Chrome profile."
        } else {
            short = "Nobody else controls this Mac. You're in charge of it."
        }
        out.append(.init(title: "In short", icon: "lightbulb", text: short, simple: true))

        var who: [String] = []
        if f.dep || f.mdm { who.append("• This Mac reports to a management server run by an organisation (this is called MDM, short for mobile device management).") }
        if !f.profileOrgs.isEmpty { who.append("• The settings packs on this Mac were made by: \(f.profileOrgs.joined(separator: ", ")).") }
        if !f.servers.isEmpty { who.append("• The management server's address: \(f.servers.joined(separator: ", ")).") }
        for v in f.vendors { who.append("• \(v) is installed. It's software organisations use to look after or watch their computers.") }
        if f.adBound { who.append("• The Mac is joined to an organisation's network accounts (Active Directory), so it may use work or school logins.") }
        if f.networkAccount { who.append("• You sign in with a school or work network account, so the organisation's directory controls your login.") }
        if f.managedAppleID { who.append("• You're signed in to iCloud with a Managed Apple Account, which belongs to the organisation.") }
        if !f.hiddenAdmins.isEmpty { who.append("• There's a hidden administrator account (\(f.hiddenAdmins.joined(separator: ", "))). Organisations often add one so their IT team can sign in.") }
        if f.profiles { who.append("• Settings packs (called configuration profiles) have been added. They turn settings on or off and can't always be changed by you.") }
        if !f.chromeOrgs.isEmpty { who.append("• Chrome: \(f.chromeOrgs.joined(separator: ", ")) manages the Chrome profile(s) you're signed into with that account.") }
        if !f.loginMessage.isEmpty { who.append("• The login screen shows this message: “\(f.loginMessage)”") }
        if !who.isEmpty { out.append(.init(title: "Who is in charge, and how", icon: "person.2", text: who.joined(separator: "\n"), simple: true)) }

        var can: [String] = []
        if f.dep || f.mdm {
            if let rights = f.mdmRights, !rights.isEmpty {
                can.append("• From far away, the management server is allowed to: " + rights.joined(separator: "; ") + ".")
            } else {
                can.append("• Add or remove apps, change settings, and lock or erase the Mac remotely.")
                can.append("• See basic facts about the Mac: its model, serial number, the apps installed, and storage space.")
            }
            can.append("• MDM on its own can't read your files, messages or photos. Other monitoring software could, if it's installed (see above).")
        }
        if f.escrow { can.append("• Unlock this Mac's disk: the organisation keeps a FileVault recovery key for it.") }
        if !f.privacy.isEmpty { can.append("• Decide, without asking you, whether some apps may use: " + f.privacy.joined(separator: ", ") + ".") }
        if f.webFilter { can.append("• Check or block the websites you visit, using a web filter.") }
        if !f.vendors.isEmpty { can.append("• Depending on how it's set up, the software listed above may see websites you visit, apps you use, or your screen.") }
        if f.intercepted { can.append("• Your web traffic is being opened up and checked by a filter, so it can see the websites you visit and what you send to them, even on secure (https) sites.") }
        else if f.extraCerts > 0 { can.append("• An extra security certificate is installed. Filters use these to read secure web traffic, so websites may be checked on some networks.") }
        if !f.chromeOrgs.isEmpty {
            can.append("• In the Chrome profile signed in as \(org): set rules, block websites, and add extensions you can't remove" + (f.chromeForced > 0 ? " (\(f.chromeForced) added so far)" : "") + ". Depending on their settings, they may also see that profile's browsing history.")
        }
        if f.chromeMachinePolicy { can.append("• Chrome settings are also forced for the whole Mac, so they apply to every Chrome profile, including personal ones.") }
        if !f.managedBrowsers.isEmpty { can.append("• Set rules in \(f.managedBrowsers.joined(separator: ", ")), such as blocked websites or extensions you can't remove.") }
        if !can.isEmpty { out.append(.init(title: "What they can do", icon: "eye", text: can.joined(separator: "\n"), simple: true)) }

        var remote: [String] = []
        if f.screenSharing { remote.append("• Screen Sharing or Remote Management is on, so someone with permission can watch and control this screen over the network.") }
        if !f.liveSessions.isEmpty { remote.append("• Someone looks to be connected to this Mac right now (\(f.liveSessions.joined(separator: ", "))).") }
        if f.ssh { remote.append("• Remote Login (SSH) is on, so someone with an account's password can run commands on this Mac over the network.") }
        let tools = f.remoteTools.map { $0.replacingOccurrences(of: remoteControlTag, with: "") }
        if !tools.isEmpty { remote.append("• Remote-control software is installed (\(tools.joined(separator: ", "))). If it's set up for it, someone could control this Mac from far away.") }
        if !remote.isEmpty { out.append(.init(title: "Who can connect from elsewhere", icon: "display", text: remote.joined(separator: "\n"), simple: true)) }

        var cant = f.restrictions.map { "• " + friendly($0.key) }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        if !f.isAdmin { cant.insert("• Install system software or change security settings without an administrator's password. Your account is a standard (non-admin) account.", at: 0) }
        if f.dep { cant.append("• Remove the management yourself. Only the organisation can release the Mac.") }
        out.append(.init(title: "What you can't do", icon: "hand.raised",
                         text: cant.isEmpty ? "Nothing is blocked. You can change settings, install apps and use every feature." : cant.joined(separator: "\n"), simple: true))

        var tips: [String] = []
        if f.dep || f.mdm || otherParts { tips.append("• Treat this Mac like a school or work computer: assume what you do on it could be seen.") }
        if !f.chromeOrgs.isEmpty && !f.chromeMachinePolicy { tips.append("• The \(org) rules only apply in Chrome while you're signed in with that account. A separate Chrome profile with a personal account isn't run by them.") }
        if f.dep || f.mdm { tips.append("• If the Mac is yours and should no longer be managed, ask the organisation's IT team to release it.") }
        if f.screenSharing || f.ssh { tips.append("• System Settings ▸ General ▸ Sharing shows who may connect. Turning these off needs an administrator.") }
        if !f.liveSessions.isEmpty { tips.append("• If you don't know who's connected, tell the person or IT team who looks after this Mac.") }
        if tips.isEmpty { tips.append("• Nothing to worry about here.") }
        tips.append("• Switch to Detailed for the technical information behind this summary.")
        out.append(.init(title: "What this means for you", icon: "info.circle", text: tips.joined(separator: "\n"), simple: true))
        return out
    }

    static func selfCheckChrome() {
        let ext = policyExtensions(["a": ["location": 7, "manifest": ["name": "Filter"]], "b": ["location": 1], "c": ["location": 9]])
        assert(ext == ["Filter (a)", "c"], "policy extension parsing")
        let r = restrictions(["com.apple.applicationaccess": ["allowCamera": false, "allowAirDrop": true], "x": ["forceSafeSearch": true]])
        assert(r.count == 2 && r[0].hasPrefix("BLOCKED   allowCamera") && r[1].hasPrefix("ENFORCED"), "restriction parsing")
        assert(friendly("allowCamera") == "Use the camera" && friendly("allowFooBar") == "Use: Foo Bar", "friendly names")
        var f = ManagementFacts(); f.chromeOrgs = ["school.org"]
        assert(plainSummary(f)[0].text.contains("school.org"), "chrome-only summary")
        f.dep = true; f.isAdmin = false
        let p = plainSummary(f)
        assert(p[0].text.contains("fully controls") && p.allSatisfy(\.simple), "DEP summary")
    }

    private static func json(_ path: String) -> [String: Any] {
        guard let data = FileManager.default.contents(atPath: path) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    static func chromeSection() -> (text: String, orgs: [String], forced: Int, machinePolicy: Bool) {
        var orgs: [String] = [], forcedTotal = 0, machinePolicy = false
        var lines: [String] = []
        let fm = FileManager.default
        // Machine-wide policy pushed by MDM
        let policyPath = "/Library/Managed Preferences/com.google.Chrome.plist"
        if let policy = NSDictionary(contentsOfFile: policyPath) as? [String: Any] {
            lines.append("Machine policy (from MDM): \(policy.count) Chrome policies in force")
            machinePolicy = true
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
            if managed || (!domain.isEmpty && domain != "NO_HOSTED_DOMAIN") {
                let name = domain.isEmpty || domain == "NO_HOSTED_DOMAIN" ? (label.isEmpty ? "An organisation" : label) : domain
                if !orgs.contains(name) { orgs.append(name) }
                forcedTotal = max(forcedTotal, forced.count)
            }
            lines.append("  Extensions:    \(settings.count) total, \(forced.count) installed by policy" + (forced.isEmpty ? "" : ":"))
            lines += forced.map { "    • \($0)" }
        }
        lines.append("\nTip: open chrome://policy and chrome://management in Chrome to see every policy and where it came from.")
        lines.append("Note: Google's own Docs/Sheets/Slides/Drive apps can show as policy-installed on some Macs.")
        return (lines.joined(separator: "\n"), orgs, forcedTotal, machinePolicy)
    }

    // MARK: - Deeper checks (all read-only, no admin needed)

    /// Every distinct match of a pattern's first group. `^` and `$` match at each line.
    static func captures(_ pattern: String, in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return [] }
        var out: [String] = []
        for match in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) where match.numberOfRanges > 1 {
            guard let range = Range(match.range(at: 1), in: text) else { continue }
            let value = text[range].trimmingCharacters(in: .whitespaces)
            if !value.isEmpty && !out.contains(value) { out.append(value) }
        }
        return out
    }

    /// The MDM server's address in the MDM payload, e.g. ServerURL = "https://school.jamfcloud.com/mdm/ServerURL";
    static let serverURLPattern = #"(?:ServerURL|CheckInURL)\s*=\s*"?([^";\s]+)"#

    /// The MDM payload's AccessRights bits: what the management server is allowed to do (Apple's MDM payload reference).
    static let mdmRightNames: [(bit: Int, plain: String)] = [
        (1, "see the settings packs installed"), (2, "add and remove settings packs"),
        (4, "lock the Mac and remove its passcode"), (8, "erase the Mac"),
        (16, "see device details (model, serial number, storage)"), (32, "see network details (hardware addresses)"),
        (64, "see provisioning profiles"), (128, "add and remove provisioning profiles"),
        (256, "see the apps installed"), (512, "check which restrictions are on"),
        (1024, "check security settings (such as FileVault and the firewall)"), (2048, "change settings"),
        (4096, "install and remove apps"),
    ]

    static func mdmRights(_ value: Int) -> [String] { mdmRightNames.filter { (value & $0.bit) != 0 }.map(\.plain) }

    /// Who runs the management: server address, organisation, Jamf/Munki servers, Activation Lock and the MDM's permissions.
    static func serverSection(profiles: String, mdm: Bool) -> (text: String, servers: [String], orgs: [String], rights: [String]?) {
        var servers: [String] = []
        for url in captures(serverURLPattern, in: profiles) {
            if let host = URL(string: url)?.host, !servers.contains(host) { servers.append(host) }
        }
        let orgs = captures(#"^\s*Organization:\s*(.+)$"#, in: profiles)
        var lines: [String] = []
        lines.append("Management server: " + (servers.isEmpty ? "none found in the profiles" : servers.joined(separator: ", ")))
        lines.append("Organisation named in the profiles: " + (orgs.isEmpty ? "none" : orgs.joined(separator: ", ")))
        if let jamf = NSDictionary(contentsOfFile: "/Library/Preferences/com.jamfsoftware.jamf.plist")?["jss_url"] as? String {
            lines.append("Jamf server: \(jamf)")
        }
        let munki = ["/Library/Managed Preferences/ManagedInstalls.plist", "/Library/Preferences/ManagedInstalls.plist"]
            .compactMap { NSDictionary(contentsOfFile: $0)?["SoftwareRepoURL"] as? String }.first
        if let munki = munki { lines.append("Munki software server: \(munki)") }
        let hardware = Shell.runSync("/usr/sbin/system_profiler", ["SPHardwareDataType"]).output
        if let lock = captures(#"Activation Lock Status:\s*(.+)$"#, in: hardware).first {
            lines.append("Activation Lock: \(lock)" + (lock.lowercased().hasPrefix("enabled")
                ? " (tied to an Apple Account, which is needed to erase and set up the Mac again)" : ""))
        }
        if profiles.range(of: #"Removal Disallowed:\s*(Yes|True|1)\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
            lines.append("Some profiles are marked “removal disallowed”, so you can't remove them yourself.")
        }
        var rights: [String]? = nil
        if let raw = captures(#"AccessRights\s*=\s*(\d+)"#, in: profiles).first, let value = Int(raw) {
            let list = mdmRights(value)
            rights = list
            lines.append("\nWhat the MDM server is allowed to do (AccessRights \(value)):")
            lines += list.map { "  ✓ " + $0 }
        } else if mdm {
            lines.append("\nThe MDM server's permissions (AccessRights) aren't shown in the profiles.")
        }
        return (lines.joined(separator: "\n"), servers, orgs, rights)
    }

    /// Settings-pack (payload) types and what they let the organisation do.
    static let payloadMeanings: [(type: String, plain: String)] = [
        ("com.apple.mdm", "Remote management (MDM): the organisation's server can send commands to this Mac"),
        ("com.apple.applicationaccess", "Restrictions: some features are turned off (see What you can and can't do)"),
        ("com.apple.TCC.configuration-profile-policy", "Privacy permissions: decides for you whether some apps may use protected things"),
        ("com.apple.webcontent-filter", "Web filter: websites are checked or blocked by a filter"),
        ("com.apple.dnsSettings.managed", "DNS settings: website look-ups go through the organisation's DNS server, often to filter them"),
        ("com.apple.dnsProxy.managed", "DNS proxy: an app handles website look-ups, often to filter them"),
        ("com.apple.relay.managed", "Network relay: traffic for some apps or websites goes through the organisation's relay server"),
        ("com.apple.vpn.managed", "VPN: a VPN set up by the organisation (it may be always on, or start by itself)"),
        ("com.apple.security.root", "Trusted certificates: a filter can use these to read secure (https) web traffic"),
        ("com.apple.security.pkcs1", "Certificates added by the organisation"),
        ("com.apple.security.pem", "Certificates added by the organisation"),
        ("com.apple.security.pkcs12", "Identity certificate: lets this Mac prove who it is to the organisation's Wi-Fi, VPN or servers"),
        ("com.apple.security.scep", "Identity certificate from the organisation's certificate server"),
        ("com.apple.security.acme", "Identity certificate from the organisation's certificate server"),
        ("com.apple.security.FDERecoveryKeyEscrow", "FileVault key escrow: the organisation keeps a recovery key that can unlock this Mac's disk"),
        ("com.apple.MCX.FileVault2", "FileVault: disk encryption is required by the organisation"),
        ("com.apple.servicemanagement", "Managed login items: some background apps always run and can't be switched off in System Settings"),
        ("com.apple.system-extension-policy", "System extensions approved in advance (they can see network traffic, files or processes)"),
        ("com.apple.syspolicy.kernel-extension-policy", "Kernel extensions approved in advance"),
        ("com.apple.systempolicy.control", "Gatekeeper rules: which apps are allowed to open"),
        ("com.apple.SoftwareUpdate", "Software updates: the organisation controls when macOS updates install"),
        ("com.apple.extensiblesso", "Single sign-on: an app signs you in to the organisation's services (and maybe the Mac itself)"),
        ("com.apple.mobiledevice.passwordpolicy", "Password rules: your login password must follow the organisation's rules"),
        ("com.apple.screensaver", "Screen lock: screen saver and lock timing are set"),
        ("com.apple.loginwindow", "Login window: its message, look or list of users is set"),
        ("com.apple.wifi.managed", "Wi-Fi: networks added by the organisation"),
        ("com.apple.security.firewall", "Firewall settings are set"),
        ("com.apple.DirectoryService.managed", "Directory: network accounts are set up"),
        ("com.apple.notificationsettings", "Notifications: some apps' notification settings are fixed"),
        ("com.apple.dock", "Dock: set up by the organisation"),
        ("com.apple.ManagedClient.preferences", "Custom app settings (see Enforced settings)"),
    ]

    /// Privacy (TCC) services a privacy-permissions payload can set, in everyday words.
    static let privacyServices: [(key: String, plain: String)] = [
        ("SystemPolicyAllFiles", "Full Disk Access (read all files)"), ("Accessibility", "Accessibility (control the Mac)"),
        ("ScreenCapture", "Screen Recording (blocked, or left for you to approve)"), ("ListenEvent", "Input Monitoring (see what's typed)"),
        ("PostEvent", "controlling the keyboard and mouse"), ("AppleEvents", "Automation (controlling other apps)"),
        ("SystemPolicySysAdminFiles", "changing system files"), ("SystemPolicyDocumentsFolder", "the Documents folder"),
        ("SystemPolicyDesktopFolder", "the Desktop folder"), ("SystemPolicyDownloadsFolder", "the Downloads folder"),
        ("SystemPolicyNetworkVolumes", "network drives"), ("SystemPolicyRemovableVolumes", "USB drives"),
        ("Camera", "the camera (can only be blocked)"), ("Microphone", "the microphone (can only be blocked)"),
        ("AddressBook", "Contacts"), ("Calendar", "Calendars"), ("Reminders", "Reminders"), ("Photos", "Photos"),
        ("BluetoothAlways", "Bluetooth"),
    ]

    /// Whether the profiles contain this payload type (not just a longer name that starts with it).
    static func hasPayload(_ type: String, in profiles: String) -> Bool {
        profiles.range(of: NSRegularExpression.escapedPattern(for: type) + "(?![A-Za-z0-9.-])",
                       options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// What the installed profiles control, in plain English.
    static func controlsSection(profiles: String) -> (text: String, privacy: [String], escrow: Bool, webFilter: Bool) {
        var controls: [String] = []
        for p in payloadMeanings where hasPayload(p.type, in: profiles) && !controls.contains(p.plain) { controls.append(p.plain) }
        var privacy: [String] = []
        if hasPayload("com.apple.TCC.configuration-profile-policy", in: profiles) {
            for service in privacyServices where profiles.range(of: #"\b"# + service.key + #"\s*=\s*\("#, options: .regularExpression) != nil {
                privacy.append(service.plain)
            }
        }
        let escrow = hasPayload("com.apple.security.FDERecoveryKeyEscrow", in: profiles)
        let webFilter = hasPayload("com.apple.webcontent-filter", in: profiles) || hasPayload("com.apple.dnsProxy.managed", in: profiles)
        var lines = controls.map { "• " + $0 }
        if !privacy.isEmpty { lines.append("\nPrivacy permissions set for some apps (allowed or blocked): " + privacy.joined(separator: ", ")) }
        let text: String
        if profiles.hasPrefix("No configuration") {
            text = "No configuration profiles installed."
        } else if lines.isEmpty {
            text = "None of the common setting types MacTools knows about. See Configuration profiles & payloads for everything."
        } else {
            text = lines.joined(separator: "\n")
        }
        return (text, privacy, escrow, webFilter)
    }

    /// Ports something listens on, and connections coming in, from `netstat -an`.
    static func sockets(_ netstat: String) -> (listening: Set<Int>, connected: [(port: Int, remote: String)]) {
        var listening = Set<Int>()
        var connected: [(port: Int, remote: String)] = []
        for line in netstat.split(separator: "\n") {
            let f = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard f.count >= 5, f[0].hasPrefix("tcp") || f[0].hasPrefix("udp"),
                  let dot = f[3].lastIndex(of: "."), let port = Int(f[3][f[3].index(after: dot)...]) else { continue }
            let state = f.count >= 6 ? f[5] : ""
            if state == "LISTEN" || f[0].hasPrefix("udp") { listening.insert(port) }
            if state == "ESTABLISHED", let remoteDot = f[4].lastIndex(of: ".") { connected.append((port: port, remote: String(f[4][..<remoteDot]))) }
        }
        return (listening, connected)
    }

    /// Screen Sharing, Remote Management and SSH, who's connected now, and remote-control apps.
    static func remoteSection(remoteTools: [String]) -> (text: String, screenSharing: Bool, ssh: Bool, live: [String]) {
        let net = sockets(Shell.runSync("/usr/sbin/netstat", ["-an"]).output)
        let screen = net.listening.contains(5900)
        let ard = net.listening.contains(3283)
        let ssh = net.listening.contains(22)
        let live = net.connected.filter { $0.port == 5900 || $0.port == 22 }
            .map { ($0.port == 22 ? "SSH" : "screen sharing") + " from " + $0.remote }
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        func onOff(_ on: Bool) -> String { on ? "ON " : "off" }
        var lines: [String] = []
        lines.append("\(onOff(screen))  Screen Sharing / Remote Management or a VNC server (port 5900)"
            + (screen ? ": someone with permission can watch and control this screen over the network" : ""))
        lines.append("\(onOff(ard))  Apple Remote Desktop / Remote Management (port 3283)")
        lines.append("\(onOff(ssh))  Remote Login – SSH (port 22)"
            + (ssh ? ": someone with an account's password can run commands over the network" : ""))
        lines.append("\nConnected right now: "
            + (live.isEmpty ? "nobody (no screen sharing or SSH connections into this Mac)" : live.joined(separator: ", ")))
        lines.append("Remote-control apps found: " + (remoteTools.isEmpty ? "none known" : remoteTools.joined(separator: ", ")))
        lines.append("\nSystem Settings ▸ General ▸ Sharing shows who may use Screen Sharing, Remote Management and Remote Login.")
        return (lines.joined(separator: "\n"), screen || ard, ssh, live)
    }

    /// Local accounts (hidden admins, network accounts), iCloud, and what runs at the login screen.
    static func accountsSection(admins: [String], managed: [String: [String: Any]])
        -> (text: String, hiddenAdmins: [String], networkAccount: Bool, managedAppleID: Bool, loginMessage: String) {
        let me = NSUserName()
        var lines = ["Accounts on this Mac:"]
        var hiddenAdmins: [String] = []
        var networkAccount = false
        let users = Shell.runSync("/usr/bin/dscl", [".", "-list", "/Users", "UniqueID"]).output.split(separator: "\n")
            .compactMap { line -> (name: String, uid: Int)? in
                let f = line.split(whereSeparator: \.isWhitespace)
                guard f.count == 2, let uid = Int(f[1]), uid >= 400, !f[0].hasPrefix("_") else { return nil }
                return (name: String(f[0]), uid: uid)
            }
        for user in users.sorted(by: { $0.uid < $1.uid }) {
            let info = Shell.runSync("/usr/bin/dscl", [".", "-read", "/Users/" + user.name, "IsHidden", "AuthenticationAuthority"]).combined
            let flaggedHidden = info.range(of: #"IsHidden:\s*(1|yes|true)"#, options: [.regularExpression, .caseInsensitive]) != nil
            let lowID = user.uid < 501  // normal accounts start at 501; IT accounts are often given a lower one
            let network = info.contains("LocalCachedUser")
            let admin = admins.contains(user.name)
            if admin && (flaggedHidden || lowID) && user.name != me { hiddenAdmins.append(user.name) }
            if network && user.name == me { networkAccount = true }
            var notes = [admin ? "administrator" : "standard"]
            if flaggedHidden { notes.append("hidden from the login screen") } else if lowID { notes.append("ID below 501, often used for hidden IT accounts") }
            if network { notes.append("network account (school or work directory login)") }
            if user.name == me { notes.append("you") }
            lines.append("  ● \(user.name) (ID \(user.uid)): " + notes.joined(separator: ", "))
        }

        let mobileMe = NSDictionary(contentsOfFile: NSHomeDirectory() + "/Library/Preferences/MobileMeAccounts.plist")
        let appleAccounts = mobileMe?["Accounts"] as? [[String: Any]] ?? []
        var icloud: [String] = []
        var managedAppleID = false
        for account in appleAccounts {
            guard let id = account["AccountID"] as? String, !id.isEmpty else { continue }
            let managedAccount = (account["isManagedAppleID"] as? Bool) == true
            if managedAccount { managedAppleID = true }
            icloud.append(id + (managedAccount ? " (Managed Apple Account, owned by an organisation)" : ""))
        }
        lines.append("\niCloud / Apple Account: " + (icloud.isEmpty ? "not signed in (or not readable)" : icloud.joined(separator: ", ")))

        var login = NSDictionary(contentsOfFile: "/Library/Preferences/com.apple.loginwindow.plist") as? [String: Any] ?? [:]
        login.merge(managed["com.apple.loginwindow"] ?? [:]) { _, enforced in enforced }
        let message = (login["LoginwindowText"] as? String ?? "").trimmed
        lines.append("Login screen message: " + (message.isEmpty ? "none" : "“\(message)”"))
        let hooks = ["LoginHook", "LogoutHook"].compactMap { key in (login[key] as? String).map { "\(key): \($0)" } }
        lines.append("Login/logout scripts (run by the system at every login): " + (hooks.isEmpty ? "none" : "\n  " + hooks.joined(separator: "\n  ")))
        let plugins = list("/Library/Security/SecurityAgentPlugins").sorted()
        lines.append("Login screen add-ons (/Library/Security/SecurityAgentPlugins): " + (plugins.isEmpty ? "none" : plugins.joined(separator: ", ")))
        return (lines.joined(separator: "\n"), hiddenAdmins, networkAccount, managedAppleID, message)
    }

    /// Policies for Safari, Edge, Brave and Firefox (Chrome has its own section).
    static func otherBrowsersSection(managed: [String: [String: Any]]) -> (text: String, managed: [String]) {
        var lines: [String] = []
        var managedNames: [String] = []
        for (name, domain) in [("Safari", "com.apple.Safari"), ("Microsoft Edge", "com.microsoft.Edge"),
                               ("Brave", "com.brave.Browser"), ("Firefox", "org.mozilla.firefox")] {
            let count = managed.filter { $0.key == domain || $0.key.hasSuffix("/" + domain) }.reduce(0) { $0 + $1.value.count }
            if count > 0 { managedNames.append(name) }
            lines.append("\(name): " + (count == 0 ? "no managed settings" : "\(count) managed setting(s) from the organisation (see Enforced settings)"))
        }
        let firefoxPolicy = "/Applications/Firefox.app/Contents/Resources/distribution/policies.json"
        if let policies = json(firefoxPolicy)["policies"] as? [String: Any], !policies.isEmpty {
            if !managedNames.contains("Firefox") { managedNames.append("Firefox") }
            lines.append("Firefox policies.json (\(policies.count)): " + policies.keys.sorted().joined(separator: ", "))
        }
        return (lines.joined(separator: "\n"), managedNames)
    }

    /// Lines in /etc/hosts beyond the standard localhost ones. These redirect or block website names.
    static func hostsEntries() -> [String] {
        let text = (try? String(contentsOfFile: "/etc/hosts", encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap { raw -> String? in
            let line = (raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? "")
                .trimmingCharacters(in: .whitespaces)
            let names = line.split(whereSeparator: \.isWhitespace).dropFirst()
            return names.isEmpty || names.allSatisfy({ ["localhost", "broadcasthost"].contains($0.lowercased()) }) ? nil : line
        }
    }

    static func selfCheckDeep() {
        let net = sockets("tcp4  0  0  *.5900  *.*  LISTEN\ntcp4  0  0  10.0.0.2.5900  10.0.0.9.50123  ESTABLISHED\nudp4  0  0  *.3283  *.*")
        assert(net.listening == [5900, 3283] && net.connected.first?.remote == "10.0.0.9", "netstat parsing")
        assert(mdmRights(8191).count == 13 && mdmRights(8) == ["erase the Mac"], "access rights")
        let p = "com.apple.mdm:\n  AccessRights = 8191;\n  ServerURL = \"https://acme.example.com/mdm\";\n"
            + "com.apple.TCC.configuration-profile-policy:\n  Services = {\n    Accessibility = (\n"
        assert(hasPayload("com.apple.mdm", in: p) && !hasPayload("com.apple.mdm", in: "com.apple.mdmclient com.apple.mdm.x"), "payload types")
        assert(controlsSection(profiles: p).privacy == ["Accessibility (control the Mac)"], "privacy permissions")
        assert(captures(serverURLPattern, in: p) == ["https://acme.example.com/mdm"], "server address")
        assert(hostsEntries().allSatisfy { !$0.hasPrefix("127.0.0.1\tlocalhost") }, "hosts defaults")
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
        selfCheck(); selfCheckChrome(); selfCheckDeep()
        #endif
        var sections: [ManagementSection] = []

        // Configuration profiles with every payload (works without admin, unlike `profiles show`). Several checks read them.
        var profiles = Shell.runSync("/usr/sbin/system_profiler", ["SPConfigurationProfileDataType"]).output
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if profiles.isEmpty { profiles = "No configuration profiles installed." }

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
        let mdm = enrollText.contains("MDM enrollment: Yes")

        // 2. Who runs the management, and what the MDM server is allowed to do
        let server = serverSection(profiles: profiles, mdm: mdm)
        sections.append(.init(title: "Management server & permissions", icon: "server.rack", text: server.text))

        // 3. Management, monitoring and security agents: by file and folder name, running process and installed package
        var names: [String] = []
        for folder in ["/Applications", "/Applications/Utilities", "/Library/LaunchDaemons", "/Library/LaunchAgents",
                       "/Library/Application Support", "/Library/PrivilegedHelperTools", "/Library/Extensions",
                       "/Library/Security/SecurityAgentPlugins", "/usr/local", "/opt", NSHomeDirectory() + "/Library/LaunchAgents"] {
            names += list(folder).map { folder + "/" + $0 }
        }
        names += Shell.runSync("/bin/ps", ["-axo", "comm="]).output.split(separator: "\n").map { "running: " + String($0) }
        names += Shell.runSync("/usr/sbin/pkgutil", ["--pkgs"]).output.split(separator: "\n").map { "package: " + String($0) }
        let agents = matchAgents(in: names)
        let remoteTools = agents.keys.filter { $0.hasSuffix(remoteControlTag) }.sorted()
        let managementAgents = agents.filter { !$0.key.hasSuffix(remoteControlTag) }
        let agentText = agents.isEmpty
            ? "No known management or monitoring agent found by name. (A custom or renamed agent would not show here; check the profiles and extensions below.)"
            : agents.keys.sorted().map { vendor in "● \(vendor)\n" + agents[vendor]!.map { "    " + $0 }.joined(separator: "\n") }.joined(separator: "\n\n")
        sections.append(.init(title: "Management & monitoring software found", icon: "eye", text: agentText))

        // 4. Configuration profiles, and what they control in plain English
        sections.append(.init(title: "Configuration profiles & payloads", icon: "doc.badge.gearshape", text: profiles))
        let controls = controlsSection(profiles: profiles)
        sections.append(.init(title: "What the profiles control", icon: "slider.horizontal.3", text: controls.text))

        // 5. Settings actually enforced right now (what the profiles push into Managed Preferences)
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

        // 6. Extensions that can see network traffic, files or processes
        var ext = run("/usr/bin/systemextensionsctl", ["list"])
        let kexts = Shell.runSync("/usr/bin/kmutil", ["showloaded", "--list-only"]).output
            .split(separator: "\n").filter { !$0.contains("com.apple") }.joined(separator: "\n")
        ext += "\n\nThird-party kernel extensions loaded:\n" + (kexts.isEmpty ? "(none)" : kexts)
        sections.append(.init(title: "System & kernel extensions", icon: "puzzlepiece.extension", text: ext))

        // 7. Remote access: Screen Sharing, Remote Management, SSH, live connections, remote-control apps
        let remote = remoteSection(remoteTools: remoteTools)
        sections.append(.init(title: "Remote access & screen sharing", icon: "display", text: remote.text))

        // 8. Network control: proxy, VPN, DNS, hosts file
        let hosts = hostsEntries()
        let net = "Proxy settings:\n" + run("/usr/sbin/scutil", ["--proxy"])
            + "\n\nVPN / network services:\n" + run("/usr/sbin/scutil", ["--nc", "list"])
            + "\n\nDNS servers:\n" + Shell.runSync("/usr/sbin/scutil", ["--dns"]).output
                .split(separator: "\n").filter { $0.contains("nameserver") || $0.contains("domain") }
                .map { $0.trimmingCharacters(in: .whitespaces) }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
                .joined(separator: "\n")
            + "\n\nHosts file (/etc/hosts) entries beyond the standard ones:\n"
            + (hosts.isEmpty ? "none" : hosts.joined(separator: "\n") + "\n(These redirect or block the website names listed.)")
        sections.append(.init(title: "Network control (proxy, VPN, DNS)", icon: "network.badge.shield.half.filled", text: net))

        // 9. Extra root certificates – these allow HTTPS inspection by a filter
        let certs = Shell.runSync("/usr/bin/security", ["find-certificate", "-a", "/Library/Keychains/System.keychain"]).output
            .split(separator: "\n").filter { $0.contains("\"labl\"") }
            .map { $0.replacingOccurrences(of: "\"labl\"<blob>=", with: "").trimmingCharacters(in: CharacterSet(charactersIn: " \"")) }
            .filter { !$0.hasPrefix("com.apple.") && !$0.hasPrefix("Apple ") }
        sections.append(.init(title: "Certificates added to the System keychain", icon: "checkmark.seal",
                              text: certs.isEmpty ? "No extra certificates. (A web filter that inspects HTTPS normally installs one here.)"
                                                  : certs.joined(separator: "\n") + "\n\nA certificate from a filter or your organisation lets it read HTTPS traffic in browsers that trust it."))

        // 10. Security baseline
        let baseline = [
            "SIP:        " + run("/usr/bin/csrutil", ["status"]),
            "Gatekeeper: " + run("/usr/sbin/spctl", ["--status"]),
            "FileVault:  " + run("/usr/bin/fdesetup", ["status"]),
            "Firewall:   " + run("/usr/libexec/ApplicationFirewall/socketfilterfw", ["--getglobalstate"]),
            "Admins:     " + run("/usr/bin/dscl", [".", "-read", "/Groups/admin", "GroupMembership"]).replacingOccurrences(of: "GroupMembership: ", with: ""),
            "You:        " + NSUserName() + (isAdmin ? " (administrator)" : " (standard user)"),
        ].joined(separator: "\n")
        sections.append(.init(title: "Security & accounts", icon: "shield.lefthalf.filled", text: baseline))

        // 11. Accounts and sign-in: hidden admins, network accounts, iCloud, the login screen
        let admins = Shell.runSync("/usr/bin/dscl", [".", "-read", "/Groups/admin", "GroupMembership"]).output
            .replacingOccurrences(of: "GroupMembership:", with: "").split(whereSeparator: \.isWhitespace).map(String.init)
        let accounts = accountsSection(admins: admins, managed: managedDicts)
        sections.append(.init(title: "Accounts & sign-in", icon: "person.crop.circle.badge.checkmark", text: accounts.text))

        // 12. What you can and can't do – harmless checks only (nothing is written, installed or changed)
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

        // 13. Chrome
        let chromeInfo = chromeSection()
        let chrome = chromeInfo.text
        sections.append(.init(title: "Chrome profiles & policies", icon: "globe", text: chrome))

        // 14. Safari, Edge, Brave and Firefox
        let browsers = otherBrowsersSection(managed: managedDicts)
        sections.append(.init(title: "Safari, Edge, Brave & Firefox policies", icon: "safari", text: browsers.text))

        // Verdict: how managed this Mac is, and how it's done
        let hasProfiles = !profiles.hasPrefix("No configuration")
        var how: [String] = []
        if dep { how.append("Enrolled automatically through Apple School/Business Manager (DEP) – the device is tied to the organisation and re-enrolls after an erase") }
        else if mdm { how.append("Enrolled in MDM by installing an enrollment profile" + (enrollText.contains("User Approved") ? " (user approved)" : "")) }
        if !server.orgs.isEmpty { how.append("Organisation: " + server.orgs.joined(separator: ", ")) }
        if !server.servers.isEmpty { how.append("Management server: " + server.servers.joined(separator: ", ")) }
        if !managementAgents.isEmpty { how.append("Software: " + managementAgents.keys.sorted().joined(separator: ", ")) }
        if hasProfiles { how.append("Configuration profiles installed (see below)") }
        if controls.escrow { how.append("The organisation keeps this Mac's FileVault recovery key") }
        if !controls.privacy.isEmpty { how.append("Privacy permissions set for some apps: " + controls.privacy.joined(separator: ", ")) }
        if !accounts.hiddenAdmins.isEmpty { how.append("Hidden admin account(s): " + accounts.hiddenAdmins.joined(separator: ", ")) }
        if accounts.networkAccount { how.append("You sign in with a network (directory) account") }
        if accounts.managedAppleID { how.append("Signed in with a Managed Apple Account") }
        if !browsers.managed.isEmpty { how.append("Browser policies: " + browsers.managed.joined(separator: ", ")) }
        if !blocked.isEmpty { how.append("\(blocked.count) restriction(s) enforced through Managed Preferences") }
        if intercepted || !certs.isEmpty { how.append("Web traffic: extra root certificate(s)" + (intercepted ? " and HTTPS interception is active" : "")) }
        if !ad.isEmpty { how.append("Bound to Active Directory") }
        if chrome.contains("Managed:       YES") || chrome.contains("Machine policy (from MDM): ") && !chrome.contains("Machine policy (from MDM): none") { how.append("Chrome is managed (machine policy and/or a managed Google account)") }
        if !isAdmin { how.append("You are a standard user, so system changes need an admin password") }
        var notes: [String] = []  // worth knowing, but people turn these on for themselves too, so they don't count as management
        if remote.screenSharing { notes.append("Screen Sharing / Remote Management is on") }
        if remote.ssh { notes.append("Remote Login (SSH) is on") }
        if !remote.live.isEmpty { notes.append("Connected right now: " + remote.live.joined(separator: ", ")) }
        if !remoteTools.isEmpty { notes.append("Remote-control apps: " + remoteTools.joined(separator: ", ")) }
        let level: String
        switch (dep, mdm, hasProfiles || !managementAgents.isEmpty || !managedDicts.isEmpty || accounts.networkAccount) {
        case (true, _, _): level = "Level 3 – Fully managed & supervised"
        case (false, true, _): level = "Level 2 – MDM managed"
        case (false, false, true): level = "Level 1 – Partly managed (profiles or agents, no MDM)"
        default: level = how.isEmpty ? "Level 0 – Not managed" : "Level 0 – Mac not enrolled, but some parts are managed"
        }
        var verdict = how.isEmpty ? "Nothing on this Mac points to an organisation managing it." : how.map { "• " + $0 }.joined(separator: "\n")
        if !notes.isEmpty { verdict += "\n\nAlso worth knowing:\n" + notes.map { "• " + $0 }.joined(separator: "\n") }
        sections.insert(.init(title: "Verdict: \(level)", icon: "checklist", text: verdict), at: 0)

        var facts = ManagementFacts()
        facts.dep = dep; facts.mdm = mdm; facts.profiles = hasProfiles; facts.adBound = !ad.isEmpty; facts.isAdmin = isAdmin
        facts.intercepted = intercepted; facts.extraCerts = certs.count; facts.vendors = managementAgents.keys.sorted()
        facts.restrictions = restrictionItems(managedDicts).map { ($0.key, $0.value) }
        facts.chromeOrgs = chromeInfo.orgs; facts.chromeForced = chromeInfo.forced; facts.chromeMachinePolicy = chromeInfo.machinePolicy
        facts.servers = server.servers; facts.profileOrgs = server.orgs; facts.mdmRights = server.rights
        facts.privacy = controls.privacy; facts.escrow = controls.escrow; facts.webFilter = controls.webFilter
        facts.screenSharing = remote.screenSharing; facts.ssh = remote.ssh; facts.liveSessions = remote.live; facts.remoteTools = remoteTools
        facts.hiddenAdmins = accounts.hiddenAdmins; facts.networkAccount = accounts.networkAccount
        facts.managedAppleID = accounts.managedAppleID; facts.loginMessage = accounts.loginMessage
        facts.managedBrowsers = browsers.managed
        return plainSummary(facts) + sections
    }
}

struct ManagementInspectorView: View {
    enum Mode: String, CaseIterable { case simple = "Simple", detailed = "Detailed" }
    @State private var sections: [ManagementSection] = []
    @State private var loading = false
    @State private var status = ""
    @State private var mode = Mode.simple

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
            Picker("View", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).frame(width: 220).labelsHidden()
            if !status.isEmpty { Text(status).font(.caption).foregroundColor(.accentColor) }
            ForEach(sections.filter { mode == .simple ? $0.simple : !$0.simple }) { section in
                Card(title: section.title, icon: section.icon) {
                    if mode == .simple {
                        Text(section.text).font(.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    } else {
                        OutputBox(text: section.text, minHeight: 40, maxHeight: 320)
                    }
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
