import SwiftUI
import AppKit

struct MouseInspectorView: View {
    @State private var anchor: CGPoint?
    @State private var savedPoints: [CGPoint] = []

    var body: some View {
        ToolPage(tool: .mouseInspector) {
            TimelineView(.periodic(from: .now, by: 0.05)) { _ in
                let p = InputSynth.cursorLocation
                let cocoa = NSEvent.mouseLocation
                let screen = NSScreen.screens.first(where: { $0.frame.contains(cocoa) })
                VStack(alignment: .leading, spacing: 16) {
                    Card(title: "Cursor Position", icon: "cursorarrow") {
                        HStack(spacing: 30) {
                            bigValue("X", Int(p.x))
                            bigValue("Y", Int(p.y))
                            Spacer()
                            VStack(alignment: .trailing, spacing: 6) {
                                Button("Copy “x, y”") { ClipboardHelper.copy("\(Int(p.x)), \(Int(p.y))") }
                                PickPointButton(title: "Save Position") { pt in savedPoints.insert(pt, at: 0) }
                            }
                        }
                        InfoRow(label: "Top-left origin (Quartz)", value: "\(Int(p.x)), \(Int(p.y))")
                        InfoRow(label: "Bottom-left origin (Cocoa)", value: "\(Int(cocoa.x)), \(Int(cocoa.y))")
                        if let screen = screen {
                            InfoRow(label: "Display", value: screen.localizedName)
                            InfoRow(label: "Display size", value: "\(Int(screen.frame.width)) × \(Int(screen.frame.height)) pt @\(Int(screen.backingScaleFactor))x")
                            InfoRow(label: "Position on display", value: "\(Int(cocoa.x - screen.frame.minX)), \(Int(screen.frame.maxY - cocoa.y))")
                        }
                    }

                    Card(title: "Screen Ruler", icon: "ruler") {
                        HStack {
                            PickPointButton(title: anchor == nil ? "Set Start Point" : "Move Start Point") { pt in anchor = pt }
                            if anchor != nil {
                                Button("Clear") { anchor = nil }
                            }
                        }
                        if let a = anchor {
                            let dx = p.x - a.x
                            let dy = p.y - a.y
                            HStack(spacing: 30) {
                                bigValue("Width", Int(abs(dx)))
                                bigValue("Height", Int(abs(dy)))
                                bigValue("Distance", Int((dx * dx + dy * dy).squareRoot()))
                            }
                            Text("From (\(Int(a.x)), \(Int(a.y))) to the current pointer. Angle: \(String(format: "%.1f", atan2(-dy, dx) * 180 / .pi))°")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Set a start point, then move the mouse to measure distances on screen in points.")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if !savedPoints.isEmpty {
                Card(title: "Saved Positions", icon: "mappin.and.ellipse") {
                    ForEach(Array(savedPoints.enumerated()), id: \.offset) { item in
                        HStack {
                            Text("(\(Int(item.element.x)), \(Int(item.element.y)))")
                                .font(.system(.body, design: .monospaced))
                            Spacer()
                            CopyButton(text: "\(Int(item.element.x)), \(Int(item.element.y))")
                        }
                    }
                    Button("Clear") { savedPoints = [] }
                }
            }

            Card(title: "Displays", icon: "display.2") {
                ForEach(Array(NSScreen.screens.enumerated()), id: \.offset) { item in
                    let s = item.element
                    InfoRow(label: s.localizedName + (item.offset == 0 ? " (main)" : ""),
                            value: "\(Int(s.frame.width))×\(Int(s.frame.height)) pt, \(Int(s.frame.width * s.backingScaleFactor))×\(Int(s.frame.height * s.backingScaleFactor)) px, origin \(Int(s.frame.minX)),\(Int(s.frame.minY))")
                }
            }
        }
    }

    private func bigValue(_ label: String, _ value: Int) -> some View {
        VStack(alignment: .leading) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text("\(value)")
                .font(.system(size: 36, weight: .medium, design: .rounded))
                .monospacedDigit()
        }
    }
}
