import Testing
import UlaniKit
@testable import PaperhuePages

/// Feed colour -> panel colour (python/tests/test_image.py, the accent tests).
@Suite struct AccentTests {
    @Test(arguments: [
        // calendar colours as feeds give them ...
        ("#f83a22", PanelColour.red), ("#f691b2", .red), ("#ff7537", .orange), ("#ffad46", .orange),
        ("#ac725e", .orange), ("#fad165", .yellow), ("#fbe983", .yellow), ("#16a765", .green),
        ("#7bd148", .green), ("#92e1c0", .green), ("#9fe1e7", .blue), ("#4986e7", .blue),
        ("#9a9cff", .blue), ("#cd74e6", .blue), ("#c2c2c2", .black), ("#cabdbf", .black),
        // ... and the named colours of a calendar colour picker
        ("#d50000", .red), ("#e67c73", .red), ("#f4511e", .orange), ("#f6bf26", .yellow),
        ("#33b679", .green), ("#0b8043", .green), ("#039be5", .blue), ("#3f51b5", .blue),
        ("#7986cb", .blue), ("#8e24aa", .blue), ("#616161", .black),
    ])
    func accentMapsCalendarColoursByHue(colour: String, expected: PanelColour) {
        #expect(PanelColour.accent(colour) == expected)
    }

    @Test(arguments: ["", "blue", "#12345", "#gggggg", nil] as [String?])
    func accentFallsBackForMissingOrBadColours(bad: String?) {
        #expect(PanelColour.accent(bad) == .black)
        #expect(PanelColour.accent(bad, default: .blue) == .blue)
    }

    @Test func panelColoursAreThePaletteInFirmwareOrder() {
        #expect(PanelColour.allCases.map(\.rawValue) == ["black", "white", "green", "blue", "red", "yellow", "orange"])
        for colour in PanelColour.allCases {
            let rgb = Palette.colours[Int(colour.index)]
            #expect([colour.rgb.r, colour.rgb.g, colour.rgb.b] == [rgb.r, rgb.g, rgb.b])
        }
        #expect(PanelColour.orange.index == 6 && PanelColour.black.index == 0)
    }
}
