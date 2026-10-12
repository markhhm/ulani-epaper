import Foundation
import UlaniKit

/// What the command line asks for.
struct Invocation: Equatable, Sendable {
    enum Command: String, Sendable {
        case info, show, push, probe
    }

    enum Transport: Equatable, Sendable {
        case bluetooth
        case relay(host: String, port: UInt16)
    }

    var command: Command
    /// Image files (push, probe); the n-th goes to `pages[n]`.
    var images: [String] = []
    /// One page per image (push, probe), or the one page to put on screen (show).
    var pages: [Int] = []
    var transport: Transport = .bluetooth
    var fit: FitMode = .cover
    var dither = true
    /// `--strength`: how much of each pixel's error is diffused (1 = all).
    var strength = 1.0
    /// Encode and print the CRCs only.
    var dryRun = false
    /// Trace every command and reply on stderr.
    var verbose = false
    var scanTimeout: Duration = .seconds(30)
    /// `--flush-every`; nil: the transport's default.
    var flushEvery: Int?

    /// Image chunks between firmware-revision reads on the relay host: WinRT drops writes
    /// without them, so Python's default 10.
    var relayFlushEvery: Int { flushEvery ?? 10 }

    /// The session's read barrier over CoreBluetooth, which has real flow control: off
    /// unless asked for (a fallback switch).
    var readBarrierEvery: Int? { flushEvery.flatMap { $0 > 0 ? $0 : nil } }

    /// (page, image file) pairs, in the order given.
    var assignments: [(page: Int, path: String)] { Array(zip(pages, images)) }
}

/// The result of parsing: something to run, or a request for help / the version.
enum Parsed: Equatable, Sendable {
    case run(Invocation)
    case help
    case version
}

/// The command line is wrong (exit status 2).
struct UsageError: Error, Equatable, CustomStringConvertible {
    var description: String
}

/// Hand-written parser (no third-party dependency). Options go anywhere, as `--name value`
/// or `--name=value`; `--` ends the options.
enum Arguments {
    static let usage = """
        usage: ulani-swift [options] <command> [PAGE | IMAGE...]

        Push photos to the ULANI e-paper device from a Mac, over Bluetooth or through
        the TCP relay (python -m ulani_epaper.relay).

        commands:
          info                    model, firmware, serial, MAC, battery and the page on screen
          show PAGE               put page 1-4 on screen, as the device's button does; unless it
                                  is already there, the panel refreshes (~40 s)
          push IMAGE [IMAGE...]   put 1-4 images on pages 1-4 in one connection (the page on
                                  screen goes last); prints each page's CRC32/CRC16, the
                                  events, the order and the time taken
          probe IMAGE [IMAGE...]  check, header only, that the pages hold these images (encoded
                                  like push). A page that differs costs ~4 s, and whether it
                                  survives that is untested on hardware: probe after a push.

        connection:
          --relay HOST:PORT       through the relay (default: Bluetooth on this Mac)
          --ble                   Bluetooth (the default)
          --scan-timeout SEC      how long to look for the device (default 30)
          --flush-every N         read the firmware revision every N image chunks (0 = never;
                                  default 10 on the relay host, never over Bluetooth)

        images (push, probe):
          --fit cover|contain     cover = fill the panel and crop (default),
                                  contain = whole image on white
          --no-dither             nearest colour instead of Stucki dithering
          --strength S            dithering strength, 0 < S <= 1 (default 1; the app's grain
                                  levels are 1, 0.8, 0.65 and 0.5)
          --pages 1,2,3,4         the n-th image goes to the n-th listed page (default 1,2,...)
          --dry-run               encode and print the CRCs only, do not connect

          -v, --verbose           log every command and reply (hex) to stderr
          -h, --help              show this help
          --version               show the version

        exit status: 0 ok, 1 error (probe: also when a page differs), 2 usage, 130 interrupted

        """

    static func parse(_ arguments: [String]) throws(UsageError) -> Parsed {
        var invocation = Invocation(command: .info)
        var positional: [String] = []
        var imageOptions: [String] = []  // given, to reject them for info and show
        var pagesText: String?
        var optionsEnded = false
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let argument = arguments[index]
            index += 1
            if optionsEnded || !argument.hasPrefix("-") || argument == "-" {
                positional.append(argument)
                continue
            }
            if argument == "--" {
                optionsEnded = true
                continue
            }
            var name = argument, inline: String?
            if argument.hasPrefix("--"), let equals = argument.firstIndex(of: "=") {
                name = String(argument[..<equals])
                inline = String(argument[argument.index(after: equals)...])
            }
            func value() throws(UsageError) -> String {
                if let inline { return inline }
                guard index < arguments.endIndex else { throw UsageError(description: "\(name) needs a value") }
                defer { index += 1 }
                return arguments[index]
            }
            func flag() throws(UsageError) {
                if inline != nil { throw UsageError(description: "\(name) takes no value") }
            }
            switch name {
            case "-h", "--help":
                return .help
            case "--version":
                return .version
            case "-v", "--verbose":
                try flag()
                invocation.verbose = true
            case "--ble":
                try flag()
                invocation.transport = .bluetooth
            case "--relay":
                invocation.transport = try relay(value())
            case "--scan-timeout":
                let text = try value()
                // Bounded, so the milliseconds fit an Int64 and are never 0.
                guard let seconds = Double(text), (0.001...86_400).contains(seconds) else {
                    throw UsageError(description: "--scan-timeout expects 0.001 to 86400 seconds, got '\(text)'")
                }
                invocation.scanTimeout = .milliseconds(Int64((seconds * 1000).rounded()))
            case "--flush-every":
                let text = try value()
                guard let count = Int(text), count >= 0 else {
                    throw UsageError(description: "--flush-every expects a number >= 0, got '\(text)'")
                }
                invocation.flushEvery = count
            case "--fit":
                let text = try value()
                guard let fit = FitMode(rawValue: text) else {
                    throw UsageError(description: "--fit expects cover or contain, got '\(text)'")
                }
                invocation.fit = fit
                imageOptions.append(name)
            case "--no-dither":
                try flag()
                invocation.dither = false
                imageOptions.append(name)
            case "--strength":
                let text = try value()
                guard let strength = Double(text), strength > 0, strength <= 1 else {
                    throw UsageError(description: "--strength expects a number above 0 and at most 1, got '\(text)'")
                }
                invocation.strength = strength
                imageOptions.append(name)
            case "--pages":
                pagesText = try value()
                imageOptions.append(name)
            case "--dry-run":
                try flag()
                invocation.dryRun = true
                imageOptions.append(name)
            default:
                throw UsageError(description: "unknown option '\(argument)'")
            }
        }

        guard let word = positional.first else {
            throw UsageError(description: "missing command (info, show, push or probe)")
        }
        guard let command = Invocation.Command(rawValue: word) else {
            throw UsageError(description: "unknown command '\(word)'")
        }
        invocation.command = command
        let operands = Array(positional.dropFirst())
        switch command {
        case .info:
            guard operands.isEmpty else { throw UsageError(description: "info takes no images") }
            if let option = imageOptions.first {
                throw UsageError(description: "\(option) applies to push and probe only")
            }
        case .show:
            guard operands.count == 1 else {
                throw UsageError(description: "show needs one page (1-4), got \(operands.count) arguments")
            }
            guard let page = Int(operands[0]), Panel.userSlots.contains(page) else {
                throw UsageError(description: "show expects a page 1-4, got '\(operands[0])'")
            }
            if let option = imageOptions.first {
                throw UsageError(description: "\(option) applies to push and probe only")
            }
            invocation.pages = [page]
        case .push, .probe:
            guard (1...Panel.userSlots.count).contains(operands.count) else {
                throw UsageError(description: "\(word) needs 1-4 images (one per page), got \(operands.count)")
            }
            let pages = try pagesText.map { text throws(UsageError) in try Self.pages(text) }
                ?? Array(1...operands.count)
            guard pages.count == operands.count else {
                throw UsageError(description: "--pages lists \(pages.count) page(s) for \(operands.count) image(s)")
            }
            invocation.images = operands
            invocation.pages = pages
        }
        return .run(invocation)
    }

    /// `HOST:PORT`; an IPv6 host goes in brackets (`[::1]:8765`).
    private static func relay(_ text: String) throws(UsageError) -> Invocation.Transport {
        let invalid = UsageError(description: "--relay expects HOST:PORT, got '\(text)'")
        guard let colon = text.lastIndex(of: ":") else { throw invalid }
        var host = String(text[..<colon])
        if host.hasPrefix("[") && host.hasSuffix("]") && host.count > 2 {
            host = String(host.dropFirst().dropLast())
        }
        guard !host.isEmpty, let port = UInt16(text[text.index(after: colon)...]), port > 0 else { throw invalid }
        return .relay(host: host, port: port)
    }

    /// `1,3`: distinct pages 1-4.
    private static func pages(_ text: String) throws(UsageError) -> [Int] {
        let invalid = UsageError(description: "--pages expects pages 1-4 separated by commas, got '\(text)'")
        var pages: [Int] = []
        for item in text.split(separator: ",", omittingEmptySubsequences: false) {
            guard let page = Int(item.trimmingCharacters(in: .whitespaces)), Panel.userSlots.contains(page) else {
                throw invalid
            }
            guard !pages.contains(page) else { throw UsageError(description: "--pages lists page \(page) twice") }
            pages.append(page)
        }
        return pages
    }
}
