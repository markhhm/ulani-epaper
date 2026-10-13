import Foundation
import PaperhueAgenda

extension CalendarPages {
    /// The full month page (月曆, id monthgrid, LAYOUTS.md; Python: `render_monthgrid`): the
    /// month containing `today` over the whole page. Only Sundays are red (holidays are events
    /// like any other). Each day has its event dots; where a row is tall enough (5 weeks or
    /// fewer) the first events' short titles sit under the dots.
    public static func monthGrid(_ data: AgendaData, today: LocalDate, zone: TimeZone) -> PageCanvas {
        var page = PageCanvas()
        MonthGridPage.draw(&page, data, today, zone)
        return page
    }
}

/// The full month page's geometry (layouts.py "Month grid").
enum MonthGridPage {
    private typealias G = PageGeometry

    static let x0 = G.margin, x1 = PageCanvas.width - G.margin  // 7 columns of 106.3 px
    static let titleSize = 28  // 2026年 regular + 10月 bold red
    static let weekdayBase = 86
    static let top = 96
    static let bottom = G.bottom + 2
    static let dayCY = 18.0  // numeral centre below the row top
    static let todayR = 16
    static let dotDY = 26.0  // dot row below the numeral centre
    static let titleDY = 66.0  // baseline of the first short title below the row top
    static let titlePitch = 22.0
    static let titlePad = 6.0  // the title may use the cell width less this much on each side

    static func draw(_ p: inout PageCanvas, _ data: AgendaData, _ today: LocalDate, _ zone: TimeZone) {
        let cw = Double(x1 - x0) / 7
        let cxs = (0..<7).map { Double(x0) + cw * (Double($0) + 0.5) }
        let x = G.margin + p.text("\(today.year)年", x: G.margin, y: G.headerBase, size: titleSize)
        p.text("\(today.month)月", x: x, y: G.headerBase, size: titleSize, bold: true, fill: .red)
        let sync = data.syncText(today: today, in: zone)
        if !sync.isEmpty {
            p.text(sync, x: PageCanvas.width - G.margin, y: G.headerBase, size: PageText.syncSize, anchor: .right)
        }
        for (i, label) in "日一二三四五六".enumerated() {
            p.text(String(label), x: cxs[i], y: Double(weekdayBase), size: MonthPage.weekdayRowSize,
                   fill: i == 0 ? .red : .black, anchor: .centre)
        }

        let weeks = LocalDate.monthWeeks(year: today.year, month: today.month, firstWeekday: 6)
        let rh = Double(bottom - top) / Double(weeks.count)
        let lines = max(0, Int(((rh - titleDY - 6) / titlePitch).rounded(.down)) + 1)  // titles that fit in a row
        let digit = PageFont(size: MonthPage.daySize).verticalExtent(of: "0")
        for (r, week) in weeks.enumerated() {
            let row = Double(top) + rh * Double(r)
            let cy = row + dayCY
            let base = cy - Double(digit.top + digit.bottom) / 2
            for (c, d) in week.enumerated() where d.month == today.month {
                let cx = cxs[c]
                if d == today {
                    p.disc(cx: cx, cy: cy, r: todayR, fill: .red)
                    p.text(String(d.day), x: cx, y: base, size: MonthPage.daySize, bold: true, fill: .white,
                           anchor: .centre)
                } else {
                    p.text(String(d.day), x: cx, y: base, size: MonthPage.daySize, fill: c == 0 ? .red : .black,
                           anchor: .centre)
                }
                let events = data.eventsOn(d, in: zone)
                MonthPage.drawDots(&p, cx: cx, dy: Int((cy + dotDY).rounded(.toNearestOrEven)), events)
                for (k, e) in events.prefix(lines).enumerated() {
                    p.text(PageText.title(e.title), x: cx, y: row + titleDY + titlePitch * Double(k),
                           size: PageText.noteSize, anchor: .centre, maxWidth: cw - 2 * titlePad)
                }
            }
        }
    }
}
