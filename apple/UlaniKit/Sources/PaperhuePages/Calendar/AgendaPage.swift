import Foundation
import PaperhueAgenda

extension CalendarPages {
    /// The agenda page (LAYOUTS.md 5; Python: `render_agenda`): today on the left (the next
    /// event large, then the rest of today), the following six days on the right; a calm empty
    /// page when the whole week has no event.
    public static func agenda(_ data: AgendaData, today: LocalDate, zone: TimeZone) -> PageCanvas {
        var page = PageCanvas()
        AgendaPage.draw(&page, data, today, zone)
        return page
    }
}

/// The agenda page's columns and their geometry (layouts.py "Agenda").
enum AgendaPage {
    private typealias G = PageGeometry

    /// 星期一 (red) 10月12日 (black), bold.
    static let headerSize = 28
    static let top = 84
    static let leftX = G.margin, leftW = 326
    static let dividerX = 380
    static let rightX = 404
    static let rightW = PageCanvas.width - G.margin - rightX

    /// 接下來 / 進行中, red bold.
    static let heroLabelSize = 18
    /// Bold, up to 2 lines.
    static let heroTitleSize = 40
    static let heroTitlePitch = 52
    static let heroTimeSize = 26
    static let heroPlaceSize = 20
    static let heroBarW = 7
    static let heroTextDX = 22
    /// 今天沒有行程.
    static let heroMessageSize = 30

    /// The day number column of the six-day list.
    static let dayLabelW = 54
    /// Bold.
    static let dayNumberSize = 26
    /// Number + 明天 / 週三 / 11月.
    static let dayLabelH = 50
    static let daySubBase = 44
    static let dayGap = 6
    /// A list row with the end time and the location on a second line.
    static let fullRowH = 50
    static let fullBase2 = 44

    static func draw(_ p: inout PageCanvas, _ data: AgendaData, _ today: LocalDate, _ zone: TimeZone) {
        let days = (0..<7).map { today.adding(days: $0) }
        let perDay = days.map { data.eventsOn($0, in: zone) }
        if perDay.allSatisfy(\.isEmpty) {
            empty(&p, data, today, zone)
            return
        }
        header(&p, data, today, zone)
        todayColumn(&p, data, today, zone, perDay[0])
        p.hairlineV(x: dividerX, y0: top, y1: G.bottom)
        week(&p, Array(days.dropFirst()), Array(perDay.dropFirst()), zone)
    }

    /// "星期一 10月12日" ("2026年12月28日" when the week reaches into the next year) and the sync stamp.
    static func header(_ p: inout PageCanvas, _ data: AgendaData, _ today: LocalDate, _ zone: TimeZone) {
        let x = G.margin + p.text(DayText.weekdayLong(today), x: G.margin, y: G.headerBase, size: headerSize, bold: true,
                                  fill: .red) + 12
        let label = today.adding(days: 6).year == today.year ? DayText.md(today) : "\(today.year)年\(DayText.md(today))"
        p.text(label, x: x, y: G.headerBase, size: headerSize, bold: true)
        p.text(data.syncText(today: today, in: zone), x: PageCanvas.width - G.margin, y: G.headerBase,
               size: PageText.syncSize, anchor: .right)
    }

    /// Nothing all week: the date as a calendar icon and one calm message.
    static func empty(_ p: inout PageCanvas, _ data: AgendaData, _ today: LocalDate, _ zone: TimeZone) {
        let cx = PageCanvas.width / 2
        p.text(DayText.weekdayLong(today), x: cx, y: 100, size: 30, bold: true, fill: .red, anchor: .centre)
        p.text(String(today.day), x: cx, y: 232, size: 128, bold: true, anchor: .centre)
        p.text("\(today.year)年\(DayText.md(today))", x: cx, y: 274, size: 22, anchor: .centre)
        p.hairlineH(x0: cx - 150, x1: cx + 150, y: 298)
        p.text("今天沒有行程", x: cx, y: 346, size: 30, bold: true, anchor: .centre)
        p.text("接下來 6 天也沒有行程", x: cx, y: 380, size: 20, anchor: .centre)
        p.text(data.syncText(today: today, in: zone), x: PageCanvas.width - G.margin, y: G.headerBase,
               size: PageText.syncSize, anchor: .right)
    }

    /// The left column: the all-day line, the next event large (or a message and the next
    /// event after today), the rest of today, and how many events have ended.
    static func todayColumn(_ p: inout PageCanvas, _ data: AgendaData, _ today: LocalDate, _ zone: TimeZone,
                            _ events: [Event]) {
        let x = leftX, w = leftW
        let now = data.now(today: today, in: zone)
        let (allDay, pending, endedEarlier) = splitDay(events, today, in: zone, now: now)
        var ended = endedEarlier  // 0 once the message has said it
        var y = top
        if !allDay.isEmpty {
            y = p.allDayLine(x: x, y: y, w: w, events: allDay, day: today, zone: zone) + 6
        }

        if let hero = pending.first {
            let (s, e) = hero.localRange(in: zone)
            p.text(s <= now && now < e ? "進行中" : "接下來", x: x, y: y + 18, size: heroLabelSize, bold: true, fill: .red)
            y += 28
            let y0 = y
            let title = PageFont(size: heroTitleSize, bold: true)
            for line in PageText.wrap(PageText.title(hero.title), font: title, width: Double(w - heroTextDX), maxLines: 2) {
                p.text(line, x: x + heroTextDX, y: y + 42, size: heroTitleSize, bold: true)
                y += heroTitlePitch
            }
            p.text(hero.rangeText(on: today, in: zone), x: x + heroTextDX, y: y + 28, size: heroTimeSize,
                   maxWidth: w - heroTextDX)
            y += 36
            let place = PageFonts.clean(hero.location)
            if !place.isEmpty {
                p.text(place, x: x + heroTextDX, y: y + 24, size: heroPlaceSize, maxWidth: w - heroTextDX)
                y += 32
            }
            p.bar(x: x, y0: y0 + 10, y1: y - 6, colour: hero.accent, width: heroBarW)
            y += 14
        } else {
            p.text(events.isEmpty ? "今天沒有行程" : "今天沒有其他行程", x: x, y: y + 34, size: heroMessageSize, bold: true)
            y += 56
            if ended > 0 {
                y = p.noteLine(x: x, y: y, w: w, "稍早已結束 \(ended) 項")
                ended = 0
            }
            // Answer "what's next" even when today is done.
            if let next = data.nextEvent(after: today, in: zone), y + G.sectionGap + G.sectionH + G.cardH <= G.bottom {
                y = p.nextCard(x: x, y: y + 8, w: w, event: next, today: today, zone: zone)
            }
        }

        let rest = Array(pending.dropFirst())
        let reserve = ended > 0 ? G.noteH : 0
        var noteX = x
        if !rest.isEmpty && y + G.sectionH + G.lineH + reserve <= G.bottom {
            p.text("今天稍後", x: x, y: y + 18, size: PageText.noteSize, bold: true)
            (y, noteX) = p.timedList(x: x, y: y + G.sectionH, w: w, bottom: G.bottom - reserve, events: rest, day: today,
                                     zone: zone)
        } else if !rest.isEmpty {
            y = p.noteLine(x: x, y: y, w: w, DayText.more(rest.count))
        }
        if ended > 0 && y + G.noteH <= G.bottom {
            _ = p.noteLine(x: noteX, y: y, w: w, "稍早已結束 \(ended) 項")
        }
    }

    /// The right column: the next six days, each with its number and 明天 / 週X / M月, and as
    /// many of its events as fit. Every day first gets one compact row, then further compact
    /// rows go round-robin, earliest day first; then days switch to full rows (end time and
    /// location) in date order where that still fits: always when it costs no height, otherwise
    /// only once every event is shown. A cut day ends with "還有 N 項".
    static func week(_ p: inout PageCanvas, _ days: [LocalDate], _ perDay: [[Event]], _ zone: TimeZone) {
        let nx = rightX + dayLabelW, nw = rightW - dayLabelW
        let n = days.count

        func rowH(_ e: Event, _ i: Int, full: Bool) -> Int {
            // all-day and carried-over rows have no end time: one line
            full && !e.coversDay(days[i], in: zone) && !e.isContinuation(on: days[i], in: zone) ? fullRowH : G.lineH
        }
        func cost(_ i: Int, _ shown: Int, _ full: Bool) -> Int {
            max(dayLabelH, perDay[i].prefix(shown).reduce(0) { $0 + rowH($1, i, full: full) }) + dayGap
        }
        let budget = G.bottom - top + dayGap
        var shown = perDay.map { min($0.count, 1) }
        var full = Array(repeating: false, count: n)
        func total() -> Int { (0..<n).reduce(0) { $0 + cost($1, shown[$1], full[$1]) } }

        var grew = true
        while grew {
            grew = false
            for i in 0..<n where shown[i] < perDay[i].count {
                shown[i] += 1
                if total() <= budget { grew = true } else { shown[i] -= 1 }
            }
        }
        let everything = (0..<n).allSatisfy { shown[$0] == perDay[$0].count }
        for i in 0..<n where everything || cost(i, shown[i], true) == cost(i, shown[i], false) {
            full[i] = true
            if total() > budget { full[i] = false }
        }

        var y = top
        for (i, d) in days.enumerated() {
            let events = perDay[i]
            p.text(String(d.day), x: rightX, y: y + G.lineBase, size: dayNumberSize, bold: true)
            let sub = i == 0 ? "明天" : d.day == 1 ? "\(d.month)月" : DayText.weekdayShort(d)
            p.text(sub, x: rightX, y: y + daySubBase, size: PageText.noteSize)
            if events.isEmpty {
                p.text("沒有行程", x: nx + G.lineTitleDX, y: y + G.lineBase, size: PageText.noteSize)
            }
            var ry = y
            for (j, e) in events.prefix(shown[i]).enumerated() {
                let more = j == shown[i] - 1 && shown[i] < events.count ? DayText.more(events.count - shown[i]) : ""
                if full[i] && rowH(e, i, full: true) == fullRowH {
                    fullRow(&p, x: nx, y: ry, w: nw, event: e, day: d, zone: zone, more: more)
                } else {
                    p.lineRow(x: nx, y: ry, w: nw, event: e, day: d, zone: zone, more: more)
                }
                ry += rowH(e, i, full: full[i])
            }
            y += cost(i, shown[i], full[i])
        }
    }

    /// A six-day list row on two lines: start time and title, then the end time under the
    /// start time and the location under the title (and "還有 N 項" on the right).
    static func fullRow(_ p: inout PageCanvas, x: Int, y: Int, w: Int, event e: Event, day: LocalDate, zone: TimeZone,
                        more: String) {
        let base1 = y + G.lineBase, base2 = y + fullBase2
        p.text(e.startLabel(on: day, in: zone), x: x, y: base1, size: PageText.noteSize)
        p.text(e.endLabel(on: day, in: zone), x: x, y: base2, size: PageText.endTimeSize)
        p.bar(x: x + G.lineTimeW, y0: y + 5, y1: y + fullRowH - 6, colour: e.accent, width: G.lineBarW)
        let tx = x + G.lineTitleDX
        p.text(PageText.title(e.title), x: tx, y: base1, size: PageText.titleSize, maxWidth: w - G.lineTitleDX)
        let mw = more.isEmpty ? 0 : p.text(more, x: x + w, y: base2, size: PageText.noteSize, anchor: .right) + 12
        let place = PageFonts.clean(e.location)
        if !place.isEmpty {
            p.text(place, x: tx, y: base2, size: PageText.noteSize, maxWidth: w - G.lineTitleDX - mw)
        }
    }
}
