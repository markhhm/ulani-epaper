import Foundation
import PaperhueAgenda

// The shared data rules of the calendar pages (shared/LAYOUTS.md 2): which events a day shows
// and how, the labels of the time column and the cards, "now" and the sync stamp, as in
// python/src/ulani_epaper/layouts.py ("Dates and events"). Times are compared on the wall
// clock of the page's zone, as the reference compares datetimes that share a tzinfo.

/// The date and count wording of the pages.
enum DayText {
    /// "一二三四五六日", indexed by `LocalDate.weekday` (Monday 0).
    static let weekdays = Array("一二三四五六日")

    /// "09:00": 24 hours, zero-padded.
    static func hm(_ t: LocalDateTime) -> String {
        (t.hour < 10 ? "0" : "") + "\(t.hour):" + (t.minute < 10 ? "0" : "") + "\(t.minute)"
    }

    /// "10月12日".
    static func md(_ d: LocalDate) -> String { "\(d.month)月\(d.day)日" }

    /// "10月15日", or "2027年3月1日" when the year differs from `reference`'s.
    static func md(_ d: LocalDate, reference: LocalDate) -> String {
        d.year == reference.year ? md(d) : "\(d.year)年\(md(d))"
    }

    /// "星期一".
    static func weekdayLong(_ d: LocalDate) -> String { "星期\(weekdays[d.weekday])" }

    /// "週一".
    static func weekdayShort(_ d: LocalDate) -> String { "週\(weekdays[d.weekday])" }

    /// "還有 N 項".
    static func more(_ n: Int) -> String { "還有 \(n) 項" }
}

/// 00:00 of `day` and of the day after.
func dayBounds(_ day: LocalDate) -> (start: LocalDateTime, end: LocalDateTime) {
    (LocalDateTime(midnightOf: day), LocalDateTime(midnightOf: day.adding(days: 1)))
}

extension Event {
    /// All-day, or timed and spanning the whole of `day` (drawn like all-day: "全天").
    func coversDay(_ day: LocalDate, in zone: TimeZone) -> Bool {
        if allDay { return true }
        let (s, e) = localRange(in: zone)
        let (ds, de) = dayBounds(day)
        return s <= ds && e >= de
    }

    /// Not over yet at `now`; a zero-length event is pending until it starts.
    func isPending(at now: LocalDateTime, in zone: TimeZone) -> Bool {
        let (s, e) = localRange(in: zone)
        return e > now || (s == e && s >= now)
    }

    /// Started on an earlier day and does not cover `day`: drawn as "至HH:MM".
    func isContinuation(on day: LocalDate, in zone: TimeZone) -> Bool {
        !coversDay(day, in: zone) && localStart(in: zone) < dayBounds(day).start
    }

    /// "第 2 天，共 3 天" for an event spanning several days, else "".
    func spanNote(on day: LocalDate, in zone: TimeZone) -> String {
        let (s, e) = localRange(in: zone)
        let first = s.date
        let last = e > s ? e.adding(microseconds: -1).date : first
        let total = first.distance(to: last) + 1
        return total <= 1 ? "" : "第 \(first.distance(to: day) + 1) 天，共 \(total) 天"
    }

    /// Time column, line 1: "HH:MM", "全天", or "至HH:MM" for a carried-over event.
    func startLabel(on day: LocalDate, in zone: TimeZone) -> String {
        if coversDay(day, in: zone) { return "全天" }
        let (s, e) = localRange(in: zone)
        return s < dayBounds(day).start ? "至" + DayText.hm(e) : DayText.hm(s)
    }

    /// Time column, line 2: the end time, or the end date "M/D" when a bare time would
    /// mislead. "HH:MM" if it ends on `day` (00:00 for midnight) or early the next day before
    /// its start time (23:00 over 01:00 can only mean the next morning). Empty for all-day,
    /// carried-over and zero-length events.
    func endLabel(on day: LocalDate, in zone: TimeZone) -> String {
        if coversDay(day, in: zone) { return "" }
        let (s, e) = localRange(in: zone)
        let (ds, de) = dayBounds(day)
        if s == e || s < ds { return "" }
        if e <= de { return DayText.hm(e) }
        if e.date == day.adding(days: 1) && (e.secondOfDay, e.microsecond) < (s.secondOfDay, s.microsecond) {
            return DayText.hm(e)
        }
        return "\(e.date.month)/\(e.date.day)"
    }

    /// The time range as seen on `day`, with no words relative to the reader's today:
    /// "10:00 – 11:30", "23:00 – 00:00", "23:00 – 隔天 01:00", "20:00 – 12月31日 20:00",
    /// "至 01:00" (carried over), "全天" / "全天·第 2 天，共 3 天".
    func rangeText(on day: LocalDate, in zone: TimeZone) -> String {
        if coversDay(day, in: zone) {
            let note = spanNote(on: day, in: zone)
            return note.isEmpty ? "全天" : "全天\(PageText.separator)\(note)"
        }
        let (s, e) = localRange(in: zone)
        if s == e { return DayText.hm(s) }
        let (ds, de) = dayBounds(day)
        if s < ds { return "至 \(DayText.hm(e))" }
        if e <= de { return "\(DayText.hm(s)) – \(DayText.hm(e))" }
        if e.date == day.adding(days: 1) { return "\(DayText.hm(s)) – 隔天 \(DayText.hm(e))" }
        return "\(DayText.hm(s)) – \(DayText.md(e.date, reference: day)) \(DayText.hm(e))"
    }

    /// A card's second line: the time range, then "·" and the cleaned location if any.
    func detail(on day: LocalDate, in zone: TimeZone) -> String {
        rangeText(on: day, in: zone) + Self.joined(PageFonts.clean(location))
    }

    /// "·" + `text`, or "" when there is no text.
    static func joined(_ text: String) -> String { text.isEmpty ? "" : PageText.separator + text }

    /// The calendar colour as a panel colour.
    var accent: PanelColour { PanelColour.accent(color) }
}

extension AgendaData {
    /// The sync time if it falls on `today`, else 00:00 of `today`.
    func now(today: LocalDate, in zone: TimeZone) -> LocalDateTime {
        let (ds, de) = dayBounds(today)
        if let fetchedAt {
            let t = fetchedAt.local(in: zone)
            if ds <= t && t < de { return t }
        }
        return ds
    }

    /// "更新於 10/12" ("更新於 2025/12/31" in another year than `today`'s): the date only, never
    /// the time, so two syncs on the same day with nothing starting or ending in between draw
    /// the same page (the device then skips it). "" without a sync time.
    func syncText(today: LocalDate, in zone: TimeZone) -> String {
        guard let t = fetchedAt?.local(in: zone).date else { return "" }
        return t.year == today.year ? "更新於 \(t.month)/\(t.day)" : "更新於 \(t.year)/\(t.month)/\(t.day)"
    }

    /// The first event starting on a day after `after`: by local start, all-day first, then
    /// title (code points); the first of equals.
    func nextEvent(after: LocalDate, in zone: TimeZone) -> Event? {
        let start = dayBounds(after).end
        var best: (event: Event, start: LocalDateTime)?
        for event in events {
            let s = event.localStart(in: zone)
            guard s >= start else { continue }
            if let b = best {
                if s != b.start {
                    guard s < b.start else { continue }
                } else if event.allDay != b.event.allDay {
                    guard event.allDay else { continue }
                } else {
                    guard PaperhueAgenda.codePointsPrecede(event.title, b.event.title) else { continue }
                }
            }
            best = (event, s)
        }
        return best?.event
    }
}

/// A day's events split for drawing: the ones drawn like all-day ("全天"), the timed ones still
/// pending at `now` (all of them when `now` is nil, as for tomorrow), and how many timed ones
/// have ended.
func splitDay(_ events: [Event], _ day: LocalDate, in zone: TimeZone, now: LocalDateTime?)
    -> (allDay: [Event], pending: [Event], ended: Int) {
    let allDay = events.filter { $0.coversDay(day, in: zone) }
    let timed = events.filter { !$0.coversDay(day, in: zone) }
    let pending = now.map { now in timed.filter { $0.isPending(at: now, in: zone) } } ?? timed
    return (allDay, pending, timed.count - pending.count)
}
