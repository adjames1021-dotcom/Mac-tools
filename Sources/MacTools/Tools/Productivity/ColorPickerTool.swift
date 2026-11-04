import SwiftUI
import AppKit

private enum ColorSamplerHolder {
    static let sampler = NSColorSampler()
}

struct RGBColor: Equatable {
    var r: Double   // 0…1
    var g: Double
    var b: Double
    var a: Double = 1

    init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = min(max(r, 0), 1)
        self.g = min(max(g, 0), 1)
        self.b = min(max(b, 0), 1)
        self.a = min(max(a, 0), 1)
    }

    init?(nsColor: NSColor) {
        guard let c = nsColor.usingColorSpace(.sRGB) else { return nil }
        self.init(r: Double(c.redComponent), g: Double(c.greenComponent), b: Double(c.blueComponent), a: Double(c.alphaComponent))
    }

    init?(hex: String) {
        var s = hex.trimmed.uppercased()
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6 || s.count == 8, let value = UInt64(s, radix: 16) else { return nil }
        if s.count == 6 {
            self.init(r: Double((value >> 16) & 0xFF) / 255, g: Double((value >> 8) & 0xFF) / 255, b: Double(value & 0xFF) / 255)
        } else {
            self.init(r: Double((value >> 24) & 0xFF) / 255, g: Double((value >> 16) & 0xFF) / 255,
                      b: Double((value >> 8) & 0xFF) / 255, a: Double(value & 0xFF) / 255)
        }
    }

    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
    var color: Color { Color(nsColor: nsColor) }

    var r255: Int { Int((r * 255).rounded()) }
    var g255: Int { Int((g * 255).rounded()) }
    var b255: Int { Int((b * 255).rounded()) }

    var hex: String { String(format: "#%02X%02X%02X", r255, g255, b255) }

    var hsl: (h: Double, s: Double, l: Double) {
        let maxV = max(r, g, b), minV = min(r, g, b)
        let l = (maxV + minV) / 2
        guard maxV != minV else { return (0, 0, l) }
        let d = maxV - minV
        let s = l > 0.5 ? d / (2 - maxV - minV) : d / (maxV + minV)
        var h: Double
        if maxV == r {
            h = (g - b) / d + (g < b ? 6 : 0)
        } else if maxV == g {
            h = (b - r) / d + 2
        } else {
            h = (r - g) / d + 4
        }
        h /= 6
        return (h * 360, s, l)
    }

    var hsb: (h: Double, s: Double, b: Double) {
        let maxV = max(r, g, b), minV = min(r, g, b)
        let d = maxV - minV
        let s = maxV == 0 ? 0 : d / maxV
        guard d != 0 else { return (0, s, maxV) }
        var h: Double
        if maxV == r {
            h = (g - b) / d + (g < b ? 6 : 0)
        } else if maxV == g {
            h = (b - r) / d + 2
        } else {
            h = (r - g) / d + 4
        }
        return (h / 6 * 360, s, maxV)
    }

    var cmyk: (c: Double, m: Double, y: Double, k: Double) {
        let k = 1 - max(r, g, b)
        guard k < 1 else { return (0, 0, 0, 1) }
        return ((1 - r - k) / (1 - k), (1 - g - k) / (1 - k), (1 - b - k) / (1 - k), k)
    }

    /// Relative luminance for contrast calculations.
    var luminance: Double {
        func channel(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
    }

    func contrast(with other: RGBColor) -> Double {
        let l1 = max(luminance, other.luminance), l2 = min(luminance, other.luminance)
        return (l1 + 0.05) / (l2 + 0.05)
    }

    var formats: [(String, String)] {
        let hslV = hsl, hsbV = hsb, c = cmyk
        return [
            ("HEX", hex),
            ("RGB", "rgb(\(r255), \(g255), \(b255))"),
            ("RGBA", String(format: "rgba(%d, %d, %d, %.2f)", r255, g255, b255, a)),
            ("HSL", String(format: "hsl(%.0f, %.0f%%, %.0f%%)", hslV.h, hslV.s * 100, hslV.l * 100)),
            ("HSB / HSV", String(format: "hsb(%.0f, %.0f%%, %.0f%%)", hsbV.h, hsbV.s * 100, hsbV.b * 100)),
            ("CMYK", String(format: "cmyk(%.0f%%, %.0f%%, %.0f%%, %.0f%%)", c.c * 100, c.m * 100, c.y * 100, c.k * 100)),
            ("SwiftUI", String(format: "Color(red: %.3f, green: %.3f, blue: %.3f)", r, g, b)),
            ("NSColor", String(format: "NSColor(srgbRed: %.3f, green: %.3f, blue: %.3f, alpha: %.2f)", r, g, b, a)),
            ("UIColor", String(format: "UIColor(red: %.3f, green: %.3f, blue: %.3f, alpha: %.2f)", r, g, b, a)),
            ("CSS variable", "--color: \(hex.lowercased());")
        ]
    }
}

struct ColorPickerTool: View {
    @State private var current = RGBColor(hex: UserDefaults.standard.string(forKey: "colorPickerCurrent") ?? "#3B82F6") ?? RGBColor(r: 0.23, g: 0.51, b: 0.96)
    @State private var history: [String] = Prefs.load("colorHistory", default: [String]())
    @State private var hexInput = ""

    var body: some View {
        ToolPage(tool: .colorPicker) {
            Card(title: "Pick a Colour", icon: "eyedropper") {
                HStack(alignment: .top, spacing: 20) {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(current.color)
                        .frame(width: 150, height: 150)
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.2)))
                    VStack(alignment: .leading, spacing: 10) {
                        Button {
                            ColorSamplerHolder.sampler.show { picked in
                                if let picked = picked, let rgb = RGBColor(nsColor: picked) {
                                    set(rgb)
                                }
                            }
                        } label: {
                            Label("Pick from Screen", systemImage: "eyedropper.halffull")
                                .frame(minWidth: 160)
                        }
                        .controlSize(.large)
                        .buttonStyle(.borderedProminent)
                        ColorPicker("Colour wheel", selection: Binding(
                            get: { current.color },
                            set: { newColor in
                                if let rgb = RGBColor(nsColor: NSColor(newColor)) { set(rgb, addToHistory: false) }
                            }), supportsOpacity: true)
                        HStack {
                            TextField("#RRGGBB", text: $hexInput)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 120)
                                .onSubmit { applyHex() }
                            Button("Use HEX") { applyHex() }
                        }
                        Text(String(format: "Contrast vs white %.1f:1 · vs black %.1f:1",
                                    current.contrast(with: RGBColor(r: 1, g: 1, b: 1)),
                                    current.contrast(with: RGBColor(r: 0, g: 0, b: 0))))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Card(title: "Formats", icon: "doc.on.doc") {
                ForEach(current.formats, id: \.0) { item in
                    HStack {
                        Text(item.0).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
                        Text(item.1)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                        Spacer()
                        CopyButton(text: item.1)
                    }
                }
            }

            Card(title: "Shades & Tints", icon: "circle.lefthalf.filled") {
                HStack(spacing: 4) {
                    ForEach(-4...4, id: \.self) { step in
                        let shade = adjust(current, by: Double(step) * 0.1)
                        Button {
                            set(shade)
                        } label: {
                            VStack(spacing: 4) {
                                RoundedRectangle(cornerRadius: 6).fill(shade.color).frame(height: 40)
                                Text(shade.hex).font(.system(size: 9, design: .monospaced))
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if !history.isEmpty {
                Card(title: "History", icon: "clock.arrow.circlepath") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 70), spacing: 8)], spacing: 8) {
                        ForEach(history, id: \.self) { hex in
                            if let rgb = RGBColor(hex: hex) {
                                Button {
                                    set(rgb, addToHistory: false)
                                } label: {
                                    VStack(spacing: 3) {
                                        RoundedRectangle(cornerRadius: 6).fill(rgb.color).frame(height: 34)
                                        Text(hex).font(.system(size: 10, design: .monospaced))
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    Button("Clear History") {
                        history = []
                        Prefs.save("colorHistory", history)
                    }
                }
            }
        }
    }

    private func set(_ color: RGBColor, addToHistory: Bool = true) {
        current = color
        hexInput = color.hex
        UserDefaults.standard.set(color.hex, forKey: "colorPickerCurrent")
        if addToHistory {
            history.removeAll { $0 == color.hex }
            history.insert(color.hex, at: 0)
            if history.count > 40 { history.removeLast(history.count - 40) }
            Prefs.save("colorHistory", history)
            ClipboardHelper.copy(color.hex)
        }
    }

    private func applyHex() {
        if let rgb = RGBColor(hex: hexInput) { set(rgb) } else { NSSound.beep() }
    }

    private func adjust(_ c: RGBColor, by amount: Double) -> RGBColor {
        if amount >= 0 {
            return RGBColor(r: c.r + (1 - c.r) * amount * 2, g: c.g + (1 - c.g) * amount * 2, b: c.b + (1 - c.b) * amount * 2)
        }
        let f = 1 + amount * 2
        return RGBColor(r: c.r * f, g: c.g * f, b: c.b * f)
    }
}
