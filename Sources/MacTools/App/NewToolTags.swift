import SwiftUI

/// The "NEW" tags in the sidebar and on Home. A tool keeps its tag until you open it for the first time.
///
/// Tools added in later updates are tagged on their own: MacTools remembers which tools it has listed
/// before, so any tool it hasn't listed yet counts as new. Nothing needs to be marked by hand.
final class NewToolTags: ObservableObject {
    static let shared = NewToolTags()

    /// The tools from the last two updates (VPN / Proxy Client and MP3 to FLAC, then Management Inspector).
    /// They're tagged the first time a copy of MacTools runs with New tags: after updating from an older
    /// version, or on a fresh install.
    static let recentlyAdded: [ToolID] = [.proxyClient, .mp3ToFlac, .managementInspector]

    /// Tools that show a New tag right now.
    @Published private(set) var tagged: Set<ToolID>

    private static let knownKey = "newTagsKnownTools"  // every tool this copy of MacTools has listed
    private static let taggedKey = "newTagsTools"      // tools not opened yet

    private init() {
        let defaults = UserDefaults.standard
        let current = ToolID.visible
        var tags: Set<ToolID>
        if let known = defaults.stringArray(forKey: Self.knownKey) {
            let saved = defaults.stringArray(forKey: Self.taggedKey) ?? []
            tags = Set(saved.compactMap { ToolID(rawValue: $0) })
            let knownNames = Set(known)
            tags.formUnion(current.filter { !knownNames.contains($0.rawValue) })  // added since last launch
        } else {
            tags = Set(Self.recentlyAdded)  // first launch with New tags
        }
        tags.remove(.home)
        tagged = tags.intersection(current)
        defaults.set(current.map(\.rawValue), forKey: Self.knownKey)
        save()
    }

    func isNew(_ tool: ToolID) -> Bool { tagged.contains(tool) }

    /// Removes the tag once a tool has been opened.
    func markSeen(_ tool: ToolID) {
        guard tagged.contains(tool) else { return }
        tagged.remove(tool)
        save()
    }

    private func save() {
        UserDefaults.standard.set(tagged.map(\.rawValue).sorted(), forKey: Self.taggedKey)
    }
}

/// The small "NEW" tag shown on tools you haven't opened yet.
struct NewTag: View {
    var body: some View {
        Text("NEW")
            .font(.system(size: 9, weight: .heavy))
            .foregroundColor(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.accentColor))
            .fixedSize()
            .help("New in a recent update. The tag goes away once you open this tool.")
    }
}
