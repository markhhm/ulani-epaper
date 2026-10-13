import Foundation
import PaperhueAgenda
import UlaniKit

/// The calendar pages (shared/LAYOUTS.md; python/src/ulani_epaper/layouts.py): each one drawn
/// from the agenda, the page's date and its zone, never from the clock ("now" is the agenda's
/// sync time when that falls on `today`).
///
/// Any of them can sit on a photo (`background`, LAYOUTS.md 12: dithered to the panel's colours
/// first): the same strings in the same places, all text white with a black outline and the
/// colour marks outlined.
public enum CalendarPages {
    /// A white page, or one drawn on `background`.
    static func canvas(_ background: Frame?) -> PageCanvas {
        background.map(PageCanvas.init(background:)) ?? PageCanvas()
    }

    /// The today + month page (本日＋月曆, LAYOUTS.md 4; Python: `render_month`): today on the left (red
    /// weekday, large numeral, today's events, then tomorrow or the next event), the month
    /// containing `today` on the right with a dot per event in its calendar's colour.
    public static func month(_ data: AgendaData, today: LocalDate, zone: TimeZone,
                            background: Frame? = nil) -> PageCanvas {
        var page = canvas(background)
        MonthPage.draw(&page, data, today, zone)
        return page
    }
}

/// The month page's two halves and their geometry (layouts.py "Month").
enum MonthPage {
    private typealias G = PageGeometry

    static let panelX = G.margin
    static let panelW = 262
    /// 星期一, red bold.
    static let weekdaySize = 26
    /// Today's date, bold.
    static let numeralSize = 128
    static let numeralBase = 168
    static let listTop = 196
    /// 今天沒有行程.
    static let messageSize = 22

    /// 7 columns of about 64.6 px.
    static let gridX0 = 326, gridX1 = PageCanvas.width - G.margin + 6
    /// 2026年 regular + 10月 bold red.
    static let titleSize = 28
    static let weekdayRowBase = 98
    static let weekdayRowSize = 18
    static let gridTop = 110
    static let gridBottom = G.bottom + 2
    /// Row pitch = min(84, 354 / weeks): 84 (4 weeks), 70.8 (5), 59 (6).
    static let rowMax = 84.0
    static let daySize = 22
    /// Numeral centre below the row top.
    static let dayCY = 22.0
    /// Red disc behind today's numeral.
    static let todayR = 19
    /// Dot row below the numeral centre.
    static let dotDY = 28.0
    /// 10 px dots, 2 px apart.
    static let dotPitch = 12
    static let dotsMax = 4
    /// The "+" (2 px strokes) after the dots when a day has more events than dots.
    static let plus = 9

    static func draw(_ p: inout PageCanvas, _ data: AgendaData, _ today: LocalDate, _ zone: TimeZone) {
        panel(&p, data, today, zone)
        grid(&p, data, today, zone)
    }

    /// Today's panel: weekday, numeral, today's events, then tomorrow if there is room, or the
    /// next event when today is empty.
    static func panel(_ p: inout PageCanvas, _ data: AgendaData, _ today: LocalDate, _ zone: TimeZone) {
        let x = panelX, w = panelW
        p.text(DayText.weekdayLong(today), x: x, y: G.headerBase, size: weekdaySize, bold: true, fill: .red)
        p.text(String(today.day), x: x, y: numeralBase, size: numeralSize, bold: true)

        var y = listTop
        let events = data.eventsOn(today, in: zone)
        let (allDay, pending, ended) = splitDay(events, today, in: zone, now: data.now(today: today, in: zone))
        if events.isEmpty {
            p.text("今天沒有行程", x: x, y: y + 24, size: messageSize, bold: true)
            y += 34
        } else {
            if !allDay.isEmpty {
                y = p.allDayLine(x: x, y: y, w: w, events: allDay, day: today, zone: zone)
            }
            if pending.isEmpty && ended > 0 {
                p.text("今天沒有其他行程", x: x, y: y + 24, size: messageSize, bold: true)
                y += 34
            }
            let list = p.timedList(x: x, y: y, w: w, bottom: G.bottom - (ended > 0 ? G.noteH : 0), events: pending,
                                   day: today, zone: zone)
            y = list.y
            if ended > 0 {
                y = p.noteLine(x: list.noteX, y: y, w: w, "稍早已結束 \(ended) 項")
            }
        }

        // As the widget does: if today leaves room, go on with tomorrow.
        let tomorrow = today.adding(days: 1)
        let tomorrowEvents = data.eventsOn(tomorrow, in: zone)
        if !tomorrowEvents.isEmpty {
            let (tAllDay, tTimed, _) = splitDay(tomorrowEvents, tomorrow, in: zone, now: nil)
            let need = G.sectionGap + G.sectionH + (tAllDay.isEmpty ? 0 : G.allDayH) + (tTimed.isEmpty ? 0 : G.lineH)
            if y + need <= G.bottom {
                y = p.sectionLabel(x: x, y: y, "明天")
                if !tAllDay.isEmpty {
                    y = p.allDayLine(x: x, y: y, w: w, events: tAllDay, day: tomorrow, zone: zone)
                }
                _ = p.timedList(x: x, y: y, w: w, bottom: G.bottom, events: tTimed, day: tomorrow, zone: zone)
            }
            return
        }
        if !events.isEmpty { return }
        // Nothing today or tomorrow: name the next event instead of an empty panel.
        if let next = data.nextEvent(after: today, in: zone) {
            _ = p.nextCard(x: x, y: y, w: w, event: next, today: today, zone: zone)
        } else {
            // not "none at all": the data reaches only weeks ahead
            p.text("近期沒有行程", x: x, y: y + 22, size: PageText.noteSize)
        }
    }

    /// The month: title, sync stamp, weekday row, then the weeks with today on a red disc and
    /// up to four dots under each day.
    static func grid(_ p: inout PageCanvas, _ data: AgendaData, _ today: LocalDate, _ zone: TimeZone) {
        let cw = Double(gridX1 - gridX0) / 7
        let cxs = (0..<7).map { Double(gridX0) + cw * (Double($0) + 0.5) }

        // "2026年10月": the year regular black, the month bold red (zh-TW order).
        var tx = cxs[0] - 9
        tx += Double(p.text("\(today.year)年", x: tx, y: Double(G.headerBase), size: titleSize))
        p.text("\(today.month)月", x: tx, y: Double(G.headerBase), size: titleSize, bold: true, fill: .red)
        let sync = data.syncText(today: today, in: zone)
        if !sync.isEmpty {
            p.text(sync, x: PageCanvas.width - G.margin, y: G.headerBase, size: PageText.syncSize, anchor: .right)
        }

        for (i, label) in "日一二三四五六".enumerated() {
            p.text(String(label), x: cxs[i], y: Double(weekdayRowBase), size: weekdayRowSize, anchor: .centre)
        }

        let weeks = LocalDate.monthWeeks(year: today.year, month: today.month, firstWeekday: 6)
        let rh = min(rowMax, Double(gridBottom - gridTop) / Double(weeks.count))
        let digit = PageFont(size: daySize).verticalExtent(of: "0")
        for (r, week) in weeks.enumerated() {
            let cy = Double(gridTop) + rh * Double(r) + dayCY
            let base = cy - Double(digit.top + digit.bottom) / 2  // the digits optically centred on cy
            for (c, d) in week.enumerated() where d.month == today.month {  // other months stay blank
                let cx = cxs[c]
                if d == today {
                    p.disc(cx: cx, cy: cy, r: todayR, fill: .red)
                    p.text(String(d.day), x: cx, y: base, size: daySize, bold: true, fill: .white, anchor: .centre)
                } else {
                    p.text(String(d.day), x: cx, y: base, size: daySize, anchor: .centre)
                }
                drawDots(&p, cx: cx, dy: Int((cy + dotDY).rounded(.toNearestOrEven)), data.eventsOn(d, in: zone))
            }
        }
    }

    /// A day's dots (and the "+") centred on `cx`, on row `dy` (Python: `_draw_dots`).
    static func drawDots(_ p: inout PageCanvas, cx: Double, dy: Int, _ events: [Event]) {
        let (colours, more) = dots(events)
        if colours.isEmpty { return }
        var group = dotPitch * colours.count - (dotPitch - 2 * G.dotR)
        if more { group += 4 + plus }
        let gx = Int((cx - Double(group) / 2).rounded(.toNearestOrEven))
        for (j, colour) in colours.enumerated() {
            p.dot(cx: Double(gx + G.dotR + dotPitch * j), cy: Double(dy), r: G.dotR, colour: colour)
        }
        if more {
            p.plus(px: gx + group - plus, dy: dy, size: plus)
        }
    }

    /// Up to four dots for a day: each calendar colour once, in order of first appearance, then
    /// repeats to show the load, grouped by colour; `more` when the day has more events than
    /// dots (a "+" follows).
    static func dots(_ events: [Event]) -> (colours: [PanelColour], more: Bool) {
        let sequence = events.map(\.accent)
        var distinct: [PanelColour] = []
        for colour in sequence where !distinct.contains(colour) { distinct.append(colour) }
        var extra = sequence
        for colour in distinct { extra.remove(at: extra.firstIndex(of: colour)!) }
        let shown = Array((distinct + extra).prefix(dotsMax))
        // A stable sort by first appearance: the colours in `distinct` order, each run kept.
        let grouped = distinct.flatMap { colour in shown.filter { $0 == colour } }
        return (grouped, events.count > dotsMax)
    }
}
