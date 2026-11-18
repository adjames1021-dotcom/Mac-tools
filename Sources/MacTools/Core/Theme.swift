import SwiftUI
import AppKit

/// App-wide color themes. Names are one word.
enum AppTheme: String, Codable, CaseIterable, Identifiable {
    case classic, ocean, forest, sunset, grape, candy, midnight, graphite, frost, cocoa

    var id: String { rawValue }
    var name: String { rawValue.capitalized }

    private static func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color { Color(red: r, green: g, blue: b) }

    /// The theme's accent, or nil to use the Mac's own accent color.
    var accentOverride: Color? {
        switch self {
        case .classic: return nil
        case .ocean: return Self.rgb(0.00, 0.47, 0.75)
        case .forest: return Self.rgb(0.16, 0.52, 0.30)
        case .sunset: return Self.rgb(0.93, 0.42, 0.20)
        case .grape: return Self.rgb(0.52, 0.29, 0.78)
        case .candy: return Self.rgb(0.93, 0.36, 0.62)
        case .midnight: return Self.rgb(0.38, 0.45, 0.95)
        case .graphite: return Self.rgb(0.45, 0.47, 0.50)
        case .frost: return Self.rgb(0.33, 0.64, 0.86)
        case .cocoa: return Self.rgb(0.55, 0.36, 0.24)
        }
    }

    var accent: Color { accentOverride ?? .accentColor }

    /// Colors handed out to things like class names, so each one keeps its own color.
    var palette: [Color] {
        let r = Self.rgb
        switch self {
        case .classic: return [.blue, .purple, .pink, .orange, .green, .teal, .indigo, .red]
        case .ocean: return [r(0.00, 0.47, 0.75), r(0.00, 0.62, 0.66), r(0.16, 0.35, 0.60), r(0.30, 0.69, 0.85),
                             r(0.00, 0.55, 0.50), r(0.42, 0.50, 0.85), r(0.20, 0.75, 0.75), r(0.10, 0.30, 0.45)]
        case .forest: return [r(0.16, 0.52, 0.30), r(0.45, 0.62, 0.20), r(0.55, 0.40, 0.22), r(0.20, 0.45, 0.45),
                              r(0.62, 0.55, 0.18), r(0.30, 0.65, 0.42), r(0.40, 0.30, 0.20), r(0.10, 0.38, 0.25)]
        case .sunset: return [r(0.93, 0.42, 0.20), r(0.90, 0.25, 0.35), r(0.75, 0.25, 0.55), r(0.97, 0.65, 0.20),
                              r(0.55, 0.25, 0.60), r(0.98, 0.50, 0.45), r(0.80, 0.35, 0.15), r(0.95, 0.75, 0.35)]
        case .grape: return [r(0.52, 0.29, 0.78), r(0.70, 0.30, 0.70), r(0.36, 0.25, 0.65), r(0.80, 0.45, 0.85),
                             r(0.45, 0.40, 0.90), r(0.62, 0.20, 0.50), r(0.58, 0.50, 0.85), r(0.30, 0.15, 0.50)]
        case .candy: return [r(0.93, 0.36, 0.62), r(0.98, 0.55, 0.40), r(0.55, 0.45, 0.95), r(0.30, 0.75, 0.80),
                             r(0.98, 0.75, 0.30), r(0.75, 0.40, 0.90), r(0.40, 0.80, 0.55), r(0.95, 0.45, 0.45)]
        case .midnight: return [r(0.38, 0.45, 0.95), r(0.55, 0.40, 0.90), r(0.25, 0.60, 0.90), r(0.70, 0.50, 0.95),
                                r(0.30, 0.75, 0.85), r(0.50, 0.55, 0.75), r(0.80, 0.45, 0.75), r(0.35, 0.40, 0.65)]
        case .graphite: return [r(0.45, 0.47, 0.50), r(0.35, 0.40, 0.48), r(0.55, 0.55, 0.55), r(0.40, 0.45, 0.42),
                                r(0.60, 0.58, 0.52), r(0.30, 0.32, 0.36), r(0.50, 0.45, 0.48), r(0.65, 0.66, 0.70)]
        case .frost: return [r(0.33, 0.64, 0.86), r(0.55, 0.75, 0.90), r(0.40, 0.55, 0.75), r(0.25, 0.75, 0.85),
                             r(0.60, 0.65, 0.85), r(0.35, 0.80, 0.75), r(0.50, 0.60, 0.70), r(0.20, 0.50, 0.70)]
        case .cocoa: return [r(0.55, 0.36, 0.24), r(0.75, 0.50, 0.30), r(0.45, 0.30, 0.25), r(0.80, 0.62, 0.40),
                             r(0.60, 0.40, 0.40), r(0.40, 0.45, 0.30), r(0.70, 0.45, 0.20), r(0.35, 0.25, 0.20)]
        }
    }
}

enum AppAppearance: String, Codable, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var name: String {
        switch self {
        case .system: return "Auto"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

struct ThemeSettings: Codable, Equatable {
    var theme = AppTheme.classic
    var appearance = AppAppearance.system
    /// Tint the background of every tool page with the theme color.
    var tintBackground = true

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ThemeSettings()
        theme = (try? c.decodeIfPresent(AppTheme.self, forKey: .theme)) ?? d.theme
        appearance = (try? c.decodeIfPresent(AppAppearance.self, forKey: .appearance)) ?? d.appearance
        tintBackground = (try? c.decodeIfPresent(Bool.self, forKey: .tintBackground)) ?? d.tintBackground
    }
}

/// The current theme for all of MacTools.
final class ThemeManager: ObservableObject {
    static let shared = ThemeManager()
    private static let key = "appTheme"

    @Published var settings: ThemeSettings {
        didSet {
            guard settings != oldValue else { return }
            Prefs.save(Self.key, settings)
            if settings.appearance != oldValue.appearance { applyAppearance() }
        }
    }

    private init() {
        settings = Prefs.load(Self.key, default: ThemeSettings())
    }

    func start() { applyAppearance() }

    var theme: AppTheme { settings.theme }

    /// The accent in use: Christmas red when Christmas colors are on, otherwise the theme's (nil = the Mac's).
    var accentOverride: Color? {
        ChristmasManager.shared.showColors ? ChristmasManager.red : settings.theme.accentOverride
    }

    var accent: Color { accentOverride ?? .accentColor }

    var palette: [Color] { ChristmasManager.shared.showColors ? ChristmasManager.palette : settings.theme.palette }

    private func applyAppearance() {
        switch settings.appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    /// A stable color for a name (the same class always gets the same color).
    func color(for name: String) -> Color {
        let palette = self.palette
        var hash: UInt64 = 5381
        for byte in name.lowercased().utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        return palette[Int(hash % UInt64(palette.count))]
    }
}

/// Applies the theme's accent color to everything inside (buttons, toggles, Color.accentColor…).
struct ThemedRoot: ViewModifier {
    @ObservedObject private var themes = ThemeManager.shared
    @ObservedObject private var christmas = ChristmasManager.shared

    func body(content: Content) -> some View {
        content
            .accentColor(themes.accentOverride)
            .tint(themes.accentOverride)
    }
}

/// A soft wash of the theme color behind tool pages.
struct ThemeBackdrop: View {
    @ObservedObject private var themes = ThemeManager.shared
    @ObservedObject private var christmas = ChristmasManager.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if christmas.showColors {
            LinearGradient(colors: [ChristmasManager.red.opacity(scheme == .dark ? 0.16 : 0.09),
                                    ChristmasManager.green.opacity(scheme == .dark ? 0.14 : 0.08)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
        } else if let accent = themes.theme.accentOverride, themes.settings.tintBackground {
            LinearGradient(colors: [accent.opacity(scheme == .dark ? 0.16 : 0.10), accent.opacity(0.02)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
        } else {
            Color.clear
        }
    }
}

extension View {
    func themedRoot() -> some View { modifier(ThemedRoot()) }
}

// MARK: - Themes page

struct ThemesView: View {
    @ObservedObject private var themes = ThemeManager.shared
    private let columns = [GridItem(.adaptive(minimum: 128), spacing: 12)]

    var body: some View {
        ToolPage(tool: .themes) {
            Card(title: "Theme", icon: "paintpalette") {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                    ForEach(AppTheme.allCases) { theme in
                        ThemeSwatch(theme: theme, selected: themes.settings.theme == theme) {
                            themes.settings.theme = theme
                        }
                    }
                }
                Toggle("Tint tool backgrounds with the theme color", isOn: $themes.settings.tintBackground)
                    .disabled(themes.theme == .classic)
            }
            Card(title: "Appearance", icon: "circle.lefthalf.filled") {
                Picker("", selection: $themes.settings.appearance) {
                    ForEach(AppAppearance.allCases) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 300)
                Text("Auto follows your Mac's Light or Dark setting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Card(title: "Preview", icon: "eye") {
                HStack(spacing: 12) {
                    Button("Button") {}
                        .buttonStyle(.borderedProminent)
                    Toggle("Toggle", isOn: .constant(true))
                    ProgressView(value: 0.6).frame(width: 140)
                    ForEach(0..<5, id: \.self) { index in
                        Circle().fill(themes.theme.palette[index]).frame(width: 16, height: 16)
                    }
                }
            }
        }
    }
}

private struct ThemeSwatch: View {
    let theme: AppTheme
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 3) {
                    ForEach(0..<4, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(index == 0 ? theme.accent : theme.palette[index])
                            .frame(height: 22)
                    }
                }
                Text(theme.name).font(.callout.weight(.medium))
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? theme.accent : Color.primary.opacity(0.1),
                                                              lineWidth: selected ? 2.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Removes the thin separator macOS draws under the title bar (it otherwise shows as a line across the
/// traffic-light buttons when a page scrolls).
struct WindowChromeFix: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        apply(view)
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) { apply(nsView) }

    private func apply(_ view: NSView) {
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            window.titlebarSeparatorStyle = .none
        }
    }
}
