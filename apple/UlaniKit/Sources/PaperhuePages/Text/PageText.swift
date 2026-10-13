/// The text rules of every page (shared/LAYOUTS.md 1.1-1.2; python/src/ulani_epaper/layouts.py,
/// "Text"): the type scale, titles, truncation with an ellipsis and line wrapping. Widths are
/// `PageFont.length`, Pillow's, so every cut falls where the Python reference makes it.
public enum PageText {
    // MARK: Type scale (px)

    /// "更新於 10/12" only.
    public static let syncSize = 16
    /// The end time under a start time: digits only.
    public static let endTimeSize = 16
    /// Secondary text: times, locations, "還有 N 項", section labels (bold).
    public static let noteSize = 18
    /// Event titles in rows.
    public static let titleSize = 20
    /// CJK is never set smaller: at 16-17 px Regular, 四 rasterises nearly solid (`mayDraw`).
    public static let minimumCJKSize = 18

    // MARK: Strings

    public static let ellipsis = "…"
    /// Between metadata items, with no spaces: the font's U+00B7 is full width, so it already
    /// carries its own spacing.
    public static let separator = "·"
    /// The event or task really has no title.
    public static let untitled = "（無標題）"
    /// It has one, but only of characters the font lacks (e.g. emoji).
    public static let undrawable = "（無法顯示的標題）"

    /// An event or task title as drawable text: cleaned (`PageFonts.clean`), never empty
    /// (Python: `layouts._title`).
    public static func title(_ text: String?) -> String {
        let scalars = Array((text ?? "").unicodeScalars)
        if PythonText.strip(scalars[...]).isEmpty { return untitled }
        let cleaned = PageFonts.clean(text ?? "")
        return cleaned.isEmpty ? undrawable : cleaned
    }

    /// `text` as the text primitive draws it: cleaned (`PageFonts.clean`), then, if there is a
    /// `maxWidth`, cut to it with `fit` (Python: `layouts._Page.text`). "" draws nothing; the
    /// width the primitive returns is `font.length` of the result.
    public static func drawable(_ text: String, font: PageFont, maxWidth: Double? = nil) -> String {
        let cleaned = PageFonts.clean(text)
        guard let maxWidth else { return cleaned }
        return fit(cleaned, font: font, width: maxWidth)
    }

    /// `text` cut with an ellipsis to at most `width` px, never inside a Latin word when there
    /// is a space to back off to (Python: `layouts._fit`).
    ///
    /// Text that fits is returned as it is. Otherwise the longest prefix whose right-stripped
    /// form plus "…" fits is kept; if the cut falls between two Latin letters or digits it moves
    /// back to the previous space ("Quarterly…", not "Quarterly plan…"). When nothing fits, "…"
    /// alone, or "" if even that is too wide.
    public static func fit(_ text: String, font: PageFont, width: Double) -> String {
        let scalars = Array(text.unicodeScalars)
        var widths = [0]  // widths[n]: the first n code points
        widths.reserveCapacity(scalars.count + 1)
        for scalar in scalars { widths.append(widths[widths.count - 1] + font.advance(scalar)) }
        if Double(widths[scalars.count]) <= width { return text }
        let ellipsisWidth = font.length(ellipsis)
        func fits(_ n: Int) -> Bool {  // text[:n].rstrip() + "…"
            Double(widths[PythonText.rstrip(scalars[..<n]).endIndex]) + ellipsisWidth <= width
        }
        var lo = 0, hi = scalars.count
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if fits(mid) { lo = mid } else { hi = mid - 1 }
        }
        if lo == 0 { return ellipsisWidth <= width ? ellipsis : "" }
        // (Python reads text[lo] here; lo is past the end only after trailing spaces, which
        // cleaned text never has.)
        if lo < scalars.count, isLatin(scalars[lo - 1]), isLatin(scalars[lo]),
           let space = scalars[..<lo].lastIndex(of: " "), space > 0,
           !PythonText.strip(scalars[..<space]).isEmpty {
            lo = space
        }
        return PythonText.string(PythonText.rstrip(scalars[..<lo])) + ellipsis
    }

    /// Greedy wrap into at most `maxLines` (>= 1) lines; the last one gets "…" if text is left
    /// over (Python: `layouts._wrap`).
    ///
    /// Tokens are whole Latin words (letters, digits and `'’.,:;!?&+#@%/-`), whitespace runs or
    /// single characters. A word wider than the line is split into characters. Closing
    /// punctuation (`，。、：；！？）」』》〉】,.:;!?)`) never starts a line: when it does not fit,
    /// the line's last token moves down with it ("讀完《原子習" / "慣》").
    public static func wrap(_ text: String, font: PageFont, width: Double, maxLines: Int) -> [String] {
        precondition(maxLines >= 1, "wrap needs room for a line")
        func fits(_ scalars: ArraySlice<Unicode.Scalar>) -> Bool {
            Double(font.length(PythonText.rstrip(scalars))) <= width
        }
        var pieces: [ArraySlice<Unicode.Scalar>] = []
        for token in tokens(Array(text.unicodeScalars)) {
            if !PythonText.isAllSpace(token), token.count > 1, Double(font.length(token)) > width {
                pieces += token.map { [$0][...] }
            } else {
                pieces.append(token)
            }
        }
        var lines: [[ArraySlice<Unicode.Scalar>]] = [[]]
        for piece in pieces {
            let current = Array(lines[lines.count - 1].joined())
            if PythonText.strip(current[...]).isEmpty || fits((current + piece)[...]) {
                lines[lines.count - 1].append(piece)
            } else if piece.count == 1, noLineStart.contains(piece[piece.startIndex]) {
                // punctuation may not start a line: carry the previous token down with it
                // (appending it would overflow the line, and fit would then cut the line short)
                if lines[lines.count - 1].count > 1, !PythonText.isAllSpace(lines[lines.count - 1].last!) {
                    let carried = lines[lines.count - 1].removeLast()
                    lines.append([carried, piece])
                } else {
                    lines[lines.count - 1].append(piece)
                }
            } else {
                lines.append(PythonText.isAllSpace(piece) ? [] : [piece])
            }
        }
        var out = lines.map { PythonText.strip(Array($0.joined())[...]) }.filter { !$0.isEmpty }.map(PythonText.string)
        if out.count > maxLines {
            let rest = PythonText.strip(Array(lines[(maxLines - 1)...].joined().joined())[...])
            out = Array(out[..<(maxLines - 1)]) + [fit(PythonText.string(rest), font: font, width: width)]
        }
        return out.map { fit($0, font: font, width: width) }
    }

    /// False for text LAYOUTS.md 1.1 never sets at `size`: below `minimumCJKSize` only strings
    /// without CJK may be drawn (times "17:00", dates "10/20"), with one exception, the sync
    /// stamp's 更新於 in Regular ("更新於 10/12"). Bold CJK below 18 px is never used.
    public static func mayDraw(_ text: String, size: Int, bold: Bool) -> Bool {
        if size >= minimumCJKSize { return true }
        return text.unicodeScalars.allSatisfy { !isCJK($0) || (!bold && smallCJK.contains($0)) }
    }

    // MARK: Characters

    /// The sync stamp's characters, simple enough to stay legible at 16 px.
    private static let smallCJK: Set<Unicode.Scalar> = ["更", "新", "於"]

    /// Closing punctuation: never at the start of a line.
    static let noLineStart = Set("，。、：；！？）」』》〉】,.:;!?)".unicodeScalars)

    /// CJK ideographs, kana, Hangul, bopomofo and the full-width forms and punctuation.
    static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x11FF, 0x2E80...0x9FFF, 0xA960...0xA97F, 0xAC00...0xD7FF, 0xF900...0xFAFF,
             0xFE30...0xFE4F, 0xFF00...0xFFEF, 0x20000...0x3FFFF:
            true
        default:
            false
        }
    }

    /// `[0-9A-Za-zÀ-ɏ]`: where `fit` backs off to a space instead of cutting.
    static func isLatin(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0xC0...0x24F: true
        default: false
        }
    }

    /// A character of a Latin word token: `isLatin` or one of `'’.,:;!?&+#@%/-`.
    static func isWordCharacter(_ scalar: Unicode.Scalar) -> Bool {
        isLatin(scalar) || "'’.,:;!?&+#@%/-".unicodeScalars.contains(scalar)
    }

    /// Python's `_TOKEN.findall`: whole Latin words, whitespace runs, single other characters.
    static func tokens(_ scalars: [Unicode.Scalar]) -> [ArraySlice<Unicode.Scalar>] {
        var tokens: [ArraySlice<Unicode.Scalar>] = []
        var i = 0
        while i < scalars.count {
            var end = i + 1
            if isWordCharacter(scalars[i]) {
                while end < scalars.count, isWordCharacter(scalars[end]) { end += 1 }
            } else if PythonText.isSpace(scalars[i]) {
                while end < scalars.count, PythonText.isSpace(scalars[end]) { end += 1 }
            }
            tokens.append(scalars[i..<end])
            i = end
        }
        return tokens
    }
}
