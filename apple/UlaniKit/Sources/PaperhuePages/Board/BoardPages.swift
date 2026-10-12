import Foundation
import PaperhueAgenda

/// The message board pages (shared/BOARD.md "Drawing", shared/LAYOUTS.md 9; python/src/ulani_epaper/layouts.py,
/// "Message board"): the owner's notes, newest first, drawn with the calendar pages' text rules.
/// No clock: a note's time is its own `at`, shown in `zone` as "10/12 14:03".
public enum BoardPages {
    /// 留言板 (Python: `render_board`): the newest six notes as sticky notes, each as large as
    /// it fits, with the count in the header.
    public static func board(_ notes: [Note], zone: TimeZone) -> PageCanvas {
        var page = PageCanvas()
        BoardPage.drawBoard(&page, notes, zone)
        return page
    }

    /// 大字留言 (Python: `render_message`): the newest note alone, centred, as large as it fits.
    public static func message(_ notes: [Note], zone: TimeZone) -> PageCanvas {
        var page = PageCanvas()
        BoardPage.drawMessage(&page, notes, zone)
        return page
    }
}

/// Both board pages and their geometry (layouts.py "Message board").
enum BoardPage {
    private typealias G = PageGeometry

    /// 留言板, bold, on the header baseline.
    static let boardTitleSize = 32
    /// Cards and the big message live in y top...bottom, x margin...width - margin.
    static let top = 84
    static let gap = 16
    /// Notes on the board; the header says when there are more.
    static let maxNotes = 6
    /// (columns, rows) for 1...6 notes, filled left to right, top to bottom.
    static let grid = [(1, 1), (2, 1), (3, 1), (2, 2), (3, 2), (3, 2)]
    static let cardRadius = 12
    static let cardPad = 14
    /// Bold; the largest at which the whole note fits.
    static let cardSizes = [44, 36, 30, 26, 22, 20]
    /// "10/12 14:03", bottom-left in the card.
    static let cardTimeSize = PageText.noteSize
    /// Between the last text line and the time.
    static let cardTimeGap = 10
    /// Line pitch, times the text size.
    static let pitch = 1.25

    /// 留言, red bold, on the header baseline.
    static let messageTitleSize = 28
    /// Bold; the largest at which the whole note fits.
    static let messageSizes = [120, 96, 80, 64, 52, 44, 36, 30]

    /// A note with only characters the font lacks (e.g. emoji).
    static let undrawable = "（無法顯示的留言）"

    static func drawBoard(_ p: inout PageCanvas, _ notes: [Note], _ zone: TimeZone) {
        p.text("留言板", x: G.margin, y: G.headerBase, size: boardTitleSize, bold: true)
        let n = notes.count
        guard n > 0 else { return empty(&p) }
        let count = n <= maxNotes ? "\(n) 則" : "最新 \(maxNotes) 則，共 \(n) 則"
        p.text(count, x: PageCanvas.width - G.margin, y: G.headerBase, size: PageText.noteSize, anchor: .right)
        let shown = notes.prefix(maxNotes)
        let (cols, rows) = grid[shown.count - 1]
        let cw = Double(PageCanvas.width - 2 * G.margin - (cols - 1) * gap) / Double(cols)
        let ch = Double(G.bottom - top - (rows - 1) * gap) / Double(rows)
        func round(_ v: Double) -> Int { Int(v.rounded(.toNearestOrEven)) }
        for (i, note) in shown.enumerated() {
            let (r, c) = i.quotientAndRemainder(dividingBy: cols)
            let x0 = Double(G.margin) + Double(c) * (cw + Double(gap)), y0 = Double(top) + Double(r) * (ch + Double(gap))
            card(&p, round(x0), round(y0), round(x0 + cw) - 1, round(y0 + ch) - 1, note, zone)
        }
    }

    static func drawMessage(_ p: inout PageCanvas, _ notes: [Note], _ zone: TimeZone) {
        p.text("留言", x: G.margin, y: G.headerBase, size: messageTitleSize, bold: true, fill: .red)
        guard let note = notes.first else { return empty(&p) }
        p.text(time(note, zone), x: PageCanvas.width - G.margin, y: G.headerBase, size: PageText.noteSize, anchor: .right)
        let colour = colour(note)
        let ink: PanelColour = [.red, .blue, .green].contains(colour) ? colour : .black  // yellow / orange are pale on white
        let w = Double(PageCanvas.width - 2 * G.margin), h = Double(G.bottom - top)
        let paras = paragraphs(note)
        var (size, lines) = fitNote(paras, sizes: messageSizes, width: w, height: h)
        if lines.count > paras.count && !lines[lines.count - 1].hasSuffix(PageText.ellipsis) {
            lines = balance(paras, size: size, width: w, lines: lines)
        }
        let (above, below) = glyphExtent(size)
        let pitch = Double(size) * self.pitch
        let block = Double(above) + Double(lines.count - 1) * pitch + Double(below)
        let base = Double(top) + (h - block) / 2 + Double(above)
        for (i, line) in lines.enumerated() {
            p.text(line, x: Double(PageCanvas.width) / 2, y: base + Double(i) * pitch, size: size, bold: true, fill: ink,
                   anchor: .centre, maxWidth: w)
        }
    }

    /// A sticky note in the box (inclusive): bold text from the top left, the time at the bottom.
    static func card(_ p: inout PageCanvas, _ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ note: Note, _ zone: TimeZone) {
        let colour = colour(note)
        let ink: PanelColour = colour == .yellow || colour == .orange ? .black : .white
        p.panel(x0, y0, x1, y1, colour: colour, radius: cardRadius)
        let x = x0 + cardPad, w = x1 + 1 - x0 - 2 * cardPad
        let timeBase = y1 + 1 - cardPad - 2  // "/" reaches 2 px below the baseline
        let timeTop = timeBase + PageFont(size: cardTimeSize).verticalExtent(of: "0").top
        let textTop = y0 + cardPad
        let (size, lines) = fitNote(paragraphs(note), sizes: cardSizes, width: Double(w),
                                    height: Double(timeTop - cardTimeGap - textTop))
        let base = textTop + glyphExtent(size).above
        for (i, line) in lines.enumerated() {
            p.text(line, x: Double(x), y: Double(base) + Double(i * size) * pitch, size: size, bold: true, fill: ink,
                   maxWidth: Double(w))
        }
        p.text(time(note, zone), x: x, y: timeBase, size: cardTimeSize, fill: ink, maxWidth: w)
    }

    /// No notes yet: a blank sticky note and one calm message.
    static func empty(_ p: inout PageCanvas) {
        let cx = PageCanvas.width / 2, cy = 222, half = 34
        p.panel(cx - half, cy - half, cx + half - 1, cy + half - 1, colour: .yellow, radius: 10)
        for (dy, w) in [(-12, 36), (0, 36), (12, 22)] {
            p.rect(cx - 18, cy + dy - 1, cx - 18 + w - 1, cy + dy + 1)
        }
        p.text("還沒有留言", x: cx, y: 304, size: 30, bold: true, anchor: .centre)
        p.text("在 Paperhue 輸入留言，就會顯示在這裡", x: cx, y: 338, size: 20, anchor: .centre)
    }

    // MARK: Text

    /// The note's colour; anything else (a malformed file) is yellow.
    static func colour(_ note: Note) -> PanelColour {
        NoteColour(rawValue: note.color).flatMap { PanelColour(rawValue: $0.rawValue) } ?? .yellow
    }

    /// "10/12 14:03": when the note was written, in `zone`; "" if `at` is not a date-time.
    static func time(_ note: Note, _ zone: TimeZone) -> String {
        guard let t = note.time(in: zone) else { return "" }
        return "\(t.date.month)/\(t.date.day) " + DayText.hm(t)
    }

    /// The note's own lines as drawable text, empty ones dropped; never empty.
    static func paragraphs(_ note: Note) -> [String] {
        let paras = note.text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false)
            .map { PageFonts.clean(PythonText.string($0)) }.filter { !$0.isEmpty }
        return paras.isEmpty ? [undrawable] : paras
    }

    /// The height above and depth below the baseline of a bold CJK glyph ("國") at `size`.
    static func glyphExtent(_ size: Int) -> (above: Int, below: Int) {
        let extent = PageFont(size: size, bold: true).verticalExtent(of: "國")
        return (-extent.top, extent.bottom)
    }

    /// The paragraphs wrapped into at most `maxLines` lines, and whether all of it fitted;
    /// when something is left out the last line ends with "…".
    static func flow(_ paras: [String], _ font: PageFont, _ width: Double,
                     _ maxLines: Int) -> (lines: [String], complete: Bool) {
        var lines: [String] = []
        for para in paras {
            let room = maxLines - lines.count
            let whole = PageText.wrap(para, font: font, width: width, maxLines: Int.max)
            if whole.count <= room {
                lines += whole
                continue
            }
            if room > 0 {
                lines += PageText.wrap(para, font: font, width: width, maxLines: room)
            } else {
                lines[lines.count - 1] = PageText.fit(lines[lines.count - 1] + PageText.ellipsis, font: font, width: width)
            }
            return (lines, false)
        }
        return (lines, true)
    }

    /// The largest of `sizes` at which the whole text fits in `width` x `height`, with its lines;
    /// else the smallest, its last line ending with "…".
    static func fitNote(_ paras: [String], sizes: [Int], width: Double, height: Double) -> (size: Int, lines: [String]) {
        var fitted = (size: sizes[0], lines: [String]())
        for size in sizes {
            let (above, below) = glyphExtent(size)
            let rows = ((height - Double(above) - Double(below)) / (Double(size) * pitch)).rounded(.down)
            let (lines, complete) = flow(paras, PageFont(size: size, bold: true), width, max(1, Int(rows) + 1))
            fitted = (size, lines)
            if complete { break }
        }
        return fitted
    }

    /// The same number of lines at the narrowest width that still holds the whole text (no
    /// Latin word split), so a centred block has even lines, not a long one over a short one.
    static func balance(_ paras: [String], size: Int, width: Double, lines: [String]) -> [String] {
        let font = PageFont(size: size, bold: true)
        let words = paras.flatMap { PageText.tokens(Array($0.unicodeScalars)) }.filter { !PythonText.isAllSpace($0) }
        var lo = min(width, Double(words.map { font.length($0) }.max() ?? 0)), hi = width
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if flow(paras, font, mid, lines.count).complete { hi = mid } else { lo = mid }
        }
        return flow(paras, font, hi, lines.count).lines
    }
}
