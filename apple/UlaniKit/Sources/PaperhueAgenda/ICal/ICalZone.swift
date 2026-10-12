import Foundation

/// A Python `tzinfo` as the iCal reader meets it: a fixed offset, a zoneinfo (IANA) zone, or a
/// feed's own VTIMEZONE.
///
/// Two values are the same zone when Python would hold one tzinfo object: one IANA name, one
/// fixed offset, one VTIMEZONE of one file. `ICalDateTime` compares and subtracts on the wall
/// clock within one zone.
public enum ICalZone: Hashable, Sendable, CustomStringConvertible {
    /// Seconds east of UTC (Python's `timezone(timedelta(...))`).
    case fixed(seconds: Int)
    /// `zoneinfo.ZoneInfo(key)`, with the system's zone data.
    case system(TimeZone)
    case vtimezone(VTimezone)

    /// What a DATE-TIME ending in `Z` is in (icalendar: `ZoneInfo("UTC")`).
    public static let utc = ICalZone.system(TimeZone(identifier: "UTC")!)

    /// `ZoneInfo(key)`: nil unless `key` is one of zoneinfo's names (exactly; "GMT+8" is not).
    public static func zoneinfo(_ key: String) -> ICalZone? {
        guard ZoneTables.ianaNames.contains(key), let zone = TimeZone(identifier: key) else { return nil }
        return .system(zone)
    }

    /// `utcoffset()` of a wall time in this zone, in seconds, with fold=0: zoneinfo takes the
    /// offset from before a change for a time it skips and the first of a repeated time; a
    /// VTIMEZONE follows dateutil (see `VTimezone`).
    public func utcOffset(_ wall: LocalDateTime) -> Int {
        switch self {
        case .fixed(let seconds):
            return seconds
        case .system(let zone):
            let instant = LocalDateTime.epochMicroseconds(wall.instant(in: zone))
            return (wall.wallMicroseconds - instant) / 1_000_000
        case .vtimezone(let definition):
            return definition.utcOffset(wall)
        }
    }

    /// The wall clock at `instant` (Python: `astimezone`).
    public func wallClock(at instant: Date) -> LocalDateTime {
        switch self {
        case .fixed(let seconds):
            return LocalDateTime(wallMicroseconds: LocalDateTime.epochMicroseconds(instant) + seconds * 1_000_000)
        case .system(let zone):
            return LocalDateTime(instant, in: zone)
        case .vtimezone(let definition):
            return definition.wallClock(at: instant)
        }
    }

    /// "+08:00", "Asia/Taipei", "VTIMEZONE Custom/Eastern".
    public var description: String {
        switch self {
        case .fixed(let seconds): OffsetDateTime.offsetText(seconds)
        case .system(let zone): zone.identifier
        case .vtimezone(let definition): "VTIMEZONE " + definition.tzid
        }
    }
}

/// How icalendar finds the zone of a TZID (its `tzp` with the zoneinfo provider). One per file:
/// ical.py calls `icalendar.use_zoneinfo()` before each feed, which empties the cache.
///
/// A TZID is tried as written without surrounding "/", as a Windows name ("Taipei Standard
/// Time", through CLDR's table), for "/vendor/Area/City" as the trailing names (longest
/// first), then as written; each name in the cache first, then as an IANA name. The first zone
/// found is cached under the first name. A VTIMEZONE is cached under its TZID when it ends,
/// unless the TZID is an IANA name or already cached: so a Windows name defined before its
/// first use takes the file's definition, and one used before it is defined the Windows zone.
final class ZoneResolver {
    private var cache: [String: ICalZone] = [:]

    func zone(_ tzid: String) -> ICalZone? {
        let cleaned = Self.cleaned(tzid)
        var names = [cleaned]
        if let iana = ZoneTables.windowsToIANA[cleaned] { names.append(iana) }
        if tzid.hasPrefix("/") {
            let parts = cleaned.split(separator: "/", omittingEmptySubsequences: false)
            names += parts.indices.dropFirst().map { parts[$0...].joined(separator: "/") }
        }
        names.append(tzid)
        for name in names {
            if let zone = cache[name] ?? ICalZone.zoneinfo(name) {
                cache[cleaned] = zone
                return zone
            }
        }
        return nil
    }

    /// At the end of a VTIMEZONE. Throws `ICalError` for a definition that cannot be read (in
    /// Python, too, that fails the file).
    func define(_ component: ICalComponent) throws {
        let tzid = component.first("TZID")?.text ?? ""
        let id = Self.cleaned(tzid)
        guard !ZoneTables.ianaNames.contains(id), !ZoneTables.ianaNames.contains(tzid), cache[id] == nil else { return }
        cache[id] = .vtimezone(try VTimezone(component))
    }

    private static func cleaned(_ tzid: String) -> String {
        tzid.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}
