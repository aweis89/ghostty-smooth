import AppKit
import CoreText
import SwiftUI

/// An opaque sRGB color, 0...1 per channel: what the picker's colors are
/// worked out in, so contrast can be measured before anything is drawn.
struct PCodeRGB: Equatable {
    let red: Double
    let green: Double
    let blue: Double

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// Strictly `#rrggbb`: anything else is nil.
    init?(hex: String) {
        let digits = Array(hex.utf8)
        guard digits.count == 7, digits[0] == UInt8(ascii: "#") else { return nil }
        var channels: [Double] = []
        for index in stride(from: 1, to: 7, by: 2) {
            guard let high = Self.hexDigit(digits[index]), let low = Self.hexDigit(digits[index + 1]) else {
                return nil
            }
            channels.append(Double(high * 16 + low) / 255)
        }
        self.init(red: channels[0], green: channels[1], blue: channels[2])
    }

    init?(_ color: Color) {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        self.init(red: Double(rgb.redComponent), green: Double(rgb.greenComponent), blue: Double(rgb.blueComponent))
    }

    var color: Color { Color(.sRGB, red: red, green: green, blue: blue) }
    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: 1) }

    /// WCAG relative luminance.
    var luminance: Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// WCAG contrast ratio, 1...21.
    func contrast(with other: PCodeRGB) -> Double {
        let (light, dark) = (max(luminance, other.luminance), min(luminance, other.luminance))
        return (light + 0.05) / (dark + 0.05)
    }

    /// This color moved `amount` (0...1) of the way to `other`.
    func mixed(with other: PCodeRGB, _ amount: Double) -> PCodeRGB {
        PCodeRGB(
            red: red + (other.red - red) * amount,
            green: green + (other.green - green) * amount,
            blue: blue + (other.blue - blue) * amount)
    }

    private static func hexDigit(_ byte: UInt8) -> Int? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): Int(byte - UInt8(ascii: "0"))
        case UInt8(ascii: "a")...UInt8(ascii: "f"): Int(byte - UInt8(ascii: "a")) + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): Int(byte - UInt8(ascii: "A")) + 10
        default: nil
        }
    }
}

/// pcode's optional `"style"` in a list (`pcode.pick_ui.native_style`): each
/// key a `#rrggbb`. Decoding never fails: a style that isn't an object, a key
/// we don't know, and a value that isn't a strict `#rrggbb` are all ignored.
struct PCodePickStyle: Decodable, Equatable {
    /// The selected row's text.
    var accent: PCodeRGB?
    /// The selected row's background.
    var selected: PCodeRGB?
    /// Muted text.
    var dim: PCodeRGB?

    init(accent: PCodeRGB? = nil, selected: PCodeRGB? = nil, dim: PCodeRGB? = nil) {
        self.accent = accent
        self.selected = selected
        self.dim = dim
    }

    init(from decoder: Decoder) {
        let values = (try? decoder.singleValueContainer().decode([String: Lenient].self)) ?? [:]
        func color(_ key: String) -> PCodeRGB? { values[key]?.string.flatMap { PCodeRGB(hex: $0) } }
        self.init(accent: color("accent"), selected: color("selected"), dim: color("dim"))
    }

    /// A JSON value that is kept only if it is a string.
    private struct Lenient: Decodable {
        let string: String?

        init(from decoder: Decoder) {
            string = try? decoder.singleValueContainer().decode(String.self)
        }
    }
}

/// The picker's colors and fonts: the terminal's, with pcode's style on top.
struct PCodePickTheme {
    /// Below this contrast the selected row's text falls back to the terminal's.
    static let minimumContrast = 3.0
    static let mutedOpacity = 0.6
    static let smallScale = 0.85

    /// The terminal's colors, as the config has them.
    struct Base: Equatable {
        var background: PCodeRGB
        var foreground: PCodeRGB
        var selectionBackground: PCodeRGB?
        var selectionForeground: PCodeRGB?
        var palette: [PCodeRGB]?
    }

    var foreground: Color
    /// Details, hints, the header and the footer.
    var muted: Color
    var selectedBackground: PCodeRGB
    var selectedText: PCodeRGB
    /// An action's confirm line.
    var status: Color
    /// A row's marker badge.
    var badge: Color
    /// pcode's terminal font: labels and the search field.
    var font: NSFont?
    /// Its family at `smallScale`.
    var smallFont: NSFont?

    init(base: Base, style: PCodePickStyle?, font: CTFont?) {
        foreground = base.foreground.color
        muted = style?.dim?.color ?? base.foreground.color.opacity(Self.mutedOpacity)
        let selection = Self.selection(base: base, style: style)
        selectedBackground = selection.background
        selectedText = selection.text
        status = Self.pick([3, 11], from: base).map(\.color) ?? .orange
        badge = Self.pick([4, 12, 6, 14], from: base).map(\.color) ?? base.foreground.color.opacity(Self.mutedOpacity)
        if let font {
            self.font = font as NSFont
            smallFont = CTFontCreateCopyWithAttributes(font, CTFontGetSize(font) * Self.smallScale, nil, nil) as NSFont
        }
    }

    /// The selected row's colors: pcode's, else the config's selection, else a
    /// tint of the foreground; its text kept readable on its background.
    static func selection(base: Base, style: PCodePickStyle?) -> (background: PCodeRGB, text: PCodeRGB) {
        let background = style?.selected ?? base.selectionBackground
            ?? base.background.mixed(with: base.foreground, 0.22)
        let text = style?.accent ?? base.selectionForeground ?? base.foreground
        return (background, readable(text, on: background, base: base))
    }

    /// `text`, unless it is too faint on `background`: then the foreground or
    /// background, whichever stands out more.
    static func readable(_ text: PCodeRGB, on background: PCodeRGB, base: Base) -> PCodeRGB {
        guard text.contrast(with: background) < minimumContrast else { return text }
        return base.foreground.contrast(with: background) >= base.background.contrast(with: background)
            ? base.foreground : base.background
    }

    /// Of the palette's `indexes`, the one that stands out most on the background.
    private static func pick(_ indexes: [Int], from base: Base) -> PCodeRGB? {
        guard let palette = base.palette else { return nil }
        return indexes.filter(palette.indices.contains).map { palette[$0] }
            .max { $0.contrast(with: base.background) < $1.contrast(with: base.background) }
    }

    func labelFont(fallbackSize: CGFloat) -> Font {
        font.map { Font($0 as CTFont) } ?? .system(size: fallbackSize)
    }

    func smallFont(fallbackSize: CGFloat, weight: Font.Weight = .regular) -> Font {
        smallFont.map { Font($0 as CTFont).weight(weight) } ?? .system(size: fallbackSize, weight: weight)
    }
}

extension PCodePickTheme.Base {
    /// The terminal's colors from `config`.
    init(_ config: Ghostty.Config) {
        // All 256 or none: a gap would shift the indexes.
        let palette = config.palette?.compactMap { PCodeRGB($0) }
        self.init(
            background: PCodeRGB(config.backgroundColor) ?? PCodeRGB(red: 0, green: 0, blue: 0),
            foreground: PCodeRGB(config.foregroundColor) ?? PCodeRGB(red: 1, green: 1, blue: 1),
            selectionBackground: config.selectionBackground.flatMap { PCodeRGB($0) },
            selectionForeground: config.selectionForeground.flatMap { PCodeRGB($0) },
            palette: palette?.count == 256 ? palette : nil)
    }
}
