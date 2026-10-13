import CoreGraphics
import CoreText

/// One string's glyphs at Pillow's pen positions (`PageFont.layout`: whole-pixel advances from
/// `left`, on the baseline row boundary `baseline`), as 1-bit pixels: a pixel is ink when the
/// outline covers at least half of it, which is FreeType's 1-bit rule (ink where the pixel's
/// centre is inside) up to where an edge crosses a pixel's centre.
///
/// CoreText gives the coverage: the glyphs are drawn in grey levels (font smoothing and
/// subpixel positioning off) and cut at half. CoreGraphics' own aliased mode is not used: it
/// sets every pixel an outline touches, which makes every stem a pixel thicker on each side.
///
/// The Python reference rasterises with FreeType, which also hints the outlines (moves edges to
/// whole pixels) before its 1-bit rendering; CoreText does not hint, so a stem or a curve may
/// be a pixel thicker, thinner or shifted. That is the only difference from the reference's
/// pages, and it stays inside `box`.
struct GlyphRaster {
    /// The text's bounding box as Pillow's `textbbox` defines it (right and bottom exclusive):
    /// the pen line from `left` to `left + advance` on the baseline and the glyphs' outline
    /// bounds, rounded out.
    let bounds: (left: Int, top: Int, right: Int, bottom: Int)

    /// Room around `bounds` for what hinting can move (at most a pixel).
    static let margin = 2

    /// Inclusive page pixels: every pixel a glyph may set here or in the reference (`bounds`
    /// plus `margin`).
    var box: (x0: Int, y0: Int, x1: Int, y1: Int) {
        (bounds.left - Self.margin, bounds.top - Self.margin, bounds.right - 1 + Self.margin,
         bounds.bottom - 1 + Self.margin)
    }

    private let font: PageFont
    private let glyphs: [CGGlyph]
    private let origins: [Int]
    private let baseline: Int

    init(font: PageFont, text: String, left: Int, advance: Int, baseline: Int) {
        let layout = font.layout(text)
        self.font = font
        self.baseline = baseline
        glyphs = layout.map(\.glyph)
        origins = layout.map { left + $0.x }
        var outlines = [CGRect](repeating: .zero, count: glyphs.count)
        CTFontGetBoundingRectsForGlyphs(font.ctFont, .horizontal, glyphs, &outlines, glyphs.count)
        var (x0, y0, x1, y1) = (left, baseline, left + advance, baseline)
        for (rect, origin) in zip(outlines, origins) where !rect.isNull && !rect.isEmpty {
            x0 = min(x0, origin + Int(rect.minX.rounded(.down)))
            x1 = max(x1, origin + Int(rect.maxX.rounded(.up)))
            y0 = min(y0, baseline - Int(rect.maxY.rounded(.up)))
            y1 = max(y1, baseline - Int(rect.minY.rounded(.down)))
        }
        bounds = (x0, y0, x1, y1)
    }

    /// Calls `body(x, y)` for every ink pixel, in page coordinates (possibly off the page).
    func forEachInk(_ body: (Int, Int) -> Void) {
        let width = box.x1 - box.x0 + 1, height = box.y1 - box.y0 + 1
        guard !glyphs.isEmpty,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return }
        context.setAllowsAntialiasing(true)  // coverage, cut at half below
        context.setShouldAntialias(true)
        context.setAllowsFontSmoothing(false)
        context.setShouldSmoothFonts(false)
        context.setAllowsFontSubpixelPositioning(false)
        context.setShouldSubpixelPositionFonts(false)
        context.setAllowsFontSubpixelQuantization(false)
        context.setShouldSubpixelQuantizeFonts(false)
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(gray: 1, alpha: 1)
        context.textMatrix = .identity
        // CoreGraphics counts y up from the bottom edge, which is page row box.y1 + 1.
        let y = CGFloat(box.y1 + 1 - baseline)
        let positions = origins.map { CGPoint(x: CGFloat($0 - box.x0), y: y) }
        CTFontDrawGlyphs(font.ctFont, glyphs, positions, glyphs.count, context)
        guard let data = context.data else { return }
        let rowBytes = context.bytesPerRow
        let bytes = data.bindMemory(to: UInt8.self, capacity: rowBytes * height)
        for row in 0..<height {  // the first row in memory is the top one
            for column in 0..<width where bytes[row * rowBytes + column] >= 128 {
                body(box.x0 + column, box.y0 + row)
            }
        }
    }
}
