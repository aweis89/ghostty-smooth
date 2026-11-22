import Foundation
import Testing
@testable import Ghostty

/// pcode's optional list `style` and the colors the picker derives from it.
@Suite
struct PCodePickStyleTests {
    private static let black = PCodeRGB(red: 0, green: 0, blue: 0)
    private static let white = PCodeRGB(red: 1, green: 1, blue: 1)

    @Test(arguments: [
        ("#000000", PCodeRGB(red: 0, green: 0, blue: 0)),
        ("#ffffff", PCodeRGB(red: 1, green: 1, blue: 1)),
        ("#FF8000", PCodeRGB(red: 1, green: 128.0 / 255, blue: 0)),
    ])
    func parsesHex(_ text: String, _ expected: PCodeRGB) {
        #expect(PCodeRGB(hex: text) == expected)
    }

    @Test(arguments: ["", "#", "fff000", "#fff", "#ffff000", "#gggggg", " #ffffff", "#ffffff ", "#ff ff0", "#+fffff", "#ＦＦＦＦＦＦ"])
    func rejectsBadHex(_ text: String) {
        #expect(PCodeRGB(hex: text) == nil)
    }

    private struct List: Decodable {
        let title: String
        let style: PCodePickStyle?
    }

    private func decode(_ json: String) throws -> List {
        try JSONDecoder().decode(List.self, from: Data(json.utf8))
    }

    @Test func styleAbsentOrNull() throws {
        #expect(try decode(#"{"title": "t"}"#).style == nil)
        #expect(try decode(#"{"title": "t", "style": null}"#).style == nil)
    }

    @Test func styleDecodes() throws {
        let style = try decode(##"{"title": "t", "style": {"accent": "#ff0000", "selected": "#00ff00", "dim": "#0000ff", "new": "#123456"}}"##).style
        #expect(style == PCodePickStyle(
            accent: PCodeRGB(red: 1, green: 0, blue: 0),
            selected: PCodeRGB(red: 0, green: 1, blue: 0),
            dim: PCodeRGB(red: 0, green: 0, blue: 1)))
    }

    @Test(arguments: [##""red""##, "5", "[]", "true", ##"["#ff0000"]"##])
    func styleOfWrongTypeIsEmpty(_ value: String) throws {
        let list = try decode(##"{"title": "t", "style": \##(value)}"##)
        #expect(list.title == "t")
        #expect(list.style == PCodePickStyle())
    }

    @Test func badValuesAreIgnored() throws {
        let style = try decode(##"{"title": "t", "style": {"accent": 3, "selected": "#zzzzzz", "dim": {"x": 1}}}"##).style
        #expect(style == PCodePickStyle())
        let partial = try decode(##"{"title": "t", "style": {"accent": "red", "dim": "#808080"}}"##).style
        #expect(partial?.accent == nil)
        #expect(partial?.dim == PCodeRGB(hex: "#808080"))
    }

    private let dark = PCodePickTheme.Base(background: black, foreground: white)

    @Test func contrastRatio() {
        #expect(abs(Self.black.contrast(with: Self.white) - 21) < 0.01)
        #expect(Self.white.contrast(with: Self.white) == 1)
    }

    @Test func styleOverridesConfigSelection() {
        var base = dark
        base.selectionBackground = PCodeRGB(hex: "#444444")
        base.selectionForeground = PCodeRGB(hex: "#eeeeee")
        let config = PCodePickTheme.selection(base: base, style: nil)
        #expect(config.background == PCodeRGB(hex: "#444444"))
        #expect(config.text == PCodeRGB(hex: "#eeeeee"))
        let styled = PCodePickTheme.selection(
            base: base, style: PCodePickStyle(accent: PCodeRGB(hex: "#ffff00"), selected: PCodeRGB(hex: "#000080")))
        #expect(styled.background == PCodeRGB(hex: "#000080"))
        #expect(styled.text == PCodeRGB(hex: "#ffff00"))
    }

    @Test func faintSelectedTextFallsBack() {
        // Grey on grey: whichever of the background (black) or foreground (white) stands out more.
        let lightGrey = PCodePickTheme.selection(
            base: dark, style: PCodePickStyle(accent: PCodeRGB(hex: "#aaaaaa"), selected: PCodeRGB(hex: "#a0a0a0")))
        #expect(lightGrey.text == Self.black)
        let darkGrey = PCodePickTheme.selection(
            base: dark, style: PCodePickStyle(accent: PCodeRGB(hex: "#303030"), selected: PCodeRGB(hex: "#333333")))
        #expect(darkGrey.text == Self.white)
    }

    @Test func unsetSelectionTintsTheForeground() {
        let selection = PCodePickTheme.selection(base: dark, style: nil)
        #expect(selection.background != Self.black)
        #expect(selection.text == Self.white)
        #expect(selection.text.contrast(with: selection.background) >= PCodePickTheme.minimumContrast)
    }
}

private extension PCodePickTheme.Base {
    init(background: PCodeRGB, foreground: PCodeRGB) {
        self.init(background: background, foreground: foreground, selectionBackground: nil, selectionForeground: nil, palette: nil)
    }
}
