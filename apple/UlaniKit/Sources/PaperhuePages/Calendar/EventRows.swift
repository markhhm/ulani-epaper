import Foundation
import PaperhueAgenda

/// The geometry every calendar page shares (shared/LAYOUTS.md 1 and 3; the constants of
/// python/src/ulani_epaper/layouts.py).
enum PageGeometry {
    /// Left and right page margin.
    static let margin = 28
    /// No ink below this row.
    static let bottom = PageCanvas.height - 18
    /// The baseline of every page's top line.
    static let headerBase = 56

    /// Text x in cards and the all-day line (after the 5 px bar or the 10 px dot).
    static let rowTextDX = 15
    /// Calendar dot radius (10 px dots), also in the mini month.
    static let dotR = 5

    /// One line: ● title ● title +N.
    static let allDayH = 34
    static let allDayBase = 22

    /// Two lines: bold title, then "10:00 – 11:30·3F 大會議室".
    static let cardH = 56
    static let cardBarW = 5
    static let cardBase1 = 20
    static let cardBase2 = 44

    /// One line: start time | bar | title.
    static let lineH = 28
    static let lineBase = 22
    static let lineBarW = 4
    /// Bar x offset (fits "至01:00" at 18 px, 63 px).
    static let lineTimeW = 70
    static let lineTitleDX = 82

    /// "還有 N 項" / "稍早已結束 N 項" on a line of their own.
    static let noteH = 28
    static let noteBase = 21
    /// Space above a "明天" / "下一個行程" label.
    static let sectionGap = 10
    /// The label itself (18 px bold).
    static let sectionH = 26
}

// The event rows of the month panel and the agenda page (LAYOUTS.md 3; layouts.py "Shared row
// drawing"). x, y are a row's top-left corner, w the width it may use.
extension PageCanvas {
    private typealias G = PageGeometry

    /// All of a day's all-day events on one line; returns the y below it.
    ///
    /// One event:  ● 墾丁三日遊  第 3 天，共 3 天   (the note only if it fits)
    /// Several:    ● 墾丁三日遊  ● 咖啡日  +1       (as many as fit, then +N)
    mutating func allDayLine(x: Int, y: Int, w: Int, events: [Event], day: LocalDate, zone: TimeZone) -> Int {
        let base = y + G.allDayBase
        let cy = Double(base - 8)  // dot centre at the middle of the CJK glyphs
        let titles = events.map { PageText.title($0.title) }
        let n = events.count, gap = 16
        let note = PageFont(size: PageText.noteSize), title = PageFont(size: PageText.titleSize, bold: true)
        if n == 1 {
            dot(cx: Double(x + G.dotR), cy: cy, r: G.dotR, colour: events[0].accent)
            let tw = text(titles[0], x: x + G.rowTextDX, y: base, size: PageText.titleSize, bold: true,
                          maxWidth: w - G.rowTextDX)
            let span = events[0].spanNote(on: day, in: zone)
            if !span.isEmpty && G.rowTextDX + tw + 12 + Int(note.length(span)) <= w {
                text(span, x: x + G.rowTextDX + tw + 12, y: base, size: PageText.noteSize)
            }
            return y + G.allDayH
        }
        let itemW = titles.map { G.rowTextDX + Int(title.length($0)) }
        func plusW(_ rest: Int) -> Int { rest == 0 ? 0 : gap + Int(note.length("+\(rest)")) }
        var k = 1  // at least one item (cut if need be)
        while k < n && itemW[...k].reduce(0, +) + gap * k + plusW(n - k - 1) <= w { k += 1 }
        var cx = x
        for i in 0..<k {
            dot(cx: Double(cx + G.dotR), cy: cy, r: G.dotR, colour: events[i].accent)
            let room = w - (cx - x) - G.rowTextDX - (i == k - 1 ? plusW(n - k) : 0)
            let tw = text(titles[i], x: cx + G.rowTextDX, y: base, size: PageText.titleSize, bold: true, maxWidth: room)
            cx += G.rowTextDX + tw + gap
        }
        if k < n {
            text("+\(n - k)", x: cx, y: base, size: PageText.noteSize)
        }
        return y + G.allDayH
    }

    /// Two-line row: colour bar, bold title, "time range·location".
    mutating func card(x: Int, y: Int, w: Int, event: Event, day: LocalDate, zone: TimeZone) {
        cardBody(x: x, y: y, w: w, event: event, detail: event.detail(on: day, in: zone))
    }

    private mutating func cardBody(x: Int, y: Int, w: Int, event: Event, detail: String) {
        bar(x: x, y0: y + 4, y1: y + G.cardH - 11, colour: event.accent, width: G.cardBarW)
        text(PageText.title(event.title), x: x + G.rowTextDX, y: y + G.cardBase1, size: PageText.titleSize, bold: true,
             maxWidth: w - G.rowTextDX)
        text(detail, x: x + G.rowTextDX, y: y + G.cardBase2, size: PageText.noteSize, maxWidth: w - G.rowTextDX)
    }

    /// One-line row: start time, colour bar, title, and an optional right-aligned "還有 N 項".
    /// Titles are bold in the left-hand "today" lists, regular in the six-day list.
    mutating func lineRow(x: Int, y: Int, w: Int, event: Event, day: LocalDate, zone: TimeZone, more: String = "",
                          bold: Bool = false) {
        let base = y + G.lineBase
        text(event.startLabel(on: day, in: zone), x: x, y: base, size: PageText.noteSize)
        bar(x: x + G.lineTimeW, y0: y + 5, y1: y + G.lineH - 4, colour: event.accent, width: G.lineBarW)
        let mw = more.isEmpty ? 0 : text(more, x: x + w, y: base, size: PageText.noteSize, anchor: .right) + 12
        text(PageText.title(event.title), x: x + G.lineTitleDX, y: base, size: PageText.titleSize, bold: bold,
             maxWidth: w - G.lineTitleDX - mw)
    }

    /// `text` in 18 px on a line of its own; returns the y below it.
    mutating func noteLine(x: Int, y: Int, w: Int, _ note: String) -> Int {
        text(note, x: x, y: y + G.noteBase, size: PageText.noteSize, maxWidth: w)
        return y + G.noteH
    }

    /// Timed events as cards if all fit, else one-line rows, else rows and "還有 N 項".
    /// Returns the y below and the x where a following note starts.
    mutating func timedList(x: Int, y: Int, w: Int, bottom: Int, events: [Event], day: LocalDate,
                            zone: TimeZone) -> (y: Int, noteX: Int) {
        let n = events.count
        if n == 0 { return (y, x + G.rowTextDX) }
        var y = y
        let avail = bottom - y
        if n * G.cardH <= avail {
            for event in events {
                card(x: x, y: y, w: w, event: event, day: day, zone: zone)
                y += G.cardH
            }
            return (y, x + G.rowTextDX)
        }
        let k = n * G.lineH <= avail ? n : max(0, floorDivide(avail - G.noteH, G.lineH))
        for event in events.prefix(k) {
            lineRow(x: x, y: y, w: w, event: event, day: day, zone: zone, bold: true)
            y += G.lineH
        }
        if k < n && y + G.noteH <= bottom {
            y = noteLine(x: x, y: y, w: w, DayText.more(n - k))
        }
        return (y, x)
    }

    /// "明天" / "下一個行程" in 18 px bold after a 10 px gap; returns the y below it.
    mutating func sectionLabel(x: Int, y: Int, _ label: String, fill: PanelColour = .black) -> Int {
        text(label, x: x, y: y + G.sectionGap + 18, size: PageText.noteSize, bold: true, fill: fill)
        return y + G.sectionGap + G.sectionH
    }

    /// The "下一個行程" block: the label, then a card whose second line names the day
    /// ("明天 08:00·鼎泰豐", "10月1日 週四 09:30", "2027年1月1日 週五 全天"). Returns the y below.
    mutating func nextCard(x: Int, y: Int, w: Int, event: Event, today: LocalDate, zone: TimeZone) -> Int {
        let y = sectionLabel(x: x, y: y, "下一個行程")
        let d = event.localStart(in: zone).date
        let day = d == today.adding(days: 1)
            ? "明天" : "\(DayText.md(d, reference: today)) \(DayText.weekdayShort(d))"
        let detail = "\(day) \(event.startLabel(on: d, in: zone))" + Event.joined(PageFonts.clean(event.location))
        cardBody(x: x, y: y, w: w, event: event, detail: detail)
        return y + G.cardH
    }
}

/// Python's `a // b` (rounds towards minus infinity) for b > 0.
func floorDivide(_ a: Int, _ b: Int) -> Int {
    a >= 0 ? a / b : -((-a + b - 1) / b)
}
