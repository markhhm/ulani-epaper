/// Calendar and message data for the pages (shared/AGENDA.md, shared/BOARD.md): the agenda
/// model, iCal parsing and recurrence, calendar sources and the owner's notes. Nothing read
/// from a calendar is stored: it is fetched, drawn, pushed and dropped.
public enum PaperhueAgenda {
    /// Python's `a < b` for strings: Unicode code points one by one, no normalisation and no
    /// locale (Swift's `<` treats canonically equivalent strings as equal).
    public static func codePointsPrecede(_ a: String, _ b: String) -> Bool {
        compareCodePoints(a, b) < 0
    }

    /// -1, 0 or 1 by code points.
    public static func compareCodePoints(_ a: String, _ b: String) -> Int {
        var i = a.unicodeScalars.makeIterator()
        var j = b.unicodeScalars.makeIterator()
        while true {
            switch (i.next(), j.next()) {
            case (nil, nil): return 0
            case (nil, _): return -1
            case (_, nil): return 1
            case let (x?, y?) where x != y: return x.value < y.value ? -1 : 1
            default: continue
            }
        }
    }
}
