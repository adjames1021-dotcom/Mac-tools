import SwiftUI
import AppKit

// MARK: - Calculator

struct CalcEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var expression: String
    var result: String
}

struct CalculatorView: View {
    @State private var expression = ""
    @State private var preview = ""
    @State private var history: [CalcEntry] = Prefs.load("calcHistory", default: [CalcEntry]())
    @AppStorage("calcDegrees") private var useDegrees = true
    @State private var lastAnswer: Double = 0

    private let keypad: [[String]] = [
        ["(", ")", "%", "⌫", "C"],
        ["sin(", "cos(", "tan(", "^", "÷"],
        ["7", "8", "9", "√(", "×"],
        ["4", "5", "6", "ln(", "−"],
        ["1", "2", "3", "π", "+"],
        ["0", ".", "ans", "!", "="]
    ]

    var body: some View {
        ToolPage(tool: .calculator) {
            Card(title: "Expression", icon: "function") {
                TextField("e.g. (12 + 7) * 3^2 / sqrt(16)", text: $expression)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 22, design: .monospaced))
                    .onSubmit(evaluate)
                    .onChange(of: expression) { _ in updatePreview() }
                HStack {
                    Text(preview.isEmpty ? " " : preview)
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .textSelection(.enabled)
                    Spacer()
                    Picker("", selection: $useDegrees) {
                        Text("Degrees").tag(true)
                        Text("Radians").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 180)
                    CopyButton(text: preview.hasPrefix("= ") ? String(preview.dropFirst(2)) : "")
                }
                Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                    ForEach(keypad, id: \.self) { row in
                        GridRow {
                            ForEach(row, id: \.self) { key in
                                Button {
                                    press(key)
                                } label: {
                                    Text(key == "√(" ? "√" : (key.hasSuffix("(") && key.count > 1 ? String(key.dropLast()) : key))
                                        .font(.system(size: 17, weight: .medium))
                                        .frame(maxWidth: .infinity, minHeight: 34)
                                }
                                .buttonStyle(TileButtonStyle(selected: key == "="))
                            }
                        }
                    }
                }
                .frame(maxWidth: 520)
                Text("Functions: sqrt cbrt abs sin cos tan asin acos atan ln log log2 exp floor ceil round min max avg sum pow hypot rand · constants: pi e tau phi ans · hex 0xFF, binary 0b101")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Card(title: "History", icon: "clock") {
                if history.isEmpty {
                    Text("Press Return or = to add results here.").foregroundStyle(.secondary)
                }
                ForEach(history) { entry in
                    HStack {
                        Text(entry.expression)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(entry.result)
                            .font(.system(.body, design: .monospaced))
                            .bold()
                            .textSelection(.enabled)
                        Button("Use") { expression = entry.result }
                            .buttonStyle(.borderless)
                    }
                }
                if !history.isEmpty {
                    Button("Clear History") {
                        history = []
                        Prefs.save("calcHistory", history)
                    }
                }
            }
        }
    }

    private func press(_ key: String) {
        switch key {
        case "C": expression = ""
        case "⌫": if !expression.isEmpty { expression.removeLast() }
        case "=": evaluate()
        case "√(": expression += "sqrt("
        default: expression += key
        }
    }

    private func compute() throws -> Double {
        try ExpressionParser.evaluate(expression, useDegrees: useDegrees, variables: ["ans": lastAnswer])
    }

    private func updatePreview() {
        guard !expression.trimmed.isEmpty else {
            preview = ""
            return
        }
        if let value = try? compute() {
            preview = "= " + Format.number(value, maxFraction: 10)
        } else {
            preview = ""
        }
    }

    private func evaluate() {
        guard !expression.trimmed.isEmpty else { return }
        do {
            let value = try compute()
            let result = Format.number(value, maxFraction: 10)
            lastAnswer = value
            history.insert(CalcEntry(expression: expression, result: result), at: 0)
            if history.count > 100 { history.removeLast(history.count - 100) }
            Prefs.save("calcHistory", history)
            preview = "= " + result
            expression = result
        } catch {
            preview = "⚠️ " + error.localizedDescription
            NSSound.beep()
        }
    }
}

// MARK: - Unit converter

struct UnitCategory: Identifiable {
    let id: String
    let icon: String
    let units: [(String, Dimension)]
}

enum UnitCatalog {
    static let day = UnitDuration(symbol: "d", converter: UnitConverterLinear(coefficient: 86_400))
    static let week = UnitDuration(symbol: "wk", converter: UnitConverterLinear(coefficient: 604_800))
    static let year = UnitDuration(symbol: "yr", converter: UnitConverterLinear(coefficient: 31_557_600))

    static let categories: [UnitCategory] = [
        UnitCategory(id: "Length", icon: "ruler", units: [
            ("Millimeters", UnitLength.millimeters), ("Centimeters", UnitLength.centimeters), ("Meters", UnitLength.meters),
            ("Kilometers", UnitLength.kilometers), ("Inches", UnitLength.inches), ("Feet", UnitLength.feet),
            ("Yards", UnitLength.yards), ("Miles", UnitLength.miles), ("Nautical miles", UnitLength.nauticalMiles),
            ("Micrometers", UnitLength.micrometers), ("Light years", UnitLength.lightyears)
        ]),
        UnitCategory(id: "Weight", icon: "scalemass", units: [
            ("Milligrams", UnitMass.milligrams), ("Grams", UnitMass.grams), ("Kilograms", UnitMass.kilograms),
            ("Metric tons", UnitMass.metricTons), ("Ounces", UnitMass.ounces), ("Pounds", UnitMass.pounds),
            ("Stones", UnitMass.stones), ("US tons", UnitMass.shortTons), ("Carats", UnitMass.carats)
        ]),
        UnitCategory(id: "Temperature", icon: "thermometer", units: [
            ("Celsius", UnitTemperature.celsius), ("Fahrenheit", UnitTemperature.fahrenheit), ("Kelvin", UnitTemperature.kelvin)
        ]),
        UnitCategory(id: "Volume", icon: "drop", units: [
            ("Milliliters", UnitVolume.milliliters), ("Liters", UnitVolume.liters), ("Cubic meters", UnitVolume.cubicMeters),
            ("Teaspoons (US)", UnitVolume.teaspoons), ("Tablespoons (US)", UnitVolume.tablespoons), ("Fluid ounces (US)", UnitVolume.fluidOunces),
            ("Cups (US)", UnitVolume.cups), ("Pints (US)", UnitVolume.pints), ("Quarts (US)", UnitVolume.quarts),
            ("Gallons (US)", UnitVolume.gallons), ("Gallons (UK)", UnitVolume.imperialGallons), ("Cubic feet", UnitVolume.cubicFeet),
            ("Cubic inches", UnitVolume.cubicInches)
        ]),
        UnitCategory(id: "Area", icon: "square.dashed", units: [
            ("Square centimeters", UnitArea.squareCentimeters), ("Square meters", UnitArea.squareMeters),
            ("Square kilometers", UnitArea.squareKilometers), ("Hectares", UnitArea.hectares), ("Square inches", UnitArea.squareInches),
            ("Square feet", UnitArea.squareFeet), ("Square yards", UnitArea.squareYards), ("Acres", UnitArea.acres),
            ("Square miles", UnitArea.squareMiles)
        ]),
        UnitCategory(id: "Speed", icon: "speedometer", units: [
            ("Meters / second", UnitSpeed.metersPerSecond), ("Kilometers / hour", UnitSpeed.kilometersPerHour),
            ("Miles / hour", UnitSpeed.milesPerHour), ("Knots", UnitSpeed.knots)
        ]),
        UnitCategory(id: "Time", icon: "clock", units: [
            ("Milliseconds", UnitDuration.milliseconds), ("Seconds", UnitDuration.seconds), ("Minutes", UnitDuration.minutes),
            ("Hours", UnitDuration.hours), ("Days", day), ("Weeks", week), ("Years", year)
        ]),
        UnitCategory(id: "Data", icon: "externaldrive", units: [
            ("Bits", UnitInformationStorage.bits), ("Bytes", UnitInformationStorage.bytes), ("Kilobytes (1000)", UnitInformationStorage.kilobytes),
            ("Megabytes (1000)", UnitInformationStorage.megabytes), ("Gigabytes (1000)", UnitInformationStorage.gigabytes),
            ("Terabytes (1000)", UnitInformationStorage.terabytes), ("Kibibytes (1024)", UnitInformationStorage.kibibytes),
            ("Mebibytes (1024)", UnitInformationStorage.mebibytes), ("Gibibytes (1024)", UnitInformationStorage.gibibytes),
            ("Tebibytes (1024)", UnitInformationStorage.tebibytes), ("Megabits", UnitInformationStorage.megabits),
            ("Gigabits", UnitInformationStorage.gigabits)
        ]),
        UnitCategory(id: "Energy", icon: "bolt", units: [
            ("Joules", UnitEnergy.joules), ("Kilojoules", UnitEnergy.kilojoules), ("Calories", UnitEnergy.calories),
            ("Kilocalories", UnitEnergy.kilocalories), ("Kilowatt hours", UnitEnergy.kilowattHours)
        ]),
        UnitCategory(id: "Pressure", icon: "gauge", units: [
            ("Pascals", UnitPressure.newtonsPerMetersSquared), ("Kilopascals", UnitPressure.kilopascals),
            ("Hectopascals", UnitPressure.hectopascals), ("Bars", UnitPressure.bars), ("Millibars", UnitPressure.millibars),
            ("PSI", UnitPressure.poundsForcePerSquareInch), ("mm of mercury", UnitPressure.millimetersOfMercury),
            ("Inches of mercury", UnitPressure.inchesOfMercury)
        ]),
        UnitCategory(id: "Angle", icon: "angle", units: [
            ("Degrees", UnitAngle.degrees), ("Radians", UnitAngle.radians), ("Gradians", UnitAngle.gradians),
            ("Revolutions", UnitAngle.revolutions), ("Arc minutes", UnitAngle.arcMinutes), ("Arc seconds", UnitAngle.arcSeconds)
        ]),
        UnitCategory(id: "Fuel", icon: "fuelpump", units: [
            ("Liters / 100 km", UnitFuelEfficiency.litersPer100Kilometers), ("Miles / gallon (US)", UnitFuelEfficiency.milesPerGallon),
            ("Miles / gallon (UK)", UnitFuelEfficiency.milesPerImperialGallon)
        ]),
        UnitCategory(id: "Power", icon: "powerplug", units: [
            ("Watts", UnitPower.watts), ("Kilowatts", UnitPower.kilowatts), ("Megawatts", UnitPower.megawatts),
            ("Horsepower", UnitPower.horsepower)
        ])
    ]

    static func convert(_ value: Double, from: Dimension, to: Dimension) -> Double {
        Measurement(value: value, unit: from).converted(to: to).value
    }
}

struct UnitConverterView: View {
    @AppStorage("unitCategory") private var categoryID = "Length"
    @State private var value: Double = 1
    @State private var fromIndex = 2

    private var category: UnitCategory {
        UnitCatalog.categories.first { $0.id == categoryID } ?? UnitCatalog.categories[0]
    }

    var body: some View {
        ToolPage(tool: .unitConverter) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 8)], spacing: 8) {
                ForEach(UnitCatalog.categories) { cat in
                    Button {
                        categoryID = cat.id
                        fromIndex = 0
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: cat.icon)
                            Text(cat.id).font(.caption)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(TileButtonStyle(selected: cat.id == categoryID))
                }
            }

            Card(title: category.id, icon: category.icon) {
                HStack {
                    TextField("Value", value: $value, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .font(.title3)
                        .frame(width: 180)
                    Picker("", selection: $fromIndex) {
                        ForEach(category.units.indices, id: \.self) { i in
                            Text(category.units[i].0).tag(i)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                }
                Divider()
                let from = category.units[min(fromIndex, category.units.count - 1)].1
                ForEach(category.units.indices, id: \.self) { i in
                    let unit = category.units[i]
                    let converted = UnitCatalog.convert(value, from: from, to: unit.1)
                    let text = Format.number(converted, maxFraction: 8)
                    HStack {
                        Text(unit.0).foregroundStyle(.secondary).frame(width: 180, alignment: .leading)
                        Text(text)
                            .font(.system(.body, design: .monospaced))
                            .fontWeight(i == fromIndex ? Font.Weight.bold : Font.Weight.regular)
                            .textSelection(.enabled)
                        Spacer()
                        CopyButton(text: text)
                    }
                }
            }
        }
    }
}

// MARK: - Base converter

struct BaseConverterView: View {
    @State private var input = "255"
    @State private var base = 10
    @State private var text = "Hello"

    private var value: UInt64? {
        var s = input.trimmed.replacingOccurrences(of: "_", with: "").replacingOccurrences(of: " ", with: "")
        if s.isEmpty { return nil }
        let lower = s.lowercased()
        if (base == 16 && lower.hasPrefix("0x")) || (base == 2 && lower.hasPrefix("0b")) || (base == 8 && lower.hasPrefix("0o")) {
            s = String(s.dropFirst(2))
        }
        if s.hasPrefix("-") {
            guard let negative = Int64(s, radix: base) else { return nil }
            return UInt64(bitPattern: negative)
        }
        return UInt64(s, radix: base)
    }

    private func grouped(_ s: String, every n: Int, separator: String = " ") -> String {
        var out = ""
        for (i, ch) in s.reversed().enumerated() {
            if i > 0 && i % n == 0 { out.append(contentsOf: separator.reversed()) }
            out.append(ch)
        }
        return String(out.reversed())
    }

    var body: some View {
        ToolPage(tool: .baseConverter) {
            Card(title: "Number", icon: "number") {
                HStack {
                    TextField("Number", text: $input)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.title3, design: .monospaced))
                    Picker("Input base", selection: $base) {
                        Text("Binary (2)").tag(2)
                        Text("Octal (8)").tag(8)
                        Text("Decimal (10)").tag(10)
                        Text("Hex (16)").tag(16)
                    }
                    .frame(width: 220)
                }
                if let v = value {
                    let signed = Int64(bitPattern: v)
                    InfoRow(label: "Decimal", value: String(v))
                    if signed < 0 { InfoRow(label: "Signed decimal", value: String(signed)) }
                    InfoRow(label: "Hexadecimal", value: "0x" + String(v, radix: 16, uppercase: true))
                    InfoRow(label: "Octal", value: "0o" + String(v, radix: 8))
                    InfoRow(label: "Binary", value: grouped(String(v, radix: 2), every: 4))
                    InfoRow(label: "Bits needed", value: "\(v == 0 ? 1 : 64 - v.leadingZeroBitCount)")
                    if v < 0x110000, let scalar = UnicodeScalar(UInt32(v)), v >= 32 {
                        InfoRow(label: "Character", value: "\(Character(scalar))  (U+\(String(format: "%04X", UInt32(v))))")
                    }
                    InfoRow(label: "Size", value: Format.bytes(Int64(clamping: v)))
                } else {
                    Text("Not a valid base-\(base) number").foregroundColor(.red)
                }
            }

            Card(title: "Text ↔ Bytes", icon: "character.textbox") {
                TextField("Text", text: $text)
                    .textFieldStyle(.roundedBorder)
                let bytes = Array(text.utf8)
                InfoRow(label: "UTF-8 hex", value: bytes.map { String(format: "%02X", $0) }.joined(separator: " "))
                InfoRow(label: "UTF-8 binary", value: bytes.map { (byte: UInt8) -> String in
                    let bits = String(byte, radix: 2)
                    return String(repeating: "0", count: max(0, 8 - bits.count)) + bits
                }.joined(separator: " "))
                InfoRow(label: "Decimal bytes", value: bytes.map(String.init).joined(separator: " "))
                InfoRow(label: "Code points", value: text.unicodeScalars.map { String(format: "U+%04X", $0.value) }.joined(separator: " "))
            }
        }
    }
}

// MARK: - Date & time tools

struct TimestampView: View {
    @State private var timestampInput = String(Int(Date().timeIntervalSince1970))
    @State private var pickedDate = Date()
    @State private var startDate = Date()
    @State private var endDate = Date().addingTimeInterval(86_400 * 30)
    @State private var addAmount = 10
    @State private var addUnit = Calendar.Component.day
    @AppStorage("worldClocks") private var clocksRaw = "America/New_York,Europe/London,Europe/Paris,Asia/Tokyo,Australia/Sydney"
    @State private var newZone = "America/Los_Angeles"

    private var clocks: [String] { clocksRaw.split(separator: ",").map(String.init).filter { TimeZone(identifier: $0) != nil } }

    private var parsedDate: Date? {
        guard let n = Double(timestampInput.trimmed) else { return nil }
        // Treat 13-digit values as milliseconds.
        return Date(timeIntervalSince1970: abs(n) > 100_000_000_000 ? n / 1000 : n)
    }

    private func formats(_ date: Date) -> [(String, String)] {
        let iso = ISO8601DateFormatter()
        let utc = DateFormatter()
        utc.timeZone = TimeZone(identifier: "UTC")
        utc.dateFormat = "yyyy-MM-dd HH:mm:ss 'UTC'"
        let rfc = DateFormatter()
        rfc.locale = Locale(identifier: "en_US_POSIX")
        rfc.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        let relative = RelativeDateTimeFormatter()
        return [
            ("Local", date.formatted(date: .complete, time: .standard)),
            ("UTC", utc.string(from: date)),
            ("ISO 8601", iso.string(from: date)),
            ("RFC 2822", rfc.string(from: date)),
            ("Unix seconds", String(Int(date.timeIntervalSince1970))),
            ("Unix milliseconds", String(Int64(date.timeIntervalSince1970 * 1000))),
            ("Relative", relative.localizedString(for: date, relativeTo: Date()))
        ]
    }

    var body: some View {
        ToolPage(tool: .timestampConverter) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Card(title: "Now", icon: "clock") {
                    HStack(spacing: 30) {
                        VStack(alignment: .leading) {
                            Text("Unix time").font(.caption).foregroundStyle(.secondary)
                            Text(String(Int(context.date.timeIntervalSince1970)))
                                .font(.system(size: 28, weight: .medium, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        VStack(alignment: .leading) {
                            Text("Local time").font(.caption).foregroundStyle(.secondary)
                            Text(context.date.formatted(date: .abbreviated, time: .standard))
                                .font(.system(size: 20, weight: .medium))
                        }
                        Spacer()
                        CopyButton(text: String(Int(context.date.timeIntervalSince1970)))
                    }
                }
            }

            Card(title: "Timestamp → Date", icon: "arrow.right") {
                HStack {
                    TextField("Unix timestamp (seconds or ms)", text: $timestampInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                    Button("Now") { timestampInput = String(Int(Date().timeIntervalSince1970)) }
                }
                if let date = parsedDate {
                    ForEach(formats(date), id: \.0) { row in InfoRow(label: row.0, value: row.1) }
                } else {
                    Text("Enter a number").foregroundStyle(.secondary)
                }
            }

            Card(title: "Date → Timestamp", icon: "arrow.left") {
                DatePicker("Date", selection: $pickedDate)
                    .frame(maxWidth: 360)
                InfoRow(label: "Unix seconds", value: String(Int(pickedDate.timeIntervalSince1970)))
                InfoRow(label: "ISO 8601", value: ISO8601DateFormatter().string(from: pickedDate))
                HStack {
                    Stepper("Add \(addAmount)", value: $addAmount, in: -10_000...10_000)
                    Picker("", selection: $addUnit) {
                        Text("minutes").tag(Calendar.Component.minute)
                        Text("hours").tag(Calendar.Component.hour)
                        Text("days").tag(Calendar.Component.day)
                        Text("weeks").tag(Calendar.Component.weekOfYear)
                        Text("months").tag(Calendar.Component.month)
                        Text("years").tag(Calendar.Component.year)
                    }
                    .labelsHidden()
                    .frame(width: 110)
                    let result = Calendar.current.date(byAdding: addUnit, value: addAmount, to: pickedDate) ?? pickedDate
                    Text("= " + result.formatted(date: .complete, time: .shortened))
                        .textSelection(.enabled)
                }
            }

            Card(title: "Time Between Dates", icon: "calendar") {
                HStack {
                    DatePicker("From", selection: $startDate)
                    DatePicker("To", selection: $endDate)
                }
                let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: startDate, to: endDate)
                let seconds = endDate.timeIntervalSince(startDate)
                InfoRow(label: "Difference", value: "\(comps.year ?? 0) years, \(comps.month ?? 0) months, \(comps.day ?? 0) days, \(comps.hour ?? 0) h \(comps.minute ?? 0) min")
                InfoRow(label: "Total days", value: String(format: "%.2f", seconds / 86_400))
                InfoRow(label: "Total hours", value: String(format: "%.1f", seconds / 3600))
                InfoRow(label: "Weekdays (Mon–Fri)", value: "\(weekdays(from: startDate, to: endDate))")
            }

            Card(title: "World Clock", icon: "globe") {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(clocks, id: \.self) { id in
                            if let zone = TimeZone(identifier: id) {
                                HStack {
                                    Text(id.replacingOccurrences(of: "_", with: " ")).frame(width: 220, alignment: .leading)
                                    Text(time(context.date, zone)).font(.system(.body, design: .monospaced))
                                    Text(offset(zone, context.date)).foregroundStyle(.secondary).font(.caption)
                                    Spacer()
                                    Button {
                                        clocksRaw = clocks.filter { $0 != id }.joined(separator: ",")
                                    } label: {
                                        Image(systemName: "minus.circle")
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }
                        }
                    }
                }
                HStack {
                    Picker("Add time zone", selection: $newZone) {
                        ForEach(TimeZone.knownTimeZoneIdentifiers, id: \.self) { Text($0).tag($0) }
                    }
                    .frame(maxWidth: 360)
                    Button("Add") {
                        if !clocks.contains(newZone) { clocksRaw = (clocks + [newZone]).joined(separator: ",") }
                    }
                }
            }
        }
    }

    private func time(_ date: Date, _ zone: TimeZone) -> String {
        let f = DateFormatter()
        f.timeZone = zone
        f.dateFormat = "EEE HH:mm:ss"
        return f.string(from: date)
    }

    private func offset(_ zone: TimeZone, _ date: Date) -> String {
        let seconds = zone.secondsFromGMT(for: date)
        let sign = seconds >= 0 ? "+" : "−"
        let h = abs(seconds) / 3600
        let m = (abs(seconds) % 3600) / 60
        return m == 0 ? "UTC\(sign)\(h)" : "UTC\(sign)\(h):\(String(format: "%02d", m))"
    }

    private func weekdays(from start: Date, to end: Date) -> Int {
        let calendar = Calendar.current
        var count = 0
        var day = calendar.startOfDay(for: min(start, end))
        let last = calendar.startOfDay(for: max(start, end))
        var guardCount = 0
        while day < last && guardCount < 100_000 {
            if !calendar.isDateInWeekend(day) { count += 1 }
            day = calendar.date(byAdding: .day, value: 1, to: day) ?? last
            guardCount += 1
        }
        return count
    }
}
