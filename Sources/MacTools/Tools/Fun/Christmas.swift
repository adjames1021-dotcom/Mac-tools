import SwiftUI
import AppKit
import AVFoundation

// MARK: - Settings

enum SnowAmount: String, Codable, CaseIterable, Identifiable {
    case flurries, snowfall, blizzard

    var id: String { rawValue }
    var name: String { rawValue.capitalized }

    var flakes: Int {
        switch self {
        case .flurries: return 45
        case .snowfall: return 110
        case .blizzard: return 240
        }
    }
}

struct ChristmasSettings: Codable, Equatable {
    var snow = false
    var snowAmount = SnowAmount.snowfall
    var lights = false
    var colors = false
    var countdown = false
    var menuBarIcon = false
    var menuBarCountdown = false
    var toolIcons = false
    var jingles = false
    var ornaments = false
    /// Only show decorations from December 1st to 26th.
    var onlyInSeason = false

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ChristmasSettings()
        snow = (try? c.decodeIfPresent(Bool.self, forKey: .snow)) ?? d.snow
        snowAmount = (try? c.decodeIfPresent(SnowAmount.self, forKey: .snowAmount)) ?? d.snowAmount
        lights = (try? c.decodeIfPresent(Bool.self, forKey: .lights)) ?? d.lights
        colors = (try? c.decodeIfPresent(Bool.self, forKey: .colors)) ?? d.colors
        countdown = (try? c.decodeIfPresent(Bool.self, forKey: .countdown)) ?? d.countdown
        menuBarIcon = (try? c.decodeIfPresent(Bool.self, forKey: .menuBarIcon)) ?? d.menuBarIcon
        menuBarCountdown = (try? c.decodeIfPresent(Bool.self, forKey: .menuBarCountdown)) ?? d.menuBarCountdown
        toolIcons = (try? c.decodeIfPresent(Bool.self, forKey: .toolIcons)) ?? d.toolIcons
        jingles = (try? c.decodeIfPresent(Bool.self, forKey: .jingles)) ?? d.jingles
        ornaments = (try? c.decodeIfPresent(Bool.self, forKey: .ornaments)) ?? d.ornaments
        onlyInSeason = (try? c.decodeIfPresent(Bool.self, forKey: .onlyInSeason)) ?? d.onlyInSeason
    }
}

/// Christmas decorations for all of MacTools. Each one is its own switch on the Christmas page.
final class ChristmasManager: ObservableObject {
    static let shared = ChristmasManager()
    private static let key = "christmas"

    static let red = Color(red: 0.80, green: 0.10, blue: 0.15)
    static let green = Color(red: 0.10, green: 0.55, blue: 0.25)
    static let gold = Color(red: 0.95, green: 0.75, blue: 0.20)
    static let palette: [Color] = [red, green, gold, Color(red: 0.55, green: 0.10, blue: 0.12),
                                   Color(red: 0.20, green: 0.40, blue: 0.25), Color(red: 0.85, green: 0.40, blue: 0.30),
                                   Color(red: 0.30, green: 0.65, blue: 0.45), Color(red: 0.70, green: 0.55, blue: 0.25)]

    @Published var settings: ChristmasSettings {
        didSet { if settings != oldValue { Prefs.save(Self.key, settings) } }
    }

    private init() {
        settings = Prefs.load(Self.key, default: ChristmasSettings())
    }

    /// True unless decorations are limited to the season and it isn't December 1–26.
    var inSeason: Bool {
        guard settings.onlyInSeason else { return true }
        let parts = Calendar.current.dateComponents([.month, .day], from: Date())
        return parts.month == 12 && (parts.day ?? 0) <= 26
    }

    var showSnow: Bool { settings.snow && inSeason }
    var showLights: Bool { settings.lights && inSeason }
    var showColors: Bool { settings.colors && inSeason }
    var showCountdown: Bool { settings.countdown && inSeason }
    var showToolIcons: Bool { settings.toolIcons && inSeason }
    var showOrnaments: Bool { settings.ornaments && inSeason }
    var playJingles: Bool { settings.jingles && inSeason }
    var menuBarSymbol: String? { settings.menuBarIcon && inSeason ? "snowflake" : nil }
    var menuBarDays: Int? { settings.menuBarCountdown && inSeason ? Self.daysUntilChristmas() : nil }

    var anythingOn: Bool {
        let s = settings
        return s.snow || s.lights || s.colors || s.countdown || s.menuBarIcon || s.menuBarCountdown || s.toolIcons || s.jingles || s.ornaments
    }

    func setAll(_ on: Bool) {
        var s = settings
        s.snow = on
        s.lights = on
        s.colors = on
        s.countdown = on
        s.menuBarIcon = on
        s.menuBarCountdown = on
        s.toolIcons = on
        s.jingles = on
        s.ornaments = on
        settings = s
    }

    /// The next Christmas Day (today, if it's Christmas).
    static func nextChristmas(from now: Date = Date()) -> Date {
        let cal = Calendar.current
        let year = cal.component(.year, from: now)
        let thisYear = cal.date(from: DateComponents(year: year, month: 12, day: 25)) ?? now
        if cal.isDate(now, inSameDayAs: thisYear) || now < thisYear { return thisYear }
        return cal.date(from: DateComponents(year: year + 1, month: 12, day: 25)) ?? now
    }

    static func daysUntilChristmas(from now: Date = Date()) -> Int {
        let cal = Calendar.current
        return cal.dateComponents([.day], from: cal.startOfDay(for: now), to: nextChristmas(from: now)).day ?? 0
    }

    static var countdownText: String {
        let days = daysUntilChristmas()
        switch days {
        case 0: return "Merry Christmas!"
        case 1: return "Christmas is tomorrow!"
        default: return "\(days) days until Christmas"
        }
    }
}

// MARK: - Decorations

/// Falling snow drawn over the whole window. Clicks go straight through it.
struct Snowfall: View {
    let amount: SnowAmount
    @Environment(\.colorScheme) private var scheme

    private struct Flake {
        let x: Double, size: Double, speed: Double, drift: Double, phase: Double, opacity: Double
    }

    private var flakes: [Flake] {
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func next() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11) / Double(1 << 53)
        }
        return (0..<amount.flakes).map { _ in
            Flake(x: next(), size: 2 + next() * 4, speed: 25 + next() * 55, drift: 6 + next() * 18,
                  phase: next(), opacity: 0.55 + next() * 0.45)
        }
    }

    var body: some View {
        let flakes = self.flakes
        let color = scheme == .dark ? Color.white : Color(red: 0.62, green: 0.75, blue: 0.92)
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { context in
            Canvas { gc, size in
                let t = context.date.timeIntervalSinceReferenceDate
                let fall = size.height + 20
                for flake in flakes {
                    let y = (t * flake.speed + flake.phase * fall).truncatingRemainder(dividingBy: fall) - 10
                    let x = flake.x * size.width + sin(t * 0.8 + flake.phase * 6.28) * flake.drift
                    let rect = CGRect(x: x, y: y, width: flake.size, height: flake.size)
                    gc.fill(Path(ellipseIn: rect), with: .color(color.opacity(flake.opacity)))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// A string of blinking colored bulbs.
struct ChristmasLights: View {
    private let colors: [Color] = [ChristmasManager.red, ChristmasManager.green, ChristmasManager.gold,
                                   Color(red: 0.25, green: 0.50, blue: 0.95)]

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 0.7)) { context in
            let tick = Int(context.date.timeIntervalSinceReferenceDate / 0.7)
            Canvas { gc, size in
                let spacing: CGFloat = 34
                let count = max(2, Int(size.width / spacing) + 1)
                var wire = Path()
                wire.move(to: CGPoint(x: 0, y: 3))
                for index in 0..<count {
                    let x0 = CGFloat(index) * spacing
                    wire.addQuadCurve(to: CGPoint(x: x0 + spacing, y: 3), control: CGPoint(x: x0 + spacing / 2, y: 13))
                }
                gc.stroke(wire, with: .color(Color(red: 0.15, green: 0.30, blue: 0.15)), lineWidth: 1.5)
                for index in 0..<count {
                    let x = CGFloat(index) * spacing + spacing / 2
                    let y: CGFloat = 8
                    let color = colors[index % colors.count]
                    let lit = (index + tick) % 3 != 0
                    if lit {
                        gc.fill(Path(ellipseIn: CGRect(x: x - 9, y: y - 1, width: 18, height: 22)), with: .color(color.opacity(0.28)))
                    }
                    gc.fill(Path(roundedRect: CGRect(x: x - 2.5, y: y, width: 5, height: 4), cornerRadius: 1), with: .color(.gray))
                    gc.fill(Path(ellipseIn: CGRect(x: x - 4.5, y: y + 3, width: 9, height: 13)),
                            with: .color(lit ? color : color.opacity(0.35)))
                }
            }
        }
        .frame(height: 28)
        .allowsHitTesting(false)
    }
}

/// Snow over the whole window, when it's switched on.
struct SnowOverlay: View {
    @ObservedObject private var christmas = ChristmasManager.shared

    var body: some View {
        if christmas.showSnow {
            Snowfall(amount: christmas.settings.snowAmount)
        }
    }
}

/// Lights along the top of a tool page, when they're switched on.
struct LightsOverlay: View {
    @ObservedObject private var christmas = ChristmasManager.shared

    var body: some View {
        if christmas.showLights {
            ChristmasLights()
        }
    }
}

/// A little snowflake on tool icons, when festive icons are on.
struct FestiveBadge: View {
    @ObservedObject private var christmas = ChristmasManager.shared

    var body: some View {
        if christmas.showToolIcons {
            Image(systemName: "snowflake")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.white)
                .padding(3)
                .background(Circle().fill(ChristmasManager.red))
                .offset(x: 5, y: -5)
        }
    }
}

/// The menu bar icon: the usual wrench, or a snowflake and the days until Christmas.
struct MenuBarLabel: View {
    @ObservedObject private var christmas = ChristmasManager.shared

    var body: some View {
        if let days = christmas.menuBarDays {
            // One Text with the icon inside, which the menu bar shows reliably.
            Text("\(Image(systemName: christmas.menuBarSymbol ?? "wrench.and.screwdriver")) \(days == 0 ? "🎄" : String(days))")
        } else {
            Image(systemName: christmas.menuBarSymbol ?? "wrench.and.screwdriver")
        }
    }
}

// MARK: - Jingle bells

/// Plays short sleigh-bell tunes (synthesized, no sound files needed).
final class Jingle {
    static let shared = Jingle()

    private var engine: AVAudioEngine?
    private var token = 0

    /// E E E, E E E, E G C D E
    static let chorus: [(Double, Double)] = [
        (659.25, 1), (659.25, 1), (659.25, 2), (659.25, 1), (659.25, 1), (659.25, 2),
        (659.25, 1), (783.99, 1), (523.25, 1.5), (587.33, 0.5), (659.25, 3),
    ]
    static let ding: [(Double, Double)] = [(1318.5, 0.6), (1567.98, 1.5)]

    /// Plays only when jingle sounds are switched on.
    func playIfOn(_ notes: [(Double, Double)]) {
        if ChristmasManager.shared.playJingles { play(notes) }
    }

    /// (frequency in Hz, length in beats)
    func play(_ notes: [(Double, Double)]) {
        let sampleRate = 44_100.0
        let beat = 0.18
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return }
        let seconds = notes.reduce(0.0) { $0 + $1.1 } * beat + 0.9
        let frames = AVAudioFrameCount(seconds * sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let samples = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = frames
        let total = Int(frames)
        for i in 0..<total { samples[i] = 0 }
        var start = 0.0
        for (frequency, beats) in notes {
            let begin = Int(start * sampleRate)
            let length = Int(min(1.4, beats * beat + 0.6) * sampleRate)
            for n in 0..<length where begin + n < total {
                let t = Double(n) / sampleRate
                // A bell: a decaying tone plus quickly fading inharmonic overtones.
                let tone = sin(2 * .pi * frequency * t) * exp(-t * 4.5)
                    + 0.35 * sin(2 * .pi * frequency * 2.76 * t) * exp(-t * 9)
                    + 0.15 * sin(2 * .pi * frequency * 5.40 * t) * exp(-t * 15)
                samples[begin + n] += Float(tone * 0.18)
            }
            start += beats * beat
        }
        engine?.stop()
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        do { try engine.start() } catch { return }
        player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
        player.play()
        self.engine = engine
        token += 1
        let current = token
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds + 0.3) { [weak self] in
            guard let self = self, self.token == current else { return }
            self.engine?.stop()
            self.engine = nil
        }
    }
}

// MARK: - Christmas page

struct ChristmasView: View {
    @ObservedObject private var christmas = ChristmasManager.shared

    var body: some View {
        ToolPage(tool: .christmas) {
            countdownCard
            Card(title: "Decorations", icon: "snowflake") {
                Toggle("Falling snow", isOn: $christmas.settings.snow)
                if christmas.settings.snow {
                    Picker("", selection: $christmas.settings.snowAmount) {
                        ForEach(SnowAmount.allCases) { Text($0.name).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 320)
                    .padding(.leading, 20)
                }
                Toggle("Twinkling lights along the top of every page", isOn: $christmas.settings.lights)
                Toggle("Red and green Christmas colors (instead of your theme)", isOn: $christmas.settings.colors)
                Toggle("Snowflakes on tool icons", isOn: $christmas.settings.toolIcons)
            }
            Card(title: "Countdown", icon: "calendar") {
                Toggle("Show the Christmas countdown on the Home page", isOn: $christmas.settings.countdown)
                Toggle("Snowflake menu bar icon", isOn: $christmas.settings.menuBarIcon)
                Toggle("Days until Christmas in the menu bar", isOn: $christmas.settings.menuBarCountdown)
            }
            Card(title: "Sounds & School To-Do", icon: "bell") {
                HStack {
                    Toggle("Jingle bells when you check something off or a sync finishes", isOn: $christmas.settings.jingles)
                    Spacer()
                    Button("Ring") { Jingle.shared.play(Jingle.chorus) }
                }
                Toggle("Ornament check-offs in School To-Do", isOn: $christmas.settings.ornaments)
                HStack {
                    Button {
                        SpotifyPlayer.shared.show(search: "Christmas")
                    } label: {
                        Label("Christmas Music", systemImage: "music.note")
                    }
                    Text("Opens Christmas playlists in the built-in Spotify player.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Card(title: "When", icon: "clock") {
                Toggle("Only from December 1st to 26th", isOn: $christmas.settings.onlyInSeason)
                Text("Leave everything switched on and the decorations appear by themselves each December.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Turn Everything On") { christmas.setAll(true) }
                    Button("Turn Everything Off") { christmas.setAll(false) }
                        .disabled(!christmas.anythingOn)
                }
            }
        }
    }

    private var countdownCard: some View {
        TimelineView(.periodic(from: Date(), by: 1)) { context in
            let target = ChristmasManager.nextChristmas(from: context.date)
            let remaining = max(0, target.timeIntervalSince(context.date))
            let days = ChristmasManager.daysUntilChristmas(from: context.date)
            HStack(spacing: 16) {
                Text("🎄").font(.system(size: 54))
                VStack(alignment: .leading, spacing: 4) {
                    Text(days == 0 ? "Merry Christmas!" : "\(days) day\(days == 1 ? "" : "s") until Christmas")
                        .font(.title.bold())
                    if days > 0 {
                        let hours = Int(remaining) / 3600 % 24
                        let minutes = Int(remaining) / 60 % 60
                        let seconds = Int(remaining) % 60
                        Text(String(format: "%d days, %02d:%02d:%02d", Int(remaining) / 86400, hours, minutes, seconds))
                            .font(.system(.title3, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(LinearGradient(colors: [ChristmasManager.red.opacity(0.18), ChristmasManager.green.opacity(0.18)],
                                         startPoint: .leading, endPoint: .trailing))
            )
        }
    }
}
