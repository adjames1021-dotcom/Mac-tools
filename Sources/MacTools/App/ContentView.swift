import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appState: AppState
    @State private var search = ""

    private var sections: [(category: ToolCategory, tools: [ToolID])] {
        ToolCategory.allCases.compactMap { (category: ToolCategory) -> (category: ToolCategory, tools: [ToolID])? in
            let tools = ToolID.allCases.filter { $0.category == category && matches($0) }
            if tools.isEmpty { return nil }
            return (category: category, tools: tools)
        }
    }

    private func matches(_ tool: ToolID) -> Bool {
        if search.isEmpty { return true }
        return tool.title.localizedCaseInsensitiveContains(search)
            || tool.summary.localizedCaseInsensitiveContains(search)
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $appState.selection) {
                ForEach(sections, id: \.category) { section in
                    Section(section.category.rawValue) {
                        ForEach(section.tools) { tool in
                            Label(tool.title, systemImage: tool.icon)
                                .tag(tool)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .searchable(text: $search, placement: .sidebar, prompt: "Search tools")
            .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 320)
        } detail: {
            if let tool = appState.selection {
                tool.makeView()
                    .id(tool)
                    .navigationTitle(tool.title)
            } else {
                Text("Select a tool from the sidebar")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

struct HomeView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var permissions = Permissions.shared

    private let columns = [GridItem(.adaptive(minimum: 210), spacing: 12)]

    var body: some View {
        ToolPage(tool: .home) {
            if !permissions.accessibility || !permissions.inputMonitoring {
                PermissionBanner(needs: [.accessibility, .inputMonitoring])
            }
            HStack(spacing: 12) {
                QuickStat(title: "Tools", value: "\(ToolID.allCases.count - 2)", icon: "wrench.and.screwdriver")
                QuickStat(title: "Stop everything", value: HotKeyCenter.shared.displayString(for: .stopAll), icon: "stop.circle")
                QuickStat(title: "Record macro", value: HotKeyCenter.shared.displayString(for: .toggleMacroRecording), icon: "record.circle")
                QuickStat(title: "Auto clicker", value: HotKeyCenter.shared.displayString(for: .toggleAutoClicker), icon: "cursorarrow.click.2")
            }
            ForEach(ToolCategory.allCases.filter { $0 != .general }) { category in
                VStack(alignment: .leading, spacing: 8) {
                    Text(category.rawValue).font(.title3.bold())
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                        ForEach(ToolID.allCases.filter { $0.category == category }) { tool in
                            ToolCard(tool: tool) { appState.selection = tool }
                        }
                    }
                }
                .padding(.top, 6)
            }
        }
    }
}

private struct QuickStat: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.title2).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(value).font(.headline)
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }
}

private struct ToolCard: View {
    let tool: ToolID
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: tool.icon)
                    .font(.title2)
                    .frame(width: 32, height: 32)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text(tool.title).font(.headline)
                    Text(tool.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.primary.opacity(hovering ? 0.09 : 0.05))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
