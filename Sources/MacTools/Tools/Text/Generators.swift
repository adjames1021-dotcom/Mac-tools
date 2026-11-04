import Foundation

enum PasswordGenerator {
    static let upper = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
    static let lower = Array("abcdefghijklmnopqrstuvwxyz")
    static let digits = Array("0123456789")
    static let symbols = Array("!@#$%^&*()-_=+[]{};:,.<>/?~")
    static let ambiguous: Set<Character> = ["0", "O", "o", "1", "l", "I", "|", "`", "'", "\""]

    struct Options: Codable, Equatable {
        var length = 20
        var useUpper = true
        var useLower = true
        var useDigits = true
        var useSymbols = true
        var avoidAmbiguous = true
    }

    static func pool(_ o: Options) -> [[Character]] {
        var sets: [[Character]] = []
        if o.useUpper { sets.append(upper) }
        if o.useLower { sets.append(lower) }
        if o.useDigits { sets.append(digits) }
        if o.useSymbols { sets.append(symbols) }
        if o.avoidAmbiguous { sets = sets.map { $0.filter { !ambiguous.contains($0) } } }
        return sets.filter { !$0.isEmpty }
    }

    /// Generates a password containing at least one character from every selected set.
    static func generate(_ o: Options) -> String {
        var rng = SystemRandomNumberGenerator()
        let sets = pool(o)
        guard !sets.isEmpty else { return "" }
        let all = sets.flatMap { $0 }
        let length = max(o.length, sets.count)
        var chars: [Character] = sets.map { $0.randomElement(using: &rng)! }
        while chars.count < length { chars.append(all.randomElement(using: &rng)!) }
        chars.shuffle(using: &rng)
        return String(chars)
    }

    static func entropy(_ o: Options) -> Double {
        let size = pool(o).reduce(0) { $0 + $1.count }
        guard size > 1 else { return 0 }
        return Double(max(o.length, 1)) * log2(Double(size))
    }

    static let words: [String] = """
    able acid aged also area army away baby back ball band bank base bath bear beat been beer bell belt best bird blow \
    blue boat body bomb bond bone book boom born boss both bowl bulk burn bush busy cake call calm came camp card care \
    case cash cast cell chat chip city clay club coal coat code cold come cook cool cope copy core corn cost crew crop \
    dark data date dawn deal dear debt deck deep deer desk dial diet disk dock door dose down draw drop drum dual duck \
    dust duty each earn ease east easy edge else epic even ever exam exit face fact fair fall farm fast fate fear feed \
    feel file fill film find fine fire firm fish five flag flat flow folk food foot fork form fort four free frog fuel \
    full fund gain game gate gear gift girl give glad goal goat gold golf good gray grid grow gulf hair half hall hand \
    hard harp hawk head heat help hero hide high hill hint hold hole home hook hope horn host hour huge hunt idea inch \
    iron item jazz join joke jump jury keen keep kick kind king kite knee know lake lamp land lane last late lava lawn \
    lead leaf lean left lens life lift lime line link lion list live load loan lock loft long loop lord loud love luck \
    lung made mail main make mall many maple mars mask mass mate meal meat melt menu mild mile milk mind mint mode \
    moon more moss most moth move much nail name navy near neck need nest news next nice nine node noon nose note \
    oak oath open oval oven over pace pack page pain pair palm park part pass past path peak pear pine pink pipe plan \
    play plot plug plus poem poet pond pool port pose post pour pull pump pure push quiz race rain rank rare rate read \
    real reef rice rich ride ring rise risk road rock role roof room root rope rose ruby rule safe sage sail salt sand \
    save seal seat seed self sell send ship shoe shop shot show side sign silk site size skin slow snow soap sock soft \
    soil song soup spin spot star stay step stem stop suit sung surf swan tail tale talk tall tank tape task team tent \
    term test text tide tile time tiny tone tool tour town tree trip true tube tune turn twin type unit vast verb very \
    view vine vote wage wait wake walk wall want warm wave wear week well west whale wheat wide wild will wind wine wing \
    wire wise wish wolf wood wool word work yard yarn year yoga zero zinc zone zoom
    """.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)

    static func passphrase(words count: Int, separator: String, capitalize: Bool, addNumber: Bool) -> String {
        var rng = SystemRandomNumberGenerator()
        var parts = (0..<max(2, count)).map { _ -> String in
            let w = words.randomElement(using: &rng) ?? "word"
            return capitalize ? w.prefix(1).uppercased() + w.dropFirst() : w
        }
        if addNumber {
            let index = Int.random(in: 0..<parts.count, using: &rng)
            parts[index] += String(Int.random(in: 0...99, using: &rng))
        }
        return parts.joined(separator: separator)
    }

    static func passphraseEntropy(words count: Int) -> Double {
        Double(max(2, count)) * log2(Double(words.count))
    }

    static func strengthLabel(_ bits: Double) -> String {
        switch bits {
        case ..<40: return "Weak"
        case ..<60: return "Fair"
        case ..<80: return "Strong"
        case ..<110: return "Very strong"
        default: return "Excellent"
        }
    }
}

enum RandomTools {
    static func dice(_ notation: String) -> (rolls: [Int], total: Int)? {
        // Supports NdM+K, e.g. 2d6, d20, 3d8+2
        let text = notation.lowercased().replacingOccurrences(of: " ", with: "")
        let parts = text.split(separator: "d", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let count = parts[0].isEmpty ? 1 : Int(parts[0])
        var sidesText = String(parts[1])
        var modifier = 0
        if let plus = sidesText.firstIndex(where: { $0 == "+" || $0 == "-" }) {
            modifier = Int(sidesText[plus...]) ?? 0
            sidesText = String(sidesText[..<plus])
        }
        guard let n = count, let sides = Int(sidesText), (1...1000).contains(n), (2...100_000).contains(sides) else { return nil }
        let rolls = (0..<n).map { _ in Int.random(in: 1...sides) }
        return (rolls, rolls.reduce(0, +) + modifier)
    }
}
