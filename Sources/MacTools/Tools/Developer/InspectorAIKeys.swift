import SwiftUI

extension AIProvider {
    /// A short name for buttons: "Claude" or "ChatGPT".
    var shortName: String {
        switch self {
        case .claude: return "Claude"
        case .openAI: return "ChatGPT"
        }
    }
}

/// Picks Claude or ChatGPT and lets you add or change that provider's API key.
/// Keys go into the Keychain through School To-Do's key store, so one key works everywhere in MacTools.
struct AIProviderBar: View {
    @Binding var provider: AIProvider
    @ObservedObject private var planner = SchoolPlanner.shared
    @State private var editing = false
    @State private var keyText = ""
    @State private var message = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Picker("", selection: $provider) {
                    ForEach(AIProvider.allCases) { Text($0.shortName).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 170)
                if planner.hasKey(provider) {
                    Label("Key saved", systemImage: "key.fill").font(.caption).foregroundColor(.green)
                    Button("Change") { startEditing() }.controlSize(.small)
                } else if !editing {
                    Button("Add \(provider.shortName) API Key…") { startEditing() }.controlSize(.small)
                }
            }
            if editing {
                HStack(spacing: 6) {
                    SecureField(provider.keyPlaceholder, text: $keyText)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 280)
                        .onSubmit(save)
                    Button("Save", action: save).disabled(keyText.trimmed.isEmpty)
                    Button("Cancel") { editing = false; keyText = ""; message = "" }
                    Link("Get a key", destination: provider.keyPage).font(.caption)
                }
                Text("Stored in your Mac's Keychain and shared with School To-Do. \(provider.companyName) bills your account for what you use.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if !message.isEmpty { Text(message).font(.caption).foregroundColor(.orange) }
        }
        .onChange(of: provider) { _ in editing = false; keyText = ""; message = "" }
    }

    private func startEditing() {
        keyText = ""
        message = ""
        editing = true
    }

    private func save() {
        let key = keyText.trimmed
        guard !key.isEmpty else { return }
        if planner.setAPIKey(key, for: provider) {
            editing = false
            keyText = ""
            message = ""
        } else {
            message = "The Keychain didn't accept the key. Try again."
        }
    }
}
