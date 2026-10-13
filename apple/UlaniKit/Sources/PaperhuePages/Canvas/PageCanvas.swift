import Foundation
import UlaniKit

/// Where a string sits on its point (Pillow anchors): always on the baseline, horizontally by
/// the left end, the right end or the middle of its advance width.
public enum TextAnchor: String, Sendable {
    /// "ls"
    case left = "ls"
    /// "rs"
    case right = "rs"
    /// "ms": the middle of the advance width, rounded as Pillow does (odd widths lean left).
    case centre = "ms"
}

/// One page being drawn (Python: `layouts._Page`): 800x480 pixels from the top-left, each one of
/// the panel's 7 colours, white to start with; no anti-aliasing anywhere (shared/LAYOUTS.md 1).
///
/// The primitives are exactly the reference's (LAYOUTS.md 1.3). Shapes are Pillow's pixels
/// (`Raster`). Text goes through the text primitive's rules (`PageText.drawable`), sits where
/// Pillow puts it (whole-pixel advances, baseline anchors) and becomes 1-bit pixels from
/// CoreText's outlines (`GlyphRaster`); only those glyph pixels may differ from the
/// reference's, which FreeType hints. Every drawn string is recorded in drawing order
/// (`drawnTexts`, Python's `drawn_texts`).
public struct PageCanvas: Sendable {
    public static let width = Frame.width
    public static let height = Frame.height

    /// Row-major from the top-left.
    public private(set) var pixels: [PanelColour]
    /// Every string drawn, after cleaning and cutting, in drawing order; "" draws nothing and is
    /// not recorded.
    public private(set) var drawnTexts: [String] = []

    /// Each drawing call as the reference makes it, one line per call (the differential tests
    /// compare these with the Python reference's).
    private(set) var operations: [String] = []
    /// Each drawn string with the box its glyphs may touch (the golden tests' text mask).
    private(set) var textRuns: [TextRun] = []
    /// False: strings are measured, placed and recorded, but no glyph pixel is set (the golden
    /// tests use this to see what lies under the text).
    var drawsGlyphs = true

    struct TextRun: Sendable {
        let text: String
        let fill: PanelColour
        /// As Pillow's `textbbox` (right and bottom exclusive), from the outlines.
        let bounds: (left: Int, top: Int, right: Int, bottom: Int)
        /// Inclusive page pixels: every pixel a glyph of the string may set, here or in the
        /// reference (`bounds` with a margin for hinting).
        let box: (x0: Int, y0: Int, x1: Int, y1: Int)
    }

    public init() {
        pixels = Array(repeating: .white, count: Self.width * Self.height)
    }

    public subscript(x x: Int, y y: Int) -> PanelColour { pixels[y * Self.width + x] }

    /// The palette indices, row-major from the top-left (`Frame(indices:)` takes them).
    public var indices: [UInt8] { pixels.map(\.index) }

    // MARK: Primitives

    /// Draws `text` with its baseline at `y` and returns the advance width drawn (Python:
    /// `_Page.text`). The text is cleaned (`PageFonts.clean`) and, with a `maxWidth`, cut with
    /// an ellipsis, so no caller can draw emoji or control characters. The point is rounded to
    /// whole pixels first (Python's `round`, half to even).
    @discardableResult
    public mutating func text(_ text: String, x: Double, y: Double, size: Int, bold: Bool = false,
                              fill: PanelColour = .black, anchor: TextAnchor = .left, maxWidth: Double? = nil) -> Int {
        let font = PageFont(size: size, bold: bold)
        let drawn = PageText.drawable(text, font: font, maxWidth: maxWidth)
        let width = Int(font.length(drawn))
        guard !drawn.isEmpty else { return 0 }
        let px = Int(x.rounded(.toNearestOrEven)), py = Int(y.rounded(.toNearestOrEven))
        operations.append(Self.logLine("text", px, py, anchor.rawValue, size, bold ? 1 : 0, fill.rawValue, drawn))
        drawnTexts.append(drawn)
        let left = switch anchor {
        case .left: px
        case .right: px - width
        case .centre: px - (width + 1) / 2  // Pillow: PIXEL(width * 64 / 2), half rounds up
        }
        let glyphs = GlyphRaster(font: font, text: drawn, left: left, advance: width, baseline: py)
        textRuns.append(TextRun(text: drawn, fill: fill, bounds: glyphs.bounds, box: glyphs.box))
        if drawsGlyphs {
            glyphs.forEachInk { x, y in set(x, y, fill) }
        }
        return width
    }

    /// `text` at a whole-pixel point.
    @discardableResult
    public mutating func text(_ text: String, x: Int, y: Int, size: Int, bold: Bool = false, fill: PanelColour = .black,
                              anchor: TextAnchor = .left, maxWidth: Int? = nil) -> Int {
        self.text(text, x: Double(x), y: Double(y), size: size, bold: bold, fill: fill, anchor: anchor,
                  maxWidth: maxWidth.map(Double.init))
    }

    /// A calendar colour bar: the rounded rectangle (x, y0)-(x + width - 1, y1), radius
    /// width / 2; yellow, pale on white, gets a 1 px black keyline.
    public mutating func bar(x: Int, y0: Int, y1: Int, colour: PanelColour, width: Int) {
        operations.append(Self.logLine("bar", x, y0, y1, colour.rawValue, width))
        roundedRectangle(x, y0, x + width - 1, y1, radius: width / 2, fill: colour, outline: keyline(colour))
    }

    /// A calendar colour dot in the box (round(cx - r), round(cy - r))-(round(cx + r) - 1,
    /// round(cy + r) - 1); yellow gets a black keyline.
    public mutating func dot(cx: Double, cy: Double, r: Int, colour: PanelColour) {
        let box = Self.circleBox(cx, cy, r)
        operations.append(Self.logLine("dot", box.x0, box.y0, box.x1, box.y1, colour.rawValue))
        ellipse(box, fill: colour, outline: keyline(colour))
    }

    /// A filled circle in the same box as `dot`, never outlined.
    public mutating func disc(cx: Double, cy: Double, r: Int, fill: PanelColour) {
        let box = Self.circleBox(cx, cy, r)
        operations.append(Self.logLine("disc", box.x0, box.y0, box.x1, box.y1, fill.rawValue))
        ellipse(box, fill: fill, outline: nil)
    }

    /// A circle's outline, `width` px thick, in the same box as `dot`.
    public mutating func ring(cx: Double, cy: Double, r: Int, colour: PanelColour, width: Int = 2) {
        let box = Self.circleBox(cx, cy, r)
        operations.append(Self.logLine("ring", box.x0, box.y0, box.x1, box.y1, colour.rawValue, width))
        ellipse(box, fill: nil, outline: colour, width: width)
    }

    /// A filled rectangle with inclusive corners.
    public mutating func rect(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, fill: PanelColour = .black) {
        operations.append(Self.logLine("rect", x0, y0, x1, y1, fill.rawValue))
        rectangle(x0, y0, x1, y1, fill: fill)
    }

    /// A polyline through `points`, `width` px wide (Pillow's `line` without joints: wide
    /// segments are separate quadrilaterals).
    public mutating func line(_ points: [(x: Int, y: Int)], colour: PanelColour, width: Int) {
        operations.append(Self.logLine("line", points.map { "\($0.x),\($0.y)" }.joined(separator: ";"), colour.rawValue, width))
        guard width != 0, points.count > 1 else { return }
        for (p, q) in zip(points, points.dropFirst()) {
            if width == 1 {
                Raster.line(p.x, p.y, q.x, q.y) { set($0, $1, colour) }
            } else {
                Raster.wideLine(p.x, p.y, q.x, q.y, width: width, rows: Self.height,
                                span: { fillSpan($0, $1, $2, colour) }, point: { set($0, $1, colour) })
            }
        }
        if width == 1, let last = points.last { set(last.x, last.y, colour) }
    }

    /// A rounded card in a panel colour (inclusive box); yellow gets a black keyline.
    public mutating func panel(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, colour: PanelColour, radius: Int) {
        operations.append(Self.logLine("panel", x0, y0, x1, y1, colour.rawValue, radius))
        roundedRectangle(x0, y0, x1, y1, radius: radius, fill: colour, outline: keyline(colour))
    }

    /// A "grey" horizontal hairline: black pixels at x0, x0 + 2, ... up to x1.
    public mutating func hairlineH(x0: Int, x1: Int, y: Int) {
        operations.append(Self.logLine("hairline_h", x0, x1, y))
        for x in stride(from: x0, through: x1, by: 2) { set(x, y, .black) }
    }

    /// The vertical `hairlineH`: black pixels at y0, y0 + 2, ... up to y1.
    public mutating func hairlineV(x: Int, y0: Int, y1: Int) {
        operations.append(Self.logLine("hairline_v", x, y0, y1))
        for y in stride(from: y0, through: y1, by: 2) { set(x, y, .black) }
    }

    /// The "+" mark (2 px strokes, `size` wide) with its left edge at `px`, centred on row `dy`.
    public mutating func plus(px: Int, dy: Int, size: Int) {
        operations.append(Self.logLine("plus", px, dy, size))
        let half = size / 2
        rectangle(px, dy - 1, px + size - 1, dy, fill: .black)  // horizontal stroke
        rectangle(px + half - 1, dy - half - 1, px + half, dy + half - 1, fill: .black)  // vertical stroke
    }

    // MARK: Pillow's ImageDraw shapes

    private func keyline(_ colour: PanelColour) -> PanelColour? { colour == .yellow ? .black : nil }

    private static func circleBox(_ cx: Double, _ cy: Double, _ r: Int) -> (x0: Int, y0: Int, x1: Int, y1: Int) {
        let r = Double(r)
        func round(_ v: Double) -> Int { Int(v.rounded(.toNearestOrEven)) }
        return (round(cx - r), round(cy - r), round(cx + r) - 1, round(cy + r) - 1)
    }

    /// ImageDraw.ellipse: the fill, then the outline if it is another colour.
    private mutating func ellipse(_ box: (x0: Int, y0: Int, x1: Int, y1: Int), fill: PanelColour?,
                                  outline: PanelColour?, width: Int = 1) {
        guard box.x1 >= box.x0, box.y1 >= box.y0 else { return }  // Pillow refuses these
        if let fill {
            Raster.ellipse(box.x0, box.y0, box.x1, box.y1, fill: true, width: 0) { fillSpan($0, $1, $2, fill) }
        }
        if let outline, outline != fill, width != 0 {
            Raster.ellipse(box.x0, box.y0, box.x1, box.y1, fill: false, width: width) { fillSpan($0, $1, $2, outline) }
        }
    }

    /// ImageDraw.rectangle with a fill and no outline.
    private mutating func rectangle(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, fill: PanelColour) {
        guard x1 >= x0, y1 >= y0 else { return }  // Pillow refuses these
        Raster.filledRectangle(x0, y0, x1, y1, rows: Self.height) { fillSpan($0, $1, $2, fill) }
    }

    /// ImageDraw.rounded_rectangle (all four corners, outline 1 px): pie slices for the
    /// corners and rectangles between them; joined corners make half or whole ellipses.
    private mutating func roundedRectangle(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, radius: Int,
                                           fill: PanelColour, outline: PanelColour?) {
        guard x1 >= x0, y1 >= y0 else { return }  // Pillow refuses these
        var d = min(x1 - x0, y1 - y0, radius * 2)
        let fullX = d >= x1 - x0 - 1
        if fullX { d = x1 - x0 }  // the two left and the two right corners are joined
        let fullY = d >= y1 - y0 - 1
        if fullY { d = y1 - y0 }
        if fullX && fullY {
            ellipse((x0, y0, x1, y1), fill: fill, outline: outline)
            return
        }
        if d == 0 {
            rectangle(x0, y0, x1, y1, fill: fill)
            if let outline, outline != fill {
                Raster.rectangleOutline(x0, y0, x1, y1, width: 1, span: { fillSpan($0, $1, $2, outline) },
                                        point: { set($0, $1, outline) })
            }
            return
        }
        let r = d / 2
        let corners: [(box: (Int, Int, Int, Int), start: Float, end: Float)] =
            if fullX {
                [((x0, y0, x0 + d, y0 + d), 180, 360), ((x0, y1 - d, x0 + d, y1), 0, 180)]
            } else if fullY {
                [((x0, y0, x0 + d, y0 + d), 90, 270), ((x1 - d, y0, x1, y0 + d), 270, 90)]
            } else {
                [((x0, y0, x0 + d, y0 + d), 180, 270), ((x1 - d, y0, x1, y0 + d), 270, 360),
                 ((x1 - d, y1 - d, x1, y1), 0, 90), ((x0, y1 - d, x0 + d, y1), 90, 180)]
            }
        for c in corners {
            Raster.pieslice(c.box.0, c.box.1, c.box.2, c.box.3, start: c.start, end: c.end) { fillSpan($0, $1, $2, fill) }
        }
        if fullX {
            rectangle(x0, y0 + r + 1, x1, y1 - r - 1, fill: fill)
        } else if x1 - r - 1 >= x0 + r + 1 {
            rectangle(x0 + r + 1, y0, x1 - r - 1, y1, fill: fill)
        }
        if !fullX && !fullY {
            rectangle(x0, y0 + r + 1, x0 + r, y1 - r - 1, fill: fill)
            rectangle(x1 - r, y0 + r + 1, x1, y1 - r - 1, fill: fill)
        }
        guard let outline, outline != fill else { return }
        for c in corners {
            Raster.arc(c.box.0, c.box.1, c.box.2, c.box.3, start: c.start, end: c.end, width: 1) {
                fillSpan($0, $1, $2, outline)
            }
        }
        if !fullX {
            rectangle(x0 + r + 1, y0, x1 - r - 1, y0, fill: outline)
            rectangle(x0 + r + 1, y1, x1 - r - 1, y1, fill: outline)
        }
        if !fullY {
            rectangle(x0, y0 + r + 1, x0, y1 - r - 1, fill: outline)
            rectangle(x1, y0 + r + 1, x1, y1 - r - 1, fill: outline)
        }
    }

    // MARK: Pixels

    /// One pixel; off the canvas is ignored (Pillow's `point`).
    private mutating func set(_ x: Int, _ y: Int, _ colour: PanelColour) {
        guard x >= 0, x < Self.width, y >= 0, y < Self.height else { return }
        pixels[y * Self.width + x] = colour
    }

    /// Pixels x0...x1 of row y, clipped to the canvas (Pillow's `hline`).
    private mutating func fillSpan(_ y: Int, _ x0: Int, _ x1: Int, _ colour: PanelColour) {
        guard y >= 0, y < Self.height else { return }
        let from = max(x0, 0), to = min(x1, Self.width - 1)
        guard from <= to else { return }
        let row = y * Self.width
        for x in from...to { pixels[row + x] = colour }
    }

    private static func logLine(_ fields: Any...) -> String {
        fields.map { "\($0)" }.joined(separator: "\t")
    }
}
