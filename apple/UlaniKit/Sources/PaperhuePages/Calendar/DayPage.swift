import Foundation
import PaperhueAgenda

extension CalendarPages {
    /// The day page (日, LAYOUTS.md; Python: `render_day`): the big date and weekday on the
    /// left, all of today's events on the right (also those that have ended, so the page does
    /// not depend on the time of the sync).
    public static func day(_ data: AgendaData, today: LocalDate, zone: TimeZone) -> PageCanvas {
        var page = PageCanvas()
        DayPage.draw(&page, data, today, zone)
        return page
    }
}

/// The day page's geometry (layouts.py "Day").
enum DayPage {
    private typealias G = PageGeometry

    static let weekdaySize = 32
    static let numeralSize = 180
    static let numeralBase = 232
    static let monthSize = 24
    static let monthBase = 276
    static let listX = 326
    static let listW = PageCanvas.width - G.margin - listX
    static let listTop = AgendaPage.top

    static func draw(_ p: inout PageCanvas, _ data: AgendaData, _ today: LocalDate, _ zone: TimeZone) {
        p.text(DayText.weekdayLong(today), x: G.margin, y: G.headerBase, size: weekdaySize, bold: true, fill: .red)
        p.text(String(today.day), x: G.margin, y: numeralBase, size: numeralSize, bold: true)
        p.text("\(today.year)年\(today.month)月", x: G.margin, y: monthBase, size: monthSize)
        let sync = data.syncText(today: today, in: zone)
        if !sync.isEmpty {
            p.text(sync, x: PageCanvas.width - G.margin, y: G.headerBase, size: PageText.syncSize, anchor: .right)
        }

        let (x, w) = (listX, listW)
        var y = listTop
        let events = data.eventsOn(today, in: zone)
        if !events.isEmpty {
            let (allDay, timed, _) = splitDay(events, today, in: zone, now: nil)
            if !allDay.isEmpty {
                y = p.allDayLine(x: x, y: y, w: w, events: allDay, day: today, zone: zone) + 6
            }
            _ = p.timedList(x: x, y: y, w: w, bottom: G.bottom, events: timed, day: today, zone: zone)
            return
        }
        p.text("今天沒有行程", x: x, y: y + 34, size: AgendaPage.heroMessageSize, bold: true)
        y += 56
        if let next = data.nextEvent(after: today, in: zone) {
            if y + 8 + G.sectionGap + G.sectionH + G.cardH <= G.bottom {
                _ = p.nextCard(x: x, y: y + 8, w: w, event: next, today: today, zone: zone)
            }
        } else {
            p.text("近期沒有行程", x: x, y: y + 22, size: PageText.noteSize)
        }
    }
}
