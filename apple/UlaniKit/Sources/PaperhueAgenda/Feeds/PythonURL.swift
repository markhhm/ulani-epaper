import Foundation

/// An address split the way Python's `urllib.parse.urlparse` splits it, so that what the
/// Python reference accepts, refuses and rewrites in `normalize_url`, `where` and `owner`
/// is exactly what the app accepts, refuses and rewrites. Strings are handled as code points,
/// as Python indexes them.
struct PythonURL: Equatable {
    /// Lower-case; "" when there is none.
    var scheme = ""
    /// Everything between "//" and the path, as written; nil without "//".
    var netloc: String?
    var path = ""
    /// After ";" in the last path segment; nil without one.
    var params: String?
    var query: String?
    var fragment: String?

    struct Invalid: Error {}

    /// Python: `urlparse(url)`, which raises ValueError for a malformed bracketed host or a
    /// host that NFKC normalisation turns into another address.
    init(parsing text: String) throws {
        var url = Array(text.unicodeScalars)
        url = Array(url.drop { $0.value <= 0x20 })  // WHATWG C0 control or space
        url.removeAll { $0 == "\t" || $0 == "\r" || $0 == "\n" }
        if let i = url.firstIndex(of: ":"), i > 0, Self.isASCIILetter(url[0]),
           url[..<i].allSatisfy(Self.isSchemeCharacter) {
            scheme = Self.string(url[..<i]).lowercased()
            url = Array(url[(i + 1)...])
        }
        if url.starts(with: ["/", "/"]) {
            let end = url[2...].firstIndex { $0 == "/" || $0 == "?" || $0 == "#" } ?? url.endIndex
            let netloc = Array(url[2..<end])
            url = Array(url[end...])
            let open = netloc.contains("["), close = netloc.contains("]")
            if open != close { throw Invalid() }
            if open { try Self.checkBracketedNetloc(netloc) }
            self.netloc = Self.string(netloc)
        }
        if let i = url.firstIndex(of: "#") {
            fragment = Self.string(url[(i + 1)...])
            url = Array(url[..<i])
        }
        if let i = url.firstIndex(of: "?") {
            query = Self.string(url[(i + 1)...])
            url = Array(url[..<i])
        }
        if let netloc { try Self.checkNetloc(Array(netloc.unicodeScalars)) }
        if Self.usesParams.contains(scheme), url.contains(";") {
            // Python: _splitparams, the ";" after the last "/" (or the first one without a "/")
            let from = url.lastIndex(of: "/") ?? url.startIndex
            if let i = url[from...].firstIndex(of: ";") {
                params = Self.string(url[(i + 1)...])
                url = Array(url[..<i])
            }
        }
        path = Self.string(url)
    }

    /// Python: `urlunparse` for an address with a host (the only kind normalizeURL rebuilds).
    /// An empty query, fragment or params is left out, as Python does.
    var unparsed: String {
        var url = path
        if let params, !params.isEmpty { url += ";" + params }
        if let netloc, !netloc.isEmpty {
            if !url.isEmpty, !url.hasPrefix("/") { url = "/" + url }
            url = "//" + netloc + url
        }
        if !scheme.isEmpty { url = scheme + ":" + url }
        if let query, !query.isEmpty { url += "?" + query }
        if let fragment, !fragment.isEmpty { url += "#" + fragment }
        return url
    }

    /// Python: `.hostname`, the host without user, port or brackets, lower-cased up to an
    /// IPv6 zone ("%..."); nil when empty.
    var hostname: String? {
        guard let host = hostInfo?.host, !host.isEmpty else { return nil }
        let scalars = Array(host.unicodeScalars)
        let cut = scalars.firstIndex(of: "%") ?? scalars.endIndex
        return Self.pythonLower(Self.string(scalars[..<cut])) + Self.string(scalars[cut...])
    }

    /// Python: `.username` and `.password` (nil when the address has no "@" or no ":" in it).
    var userInfo: (username: String?, password: String?) {
        guard let netloc else { return (nil, nil) }
        let scalars = Array(netloc.unicodeScalars)
        guard let at = scalars.lastIndex(of: "@") else { return (nil, nil) }
        let info = scalars[..<at]
        guard let colon = info.firstIndex(of: ":") else { return (Self.string(info), nil) }
        return (Self.string(info[..<colon]), Self.string(info[(colon + 1)...]))
    }

    /// Python: `_hostinfo`'s host.
    private var hostInfo: (host: String, port: String?)? {
        guard let netloc else { return nil }
        var scalars = Array(netloc.unicodeScalars)
        if let at = scalars.lastIndex(of: "@") { scalars = Array(scalars[(at + 1)...]) }
        if let open = scalars.firstIndex(of: "[") {
            let bracketed = scalars[(open + 1)...]
            let close = bracketed.firstIndex(of: "]") ?? bracketed.endIndex
            let rest = close < bracketed.endIndex ? scalars[(close + 1)...] : []
            let port = rest.firstIndex(of: ":").map { Self.string(rest[($0 + 1)...]) }
            return (Self.string(bracketed[..<close]), port?.isEmpty == false ? port : nil)
        }
        let colon = scalars.firstIndex(of: ":") ?? scalars.endIndex
        let port = colon < scalars.endIndex ? Self.string(scalars[(colon + 1)...]) : ""
        return (Self.string(scalars[..<colon]), port.isEmpty ? nil : port)
    }

    // MARK: Python's checks

    /// Python's uses_params: the schemes whose last path segment may carry ";params".
    private static let usesParams: Set<String> = [
        "", "ftp", "hdl", "prospero", "http", "imap", "https", "shttp", "rtsp", "rtsps", "rtspu", "sip", "sips",
        "mms", "sftp", "tel",
    ]

    private static func isASCIILetter(_ c: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(c) || ("A"..."Z").contains(c)
    }

    private static func isSchemeCharacter(_ c: Unicode.Scalar) -> Bool {
        isASCIILetter(c) || ("0"..."9").contains(c) || c == "+" || c == "-" || c == "."
    }

    /// Python: `_checknetloc`. A non-ASCII host whose NFKC form has a "/", "?", "#", "@" or ":"
    /// that the written form lacks (U+2100 ℀ becomes "a/c") is refused.
    private static func checkNetloc(_ netloc: [Unicode.Scalar]) throws {
        guard !netloc.allSatisfy(\.isASCII) else { return }
        let n = netloc.filter { $0 != "@" && $0 != ":" && $0 != "#" && $0 != "?" }
        let folded = Array(string(n).precomposedStringWithCompatibilityMapping.unicodeScalars)
        if folded == n { return }
        if folded.contains(where: { "/?#@:".unicodeScalars.contains($0) }) { throw Invalid() }
    }

    /// Python: `_check_bracketed_netloc`: nothing before "[", only ":port" after "]", and the
    /// bracketed host an IPv6 address or "v<hex>.<anything>".
    private static func checkBracketedNetloc(_ netloc: [Unicode.Scalar]) throws {
        var hostAndPort = netloc[...]
        if let at = netloc.lastIndex(of: "@") { hostAndPort = netloc[(at + 1)...] }
        let host: ArraySlice<Unicode.Scalar>
        if let open = hostAndPort.firstIndex(of: "[") {
            if open != hostAndPort.startIndex { throw Invalid() }
            let bracketed = hostAndPort[(open + 1)...]
            let close = bracketed.firstIndex(of: "]") ?? bracketed.endIndex
            let port = close < bracketed.endIndex ? bracketed[(close + 1)...] : []
            if let first = port.first, first != ":" { throw Invalid() }
            host = bracketed[..<close]
        } else {
            host = hostAndPort[..<(hostAndPort.firstIndex(of: ":") ?? hostAndPort.endIndex)]
        }
        try checkBracketedHost(Array(host))
    }

    /// Python: `_check_bracketed_host`.
    private static func checkBracketedHost(_ host: [Unicode.Scalar]) throws {
        if host.first == "v" {
            // \Av[a-fA-F0-9]+\..+\z
            let digits = host.dropFirst().prefix { $0.properties.isASCIIHexDigit }
            let rest = host.dropFirst(1 + digits.count)
            guard !digits.isEmpty, rest.first == ".", rest.count > 1, !rest.dropFirst().contains("\n") else {
                throw Invalid()
            }
            return
        }
        if isIPv4(host) { throw Invalid() }  // Python: an IPv4 address cannot be in brackets
        guard isIPv6(host) else { throw Invalid() }
    }

    /// Python: `ipaddress.IPv4Address(text)` succeeds: four decimal octets 0-255, no leading zeros.
    static func isIPv4(_ text: some Collection<Unicode.Scalar>) -> Bool {
        let octets = text.split(separator: ".", omittingEmptySubsequences: false)
        guard !text.isEmpty, !text.contains("/"), octets.count == 4 else { return false }
        return octets.allSatisfy { o in
            guard !o.isEmpty, o.count <= 3, o.allSatisfy({ ("0"..."9").contains($0) }) else { return false }
            if o.count > 1, o.first == "0" { return false }
            return Int(string(o))! <= 255
        }
    }

    /// Python: `ipaddress.IPv6Address(text)` succeeds (with an optional "%zone").
    static func isIPv6(_ text: [Unicode.Scalar]) -> Bool {
        guard !text.contains("/") else { return false }
        var address = text[...]
        if let percent = text.firstIndex(of: "%") {
            let zone = text[(percent + 1)...]
            if zone.isEmpty || zone.contains("%") { return false }
            address = text[..<percent]
        }
        guard !address.isEmpty, address.count <= 45 else { return false }
        // Python: split(":", maxsplit=9)
        var parts: [ArraySlice<Unicode.Scalar>] = []
        var rest = address
        while parts.count < 9, let colon = rest.firstIndex(of: ":") {
            parts.append(rest[..<colon])
            rest = rest[(colon + 1)...]
        }
        parts.append(rest)
        guard parts.count >= 3 else { return false }
        if let last = parts.last, last.contains(".") {
            guard isIPv4(last) else { return false }
            parts.removeLast()
            parts += [["0"], ["0"]]  // two hextets; their value does not matter here
        }
        guard parts.count <= 9 else { return false }
        var skip: Int?
        for i in 1..<(parts.count - 1) where parts[i].isEmpty {
            if skip != nil { return false }
            skip = i
        }
        var hextets: [ArraySlice<Unicode.Scalar>]
        if let skip {
            var high = skip, low = parts.count - skip - 1
            if parts[0].isEmpty {
                high -= 1
                if high != 0 { return false }
            }
            if parts[parts.count - 1].isEmpty {
                low -= 1
                if low != 0 { return false }
            }
            if 8 - (high + low) < 1 { return false }
            hextets = Array(parts[..<high]) + Array(parts.suffix(low))
        } else {
            if parts.count != 8 || parts[0].isEmpty || parts[7].isEmpty { return false }
            hextets = parts
        }
        return hextets.allSatisfy { h in !h.isEmpty && h.count <= 4 && h.allSatisfy(\.properties.isASCIIHexDigit) }
    }

    // MARK: Python's string functions

    /// Python's `str.lower()`: each code point's full lower-case mapping, and Σ as final ς
    /// where Unicode's Final_Sigma rule says so (Swift's `lowercased()` has no such context).
    static func pythonLower(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        for (i, c) in scalars.enumerated() {
            guard c == "\u{03A3}" else {
                out.append(contentsOf: c.properties.lowercaseMapping.unicodeScalars)
                continue
            }
            let before = scalars[..<i].last { !$0.properties.isCaseIgnorable }
            var final = before?.properties.isCased == true
            if final {
                let after = scalars[(i + 1)...].first { !$0.properties.isCaseIgnorable }
                final = !(after?.properties.isCased ?? false)
            }
            out.append(final ? "\u{03C2}" : "\u{03C3}")
        }
        return String(out)
    }

    /// Python: `urllib.parse.quote(text, safe)`: UTF-8 bytes, letters, digits, "_.-~" and the
    /// ASCII characters of `safe` kept, everything else as "%XX" (upper-case hex).
    static func quote(_ text: String, safe: String) -> String {
        let keep = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-~".utf8)
            .union(safe.utf8.filter { $0 < 128 })
        var out = ""
        for byte in text.utf8 {
            if keep.contains(byte) {
                out.unicodeScalars.append(Unicode.Scalar(byte))
            } else {
                out += "%" + String(byte, radix: 16, uppercase: true).leftPadded(to: 2)
            }
        }
        return out
    }

    /// Python: `urllib.parse.unquote(text)`: "%XX" decoded within each run of ASCII
    /// characters, the bytes read as UTF-8 with U+FFFD for what is not; anything else kept.
    static func unquote(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        guard scalars.contains("%") else { return text }
        var out = ""
        var i = 0
        while i < scalars.count {
            guard scalars[i].isASCII else {
                out.unicodeScalars.append(scalars[i])
                i += 1
                continue
            }
            var bytes: [UInt8] = []
            while i < scalars.count, scalars[i].isASCII {
                if scalars[i] == "%", i + 2 < scalars.count, let hi = hexValue(scalars[i + 1]),
                   let lo = hexValue(scalars[i + 2]) {
                    bytes.append(UInt8(hi * 16 + lo))
                    i += 3
                } else {
                    bytes.append(UInt8(scalars[i].value))
                    i += 1
                }
            }
            out += String(decoding: bytes, as: UTF8.self)
        }
        return out
    }

    private static func hexValue(_ c: Unicode.Scalar) -> Int? {
        guard c.isASCII, let v = Int(String(c), radix: 16) else { return nil }
        return v
    }

    static func string(_ scalars: some Sequence<Unicode.Scalar>) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }
}

extension String {
    /// Padded with leading zeros to `width` characters.
    fileprivate func leftPadded(to width: Int) -> String {
        count >= width ? self : String(repeating: "0", count: width - count) + self
    }
}
