import CoreText
import Foundation

/// One of the bundled faces at a whole pixel size, as the pages measure and draw text (Python:
/// `fonts.load(size, bold)`).
///
/// Every fit, wrap and ellipsis decision depends on widths, so they are Pillow's exactly. The
/// Python reference measures with Pillow's BASIC layout engine on FreeType: no kerning, no
/// ligatures, no shaping, and each glyph's advance as FreeType gives it with hinting on. That
/// is the `hmtx` advance scaled to the pixel size in 26.6 fixed point and rounded to a whole
/// pixel (`PageFace.pixelAdvance`); CoreText's own advances are not rounded and are not used.
public struct PageFont: Hashable, Sendable {
    /// Pixels per em (Pillow's `size`; 1 pt = 1 px when drawing at scale 1).
    public let size: Int
    public let bold: Bool

    public init(size: Int, bold: Bool = false) {
        precondition(size > 0, "a font size is a positive number of pixels")
        self.size = size
        self.bold = bold
    }

    /// Pillow's `getlength(text)`: the sum of the advances of the text's code points, so always
    /// a whole number of pixels. A character the font lacks measures as its .notdef glyph.
    public func length(_ text: String) -> Double {
        Double(length(text.unicodeScalars))
    }

    /// The advance of one code point in whole pixels.
    public func advance(_ scalar: Unicode.Scalar) -> Int {
        face.advance(scalar.value, size: size)
    }

    /// Pillow's BASIC layout of `text`: one glyph per code point (0, .notdef, where the font
    /// lacks it), each at its pen position, the whole-pixel advances before it added up. These
    /// glyphs at these positions are what `length` measures; CoreText's own line layout is not.
    public func layout(_ text: String) -> [(glyph: CGGlyph, x: Int)] {
        var x = 0
        return text.unicodeScalars.map { scalar in
            defer { x += face.advance(scalar.value, size: size) }
            return (CGGlyph(face.file.glyph(for: scalar.value)), x)
        }
    }

    /// This face at `size` for drawing with CoreText, made from the bundled file (nothing is
    /// registered with the system, and an installed font of the same name is never used).
    public var ctFont: CTFont {
        CTFontCreateWithGraphicsFont(face.graphicsFont, CGFloat(size), nil, nil)
    }

    /// The top and bottom of Pillow's `getbbox(String(scalar), anchor: "ls")`: the rows the
    /// glyph's ink reaches above the baseline (negative) and below it, with the baseline itself
    /// always included (top <= 0 <= bottom).
    ///
    /// FreeType hints CFF outlines vertically, which can move a glyph's top or bottom by a pixel
    /// from where the outline alone puts it. For the characters layouts.py measures ("0" and
    /// "國") at every page size the values are the Python reference's, recorded in
    /// `PageFace.hintedExtents`; any other character or size comes from the unhinted outline
    /// and may be a pixel off.
    public func verticalExtent(of scalar: Unicode.Scalar) -> (top: Int, bottom: Int) {
        if let extent = PageFace.hintedExtents[PageFace.ExtentKey(scalar: scalar, size: size, bold: bold)] {
            return extent
        }
        var glyph = CGGlyph(face.file.glyph(for: scalar.value))
        var box = CGRect.zero
        CTFontGetBoundingRectsForGlyphs(ctFont, .horizontal, &glyph, &box, 1)
        guard !box.isNull, !box.isEmpty else { return (0, 0) }
        return (-max(0, Int(box.maxY.rounded(.up))), -min(0, Int(box.minY.rounded(.down))))
    }

    var face: PageFace { PageFace.face(bold: bold) }

    func length(_ scalars: some Sequence<Unicode.Scalar>) -> Int {
        scalars.reduce(0) { $0 + face.advance($1.value, size: size) }
    }
}

/// One bundled weight: its file's tables and the CGFont CoreText draws it with. Read once, on
/// first use. Immutable (CGFont is immutable and safe to share between threads).
final class PageFace: @unchecked Sendable {
    static let regular = PageFace(bold: false)
    static let bold = PageFace(bold: true)

    static func face(bold: Bool) -> PageFace { bold ? Self.bold : regular }

    let file: FontFile
    let graphicsFont: CGFont

    private init(bold: Bool) {
        let url = PageFonts.url(bold: bold)
        do {
            let data = try Data(contentsOf: url, options: .alwaysMapped)
            file = try FontFile(data: data)
            guard let provider = CGDataProvider(data: data as CFData), let font = CGFont(provider) else {
                throw FontFileError("CoreText cannot read it")
            }
            graphicsFont = font
        } catch {
            // The files are part of this target and checked against the Python reference's.
            fatalError("the bundled page font \(url.lastPathComponent) is unreadable: \(error)")
        }
    }

    /// The advance of `codePoint`'s glyph (.notdef if the font lacks it) at `size` px.
    func advance(_ codePoint: UInt32, size: Int) -> Int {
        Self.pixelAdvance(units: Int(file.advances[file.glyph(for: codePoint)]), size: size,
                          unitsPerEm: file.unitsPerEm)
    }

    /// An advance of `units` font units at `size` px, as FreeType computes it for Pillow: the
    /// 16.16 scale is FT_DivFix(size * 64, unitsPerEm), FT_MulFix applies it (rounding) to give
    /// 26.6 pixels, and hinting rounds that to a whole pixel (FT_PIX_ROUND).
    static func pixelAdvance(units: Int, size: Int, unitsPerEm: Int) -> Int {
        let scale = ((size * 64) << 16 + unitsPerEm / 2) / unitsPerEm
        let scaled = (units * scale + 0x8000) >> 16
        return (scaled + 32) >> 6
    }

    struct ExtentKey: Hashable {
        let scalar: Unicode.Scalar
        let size: Int
        let bold: Bool
    }

    /// `getbbox(c, anchor="ls")` top and bottom in the Python reference (Pillow 12.3, FreeType
    /// 2.14) for "0" (month grid and card times) and "國" (note text), at every size layouts.py
    /// draws text at, both weights, and bold "國" at every size a card's text may have, 12 to 240
    /// (shared/CARDS.md). Differential/text-expectations.json holds the same numbers.
    static let hintedExtents: [ExtentKey: (top: Int, bottom: Int)] = {
        let sizes = [16, 18, 20, 22, 24, 26, 28, 30, 32, 36, 40, 44, 52, 64, 80, 96, 120, 128, 180]
        let table: [(Unicode.Scalar, Bool, [(Int, Int)])] = [
            ("0", false, [(-12, 0), (-14, 0), (-15, 0), (-16, 0), (-18, 0), (-19, 0), (-21, 0), (-22, 0),
                          (-24, 0), (-26, 0), (-30, 1), (-33, 1), (-39, 1), (-48, 1), (-60, 1), (-72, 1),
                          (-90, 2), (-95, 2), (-134, 2)]),
            ("0", true, [(-12, 0), (-14, 0), (-15, 0), (-17, 0), (-18, 0), (-19, 0), (-21, 0), (-22, 0),
                         (-24, 0), (-27, 0), (-31, 1), (-34, 1), (-39, 1), (-48, 1), (-60, 1), (-72, 1),
                         (-90, 2), (-97, 2), (-136, 3)]),
            ("國", false, [(-13, 2), (-15, 2), (-17, 2), (-18, 3), (-19, 3), (-21, 3), (-23, 3), (-24, 4),
                          (-26, 4), (-30, 4), (-32, 4), (-36, 4), (-42, 5), (-51, 7), (-64, 8), (-76, 9),
                          (-96, 10), (-102, 11), (-143, 16)]),
        ]
        var extents: [ExtentKey: (top: Int, bottom: Int)] = [:]
        for (scalar, bold, values) in table {
            for (size, value) in zip(sizes, values) {
                extents[ExtentKey(scalar: scalar, size: size, bold: bold)] = value
            }
        }
        for (size, value) in zip(12...240, boldGuo) {
            extents[ExtentKey(scalar: "國", size: size, bold: true)] = value
        }
        return extents
    }()

    /// Bold "國" at 12, 13, ... 240 px.
    private static let boldGuo: [(Int, Int)] = [
        (-11, 2), (-11, 3), (-12, 3), (-12, 3), (-13, 2), (-14, 2), (-15, 2), (-16, 2), (-17, 2), (-17, 3),
        (-18, 3), (-19, 3), (-20, 3), (-21, 3), (-22, 3), (-22, 3), (-24, 3), (-25, 3), (-25, 4), (-25, 4),
        (-26, 4), (-27, 4), (-28, 4), (-29, 4), (-30, 4), (-31, 4), (-31, 5), (-32, 5), (-33, 5), (-34, 5),
        (-35, 5), (-35, 5), (-36, 5), (-37, 5), (-37, 6), (-38, 6), (-39, 6), (-40, 6), (-41, 6), (-42, 6),
        (-43, 5), (-44, 6), (-45, 6), (-44, 7), (-46, 6), (-47, 6), (-48, 6), (-48, 6), (-49, 6), (-50, 6),
        (-51, 6), (-51, 7), (-52, 7), (-53, 7), (-54, 7), (-55, 7), (-56, 7), (-57, 7), (-57, 7), (-57, 8),
        (-58, 8), (-59, 8), (-60, 8), (-61, 8), (-62, 8), (-63, 8), (-64, 8), (-65, 8), (-65, 9), (-66, 9),
        (-66, 9), (-67, 9), (-69, 9), (-70, 9), (-70, 9), (-71, 9), (-71, 10), (-72, 9), (-73, 9), (-74, 9),
        (-75, 9), (-76, 9), (-77, 9), (-78, 9), (-78, 10), (-79, 10), (-79, 10), (-80, 10), (-81, 10), (-82, 10),
        (-83, 10), (-84, 10), (-85, 10), (-85, 11), (-86, 11), (-87, 11), (-88, 11), (-89, 11), (-89, 11), (-90, 11),
        (-92, 11), (-92, 12), (-92, 12), (-93, 12), (-94, 12), (-95, 12), (-96, 12), (-97, 12), (-98, 12), (-98, 13),
        (-99, 13), (-100, 13), (-101, 13), (-102, 13), (-102, 13), (-103, 13), (-104, 13), (-105, 13), (-105, 13), (-106, 13),
        (-107, 13), (-108, 13), (-109, 13), (-110, 13), (-111, 13), (-111, 13), (-111, 14), (-112, 14), (-114, 14), (-114, 14),
        (-115, 14), (-116, 14), (-117, 14), (-118, 14), (-118, 15), (-119, 15), (-120, 15), (-121, 15), (-122, 15), (-123, 15),
        (-124, 15), (-124, 15), (-125, 15), (-125, 16), (-126, 16), (-127, 16), (-128, 16), (-129, 16), (-130, 16), (-131, 16),
        (-132, 15), (-132, 16), (-133, 16), (-133, 16), (-134, 16), (-136, 16), (-137, 16), (-137, 16), (-138, 16), (-138, 17),
        (-139, 17), (-140, 17), (-141, 17), (-142, 17), (-143, 17), (-144, 17), (-145, 17), (-146, 17), (-146, 18), (-146, 18),
        (-147, 18), (-148, 18), (-149, 18), (-150, 18), (-151, 18), (-152, 18), (-152, 19), (-153, 19), (-154, 19), (-155, 19),
        (-155, 19), (-156, 19), (-157, 19), (-159, 19), (-158, 20), (-159, 20), (-160, 20), (-161, 20), (-162, 20), (-163, 20),
        (-164, 20), (-165, 19), (-166, 19), (-166, 20), (-167, 20), (-168, 20), (-168, 20), (-169, 20), (-170, 20), (-171, 20),
        (-172, 20), (-172, 21), (-173, 21), (-174, 21), (-175, 21), (-176, 21), (-177, 21), (-178, 21), (-178, 21), (-178, 22),
        (-179, 22), (-181, 22), (-181, 22), (-182, 22), (-183, 22), (-184, 22), (-185, 22), (-186, 22), (-186, 23), (-187, 23),
        (-188, 23), (-189, 23), (-190, 23), (-191, 23), (-191, 23), (-192, 23), (-192, 24), (-193, 23), (-194, 24)
    ]
}
