import Foundation
import Testing
@testable import PaperhueAgenda

/// LocalDate, LocalDateTime and OffsetDateTime against Python's date, datetime and zones.
@Suite struct DateTimeTests {
    // MARK: LocalDate

    @Test func ordinalsAndWeekdaysMatchPython() throws {
        let dates = try Expectations.load().dates
        #expect(dates.count == 16)
        for d in dates {
            let date = try #require(LocalDate(iso: d.iso), "\(d.iso)")
            #expect(date.ordinal == d.ordinal, "\(d.iso)")
            #expect(date.weekday == d.weekday, "\(d.iso)")
            #expect(LocalDate(ordinal: d.ordinal) == date, "\(d.iso)")
            #expect(date.iso == d.iso)
        }
    }

    @Test func dayArithmetic() {
        #expect(day(2026, 10, 12).adding(days: 20) == day(2026, 11, 1))
        #expect(day(2026, 3, 1).adding(days: -1) == day(2026, 2, 28))
        #expect(day(2028, 3, 1).adding(days: -1) == day(2028, 2, 29))
        #expect(day(2026, 12, 31).adding(days: 1) == day(2027, 1, 1))
        #expect(day(2026, 10, 12).distance(to: day(2027, 10, 12)) == 365)
        #expect(day(2026, 10, 12).distance(to: day(2026, 10, 5)) == -7)
        #expect(Array(day(2026, 10, 30)...day(2026, 11, 2)).count == 4)
        #expect(day(2026, 10, 12).weekday == 0)  // a Monday
        #expect(day(2026, 10, 12) < day(2026, 10, 13) && day(2026, 9, 30) < day(2026, 10, 1))
        #expect(day(2026, 10, 12).firstOfMonth == day(2026, 10, 1))
        #expect(day(2026, 10, 12).firstOfNextMonth == day(2026, 11, 1))
        #expect(day(2026, 12, 31).firstOfNextMonth == day(2027, 1, 1))
        #expect(LocalDate.min.ordinal == 1 && LocalDate.max == day(9999, 12, 31))
        #expect(LocalDate(year: 2026, month: 2, day: 29) == nil && LocalDate(year: 2026, month: 13, day: 1) == nil)
        #expect(LocalDate(year: 2026, month: 4, day: 31) == nil && LocalDate(year: 2026, month: 1, day: 0) == nil)
        #expect(LocalDate.today(in: tpe, now: wall(2026, 10, 11, 16, 0).instant(in: utc)) == day(2026, 10, 12))
    }

    @Test func monthWeeksMatchPythonsCalendar() throws {
        let months = try Expectations.load().months
        #expect(months.count == 144)
        for m in months {
            let weeks = LocalDate.monthWeeks(year: m.year, month: m.month, firstWeekday: m.firstWeekday)
            let label = "\(m.year)-\(m.month) from \(m.firstWeekday)"
            #expect(weeks.count == m.weeks, "\(label)")
            #expect(weeks.first?.first == (try day(iso: m.first)), "\(label)")
            let flat = weeks.flatMap { $0 }
            #expect(weeks.allSatisfy { $0.count == 7 } && flat.first?.weekday == m.firstWeekday, "\(label)")
            #expect(zip(flat, flat.dropFirst()).allSatisfy { $0.adding(days: 1) == $1 }, "\(label)")
        }
        #expect(LocalDate.monthWeeks(year: 2026, month: 13, firstWeekday: 6).isEmpty)
    }

    // MARK: Zones

    @Test func wallTimesBecomeInstantsByFold0Rules() throws {
        let walls = try Expectations.load().walls
        #expect(walls.count == 41)
        var differences = 0
        for w in walls {
            let z = try zone(w.zone)
            let local = try wall(iso: w.wall)
            let got = local.instant(in: z)
            #expect(got == instant(micros: w.fold0), "\(w.zone) \(w.wall)")
            #expect(z.secondsFromGMT(for: got) == w.offset, "\(w.zone) \(w.wall)")
            if w.local != w.fold0 { differences += 1 }
        }
        // agenda.LOCAL (the OS's mktime) differs only for times a change skips or repeats.
        #expect(differences == 14)
    }

    @Test func instantsBecomeWallTimesAsAstimezone() throws {
        let instants = try Expectations.load().instants
        #expect(instants.count == 20)
        var localDiffers = 0
        for i in instants {
            let z = try zone(i.zone)
            let t = instant(micros: i.micros)
            #expect(LocalDateTime(t, in: z) == (try wall(iso: i.wall)), "\(i.zone) \(i.instant)")
            #expect(OffsetDateTime(t, in: z).utcOffset == i.offset, "\(i.zone) \(i.instant)")
            #expect(OffsetDateTime(t, in: z).instant == t, "\(i.zone) \(i.instant)")
            if i.localOffset != i.offset { localDiffers += 1 }
        }
        // agenda.LOCAL's utcoffset() of a repeated wall time is the OS's guess, not always the
        // offset of the instant it came from.
        #expect(localDiffers == 5)
    }

    @Test func wallClockArithmetic() {
        let w = wall(2026, 10, 12, 23, 59, 59, microsecond: 999_999)
        #expect(w.adding(microseconds: 1) == LocalDateTime(midnightOf: day(2026, 10, 13)))
        #expect(LocalDateTime(midnightOf: day(2026, 10, 13)).adding(microseconds: -1) == w)
        #expect(w.adding(seconds: -86_400).date == day(2026, 10, 11))
        #expect(w.iso == "2026-10-12T23:59:59.999999" && wall(2026, 10, 12, 9, 5).iso == "2026-10-12T09:05:00")
        #expect((w.hour, w.minute, w.second) == (23, 59, 59))
        #expect(LocalDateTime(date: day(2026, 10, 12), hour: 24, minute: 0) == nil)
        #expect(LocalDateTime(date: day(2026, 10, 12), hour: 0, minute: 0, microsecond: 1_000_000) == nil)
        let before1970 = instant(micros: -500_000)  // 1969-12-31T23:59:59.5Z
        #expect(LocalDateTime(before1970, in: utc) == wall(1969, 12, 31, 23, 59, 59, microsecond: 500_000))
    }

    @Test func instantsAreKeptToTheMicrosecond() {
        let t = OffsetDateTime(wall(2026, 10, 12, 9, 0, 0, microsecond: 123_456), utcOffset: 8 * 3600)
        let again = OffsetDateTime(t.instant, utcOffset: -3 * 3600 - 1800)
        #expect(again == t && again.hashValue == t.hashValue)
        #expect(again.iso == "2026-10-11T21:30:00.123456-03:30")
        #expect(OffsetDateTime(t.instant, in: tpe).wallClock == t.wallClock)
        #expect(t.converted(to: utc).iso == "2026-10-12T01:00:00.123456+00:00")
        #expect(t < OffsetDateTime(wall(2026, 10, 12, 1, 0, 0, microsecond: 123_457), utcOffset: 0))
    }

    // MARK: ISO 8601 text

    @Test func isoDateTimesAsPythonReadsThem() throws {
        let cases = try Expectations.load().iso
        #expect(cases.count >= 50)
        for c in cases {
            if c.isDateCase {
                let want = c.swiftRefuses ? nil : c.date
                #expect(LocalDate(iso: c.text)?.iso == want, "date \(c.text)")
                continue
            }
            let parsed = ISODateTime.parse(c.text)
            guard c.ok == true, !c.swiftRefuses else {
                #expect(parsed == nil, "\(c.text)")
                continue
            }
            let got = try #require(parsed, "\(c.text)")
            #expect(got.wall == (try wall(iso: try #require(c.wall))), "\(c.text)")
            #expect(got.utcOffset == c.offset, "\(c.text)")
            let value = OffsetDateTime(iso: c.text)
            if let micros = c.micros {
                let v = try #require(value, "\(c.text)")
                #expect(v.iso == c.isoformat, "\(c.text)")
                #expect(v.epochMicroseconds == micros, "\(c.text)")
                if (1900...2100).contains(v.wallClock.date.year) {  // a Date's Double is exact to the µs here
                    #expect(LocalDateTime.epochMicroseconds(v.instant) == micros, "\(c.text)")
                }
                #expect(OffsetDateTime(iso: v.iso) == v, "\(c.text)")
            } else {
                #expect(value == nil, "\(c.text): no offset")
            }
        }
    }

    @Test func offsetsAreWrittenAsPythonWritesThem() {
        #expect(OffsetDateTime.offsetText(0) == "+00:00")
        #expect(OffsetDateTime.offsetText(8 * 3600) == "+08:00")
        #expect(OffsetDateTime.offsetText(-(3 * 3600 + 1800)) == "-03:30")
        #expect(OffsetDateTime.offsetText(20_670) == "+05:44:30")
        #expect(OffsetDateTime.offsetText(-1) == "-00:00:01")
        #expect(OffsetDateTime(wall(1, 1, 1, 0, 0), utcOffset: 0).iso == "0001-01-01T00:00:00+00:00")
    }
}
