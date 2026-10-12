import UlaniKit

/// The panel's colours by name, in the firmware's index order (python/src/ulani_epaper/image.py
/// `PALETTE`; the RGB values are UlaniKit's `Palette`).
public enum PanelColour: String, CaseIterable, Sendable {
    case black, white, green, blue, red, yellow, orange

    /// The palette index the frame stores.
    public var index: UInt8 { UInt8(Self.allCases.firstIndex(of: self)!) }

    public var rgb: (r: UInt8, g: UInt8, b: UInt8) { Palette.colours[Int(index)] }

    /// Hue ranges (degrees, upper bound exclusive) for `accent`; 330-360 is red again.
    private static let hues: [(limit: Double, colour: PanelColour)] =
        [(10, .red), (40, .orange), (75, .yellow), (165, .green), (330, .blue), (360, .red)]

    /// The panel colour for a "#rrggbb" calendar colour, chosen by hue (Python: `image.accent`).
    ///
    /// Nearest-RGB would turn the pastel colours calendars use into white; by hue they keep
    /// their identity. Greys and very dark colours (HSV saturation < 0.2 or value < 0.25)
    /// become black; a missing or malformed colour gives `fallback`.
    public static func accent(_ colour: String?, default fallback: PanelColour = .black) -> PanelColour {
        guard let colour, let (r, g, b) = channels(colour) else { return fallback }
        let (h, s, v) = hsv(Double(r) / 255, Double(g) / 255, Double(b) / 255)
        if s < 0.2 || v < 0.25 { return .black }
        return hues.first { h * 360 < $0.limit }?.colour ?? .red
    }

    /// The channels of exactly "#" and six ASCII hex digits (`re.fullmatch(r"#[0-9a-fA-F]{6}")`).
    private static func channels(_ text: String) -> (Int, Int, Int)? {
        let scalars = Array(text.unicodeScalars)
        guard scalars.count == 7, scalars[0] == "#" else { return nil }
        var digits: [Int] = []
        for scalar in scalars.dropFirst() {
            switch scalar.value {
            case 0x30...0x39: digits.append(Int(scalar.value) - 0x30)
            case 0x41...0x46: digits.append(Int(scalar.value) - 0x41 + 10)
            case 0x61...0x66: digits.append(Int(scalar.value) - 0x61 + 10)
            default: return nil
            }
        }
        return (digits[0] * 16 + digits[1], digits[2] * 16 + digits[3], digits[4] * 16 + digits[5])
    }

    /// Python's `colorsys.rgb_to_hsv`, operation for operation (the thresholds are compared
    /// with the same doubles).
    private static func hsv(_ r: Double, _ g: Double, _ b: Double) -> (h: Double, s: Double, v: Double) {
        let maxc = max(r, g, b), minc = min(r, g, b)
        if minc == maxc { return (0, 0, maxc) }
        let range = maxc - minc
        let s = range / maxc
        let rc = (maxc - r) / range, gc = (maxc - g) / range, bc = (maxc - b) / range
        let h = r == maxc ? bc - gc : g == maxc ? 2.0 + rc - bc : 4.0 + gc - rc
        let sixth = h / 6.0
        let wrapped = sixth.truncatingRemainder(dividingBy: 1.0)  // Python's % 1.0: never negative
        return (wrapped < 0 ? wrapped + 1.0 : wrapped, s, maxc)
    }
}
