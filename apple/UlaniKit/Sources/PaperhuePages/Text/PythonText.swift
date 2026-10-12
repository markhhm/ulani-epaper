/// Python's string rules the text rules are written in. Strings are handled as code points, as
/// Python indexes and slices them (a Swift Character can hold several).
enum PythonText {
    /// `str.isspace()` (and `\s` in `re`): Unicode White_Space plus the C0 separators
    /// U+001C...U+001F.
    static func isSpace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09...0x0D, 0x1C...0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000:
            true
        default:
            false
        }
    }

    /// `s.isspace()` for a whole string: not empty, and only whitespace.
    static func isAllSpace(_ scalars: some Collection<Unicode.Scalar>) -> Bool {
        !scalars.isEmpty && scalars.allSatisfy(isSpace)
    }

    /// `s.rstrip()`.
    static func rstrip(_ scalars: ArraySlice<Unicode.Scalar>) -> ArraySlice<Unicode.Scalar> {
        scalars[..<(scalars.lastIndex { !isSpace($0) }.map { $0 + 1 } ?? scalars.startIndex)]
    }

    /// `s.strip()`.
    static func strip(_ scalars: ArraySlice<Unicode.Scalar>) -> ArraySlice<Unicode.Scalar> {
        let tail = rstrip(scalars)
        return tail[(tail.firstIndex { !isSpace($0) } ?? tail.endIndex)...]
    }

    static func string(_ scalars: some Sequence<Unicode.Scalar>) -> String {
        String(String.UnicodeScalarView(scalars))
    }
}
