import Foundation

struct ClipColor: Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double

    enum Notation: String, CaseIterable, Identifiable {
        case hex = "HEX"
        case rgb = "RGB"
        case hsl = "HSL"
        case swiftUI = "SwiftUI Color"

        var id: Self { self }
    }

    func formatted(as notation: Notation) -> String {
        let channels = [red, green, blue]
        let bytes = channels.map { Int(($0 * 255).rounded()) }
        switch notation {
        case .hex:
            let components = alpha < 1 ? bytes + [Int((alpha * 255).rounded())] : bytes
            return "#" + components.map { String(format: "%02X", $0) }.joined()
        case .rgb:
            let components = bytes.map(String.init).joined(separator: ", ")
            return alpha < 1 ? "rgba(\(components), \(Self.decimal(alpha)))" : "rgb(\(components))"
        case .hsl:
            let maximum = max(red, green, blue)
            let minimum = min(red, green, blue)
            let delta = maximum - minimum
            let lightness = (maximum + minimum) / 2
            let saturation = delta == 0 ? 0 : delta / (1 - abs(2 * lightness - 1))
            let hue: Double
            switch maximum {
            case _ where delta == 0: hue = 0
            case red: hue = (green - blue) / delta
            case green: hue = (blue - red) / delta + 2
            default: hue = (red - green) / delta + 4
            }
            let degrees = hue < 0 ? (hue + 6) * 60 : hue * 60
            let components = "\(Self.decimal(degrees)), \(Self.decimal(saturation * 100))%, \(Self.decimal(lightness * 100))%"
            return alpha < 1 ? "hsla(\(components), \(Self.decimal(alpha)))" : "hsl(\(components))"
        case .swiftUI:
            let components = zip(["red", "green", "blue"], channels)
                .map { "\($0.0): \(Self.decimal($0.1))" }
                .joined(separator: ", ")
            let opacity = alpha < 1 ? ", opacity: \(Self.decimal(alpha))" : ""
            return "Color(\(components)\(opacity))"
        }
    }

    private static func decimal(_ value: Double) -> String {
        var text = String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), value)
        while text.last == "0" { text.removeLast() }
        if text.last == "." { text.removeLast() }
        return text
    }

    private static let functionPattern = try! NSRegularExpression(
        pattern: #"\A(rgb|rgba|hsl|hsla|color)\s*\(([^()]*)\)\z"#, options: .caseInsensitive
    )

    static func parse(_ text: String) -> Self? {
        if text.hasPrefix("#") { return parseHex(text) }
        guard let first = text.utf8.first, [67, 72, 82, 99, 104, 114].contains(first) else { return nil }

        let range = NSRange(text.startIndex..., in: text)
        guard let match = functionPattern.firstMatch(in: text, range: range),
              let name = Range(match.range(at: 1), in: text),
              let arguments = Range(match.range(at: 2), in: text) else { return nil }
        let function = text[name].lowercased()
        let components = text[arguments]
        let commaSeparated = components.contains(",")
        let parts = commaSeparated || function == "color"
            ? components.split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            : components.split(whereSeparator: { $0.isWhitespace || $0 == "/" }).map(String.init)
        if function == "color" { return parseSwiftUI(parts) }

        let hasAlpha = parts.count == 4
        if commaSeparated {
            guard hasAlpha == function.hasSuffix("a") else { return nil }
        } else {
            let sections = components.split(separator: "/", omittingEmptySubsequences: false)
            guard sections.count == (hasAlpha ? 2 : 1),
                  sections[0].split(whereSeparator: \.isWhitespace).count == 3 else { return nil }
        }
        guard parts.count == 3 || hasAlpha,
              let alpha = hasAlpha ? component(parts[3], scale: 1) : 1 else { return nil }
        if function.hasPrefix("rgb") {
            let rgb = parts.prefix(3).compactMap { component($0, scale: 255) }
            guard rgb.count == 3 else { return nil }
            return Self(red: rgb[0], green: rgb[1], blue: rgb[2], alpha: alpha)
        }

        let angle = parts[0].lowercased()
        guard let hue = Double(angle.hasSuffix("deg") ? String(angle.dropLast(3)) : angle), hue.isFinite,
              parts[1].hasSuffix("%"), parts[2].hasSuffix("%"),
              let saturation = component(parts[1], scale: 1),
              let lightness = component(parts[2], scale: 1) else { return nil }
        return fromHSL(hue: hue, saturation: saturation, lightness: lightness, alpha: alpha)
    }

    private static func parseHex(_ text: String) -> Self? {
        let digits = text.dropFirst()
        guard [3, 4, 6, 8].contains(digits.utf8.prefix(9).count),
              digits.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
              let value = UInt32(digits, radix: 16) else { return nil }
        let short = digits.utf8.count <= 4
        let hasAlpha = digits.utf8.count.isMultiple(of: 4)
        let bits = short ? 4 : 8
        let mask: UInt32 = short ? 15 : 255
        let rgb = hasAlpha ? value >> bits : value
        return Self(
            red: Double((rgb >> (bits * 2)) & mask) / Double(mask),
            green: Double((rgb >> bits) & mask) / Double(mask),
            blue: Double(rgb & mask) / Double(mask),
            alpha: hasAlpha ? Double(value & mask) / Double(mask) : 1
        )
    }

    private static func parseSwiftUI(_ parts: [String]) -> Self? {
        guard parts.count == 3 || parts.count == 4 else { return nil }
        var values: [Double] = []
        for (part, label) in zip(parts, ["red", "green", "blue", "opacity"]) {
            let pair = part.split(separator: ":", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard pair.count == 2, pair[0].lowercased() == label,
                  let value = Double(pair[1]), (0...1).contains(value) else { return nil }
            values.append(value)
        }
        return Self(red: values[0], green: values[1], blue: values[2], alpha: values.count == 4 ? values[3] : 1)
    }

    private static func component(_ text: String, scale: Double) -> Double? {
        let percent = text.hasSuffix("%")
        let limit = percent ? 100 : scale
        guard let value = Double(percent ? String(text.dropLast()) : text), (0...limit).contains(value) else { return nil }
        return value / limit
    }

    private static func fromHSL(hue: Double, saturation: Double, lightness: Double, alpha: Double) -> Self {
        let remainder = hue.truncatingRemainder(dividingBy: 360)
        let sector = (remainder < 0 ? remainder + 360 : remainder) / 60
        let chroma = (1 - abs(2 * lightness - 1)) * saturation
        let middle = chroma * (1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1))
        let channels: (Double, Double, Double)
        switch sector {
        case ..<1: channels = (chroma, middle, 0)
        case ..<2: channels = (middle, chroma, 0)
        case ..<3: channels = (0, chroma, middle)
        case ..<4: channels = (0, middle, chroma)
        case ..<5: channels = (middle, 0, chroma)
        default: channels = (chroma, 0, middle)
        }
        let offset = lightness - chroma / 2
        return Self(red: channels.0 + offset, green: channels.1 + offset, blue: channels.2 + offset, alpha: alpha)
    }
}
