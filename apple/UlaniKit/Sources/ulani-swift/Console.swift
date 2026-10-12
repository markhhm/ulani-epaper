import Foundation

/// Where the CLI writes: results and events to stdout; the progress bar, the `--verbose`
/// trace and errors to stderr. Writes are unbuffered, so the two interleave in order.
struct Console: Sendable {
    /// Write text as is (callers add the newlines).
    var writeOut: @Sendable (String) -> Void
    var writeErr: @Sendable (String) -> Void
    /// stderr is a terminal: progress is a bar redrawn with `\r`, not lines.
    var interactive: Bool

    static let standard = Console(
        writeOut: { FileHandle.standardOutput.write(Data($0.utf8)) },
        writeErr: { FileHandle.standardError.write(Data($0.utf8)) },
        interactive: isatty(STDERR_FILENO) != 0)

    func line(_ text: String) { writeOut(text + "\n") }
    func errorLine(_ text: String) { writeErr(text + "\n") }
}

/// Text formats shared by the commands.
enum Format {
    /// Time since the command started, e.g. `[   1.234]`.
    static func stamp(_ elapsed: Duration) -> String {
        String(format: "[%8.3f]", seconds(of: elapsed))
    }

    /// e.g. `1.3 s`.
    static func seconds(_ duration: Duration) -> String {
        String(format: "%.1f s", seconds(of: duration))
    }

    static func crc32(_ value: UInt32) -> String { String(format: "%08x", value) }
    static func crc16(_ value: UInt16) -> String { String(format: "%04x", value) }

    /// Pages in ascending order, e.g. `1, 2, 3`.
    static func pages<S: Sequence<Int>>(_ pages: S) -> String {
        pages.sorted().map(String.init).joined(separator: ", ")
    }

    /// Progress bar like the Python CLI's, drawn over the current line.
    static func bar(sent: Int, total: Int) -> String {
        let width = 30
        let filled = total > 0 ? width * sent / total : width
        let percent = total > 0 ? sent * 100 / total : 100
        let bar = String(repeating: "#", count: filled) + String(repeating: ".", count: width - filled)
        return "\r  [\(bar)] " + String(format: "%3d%%", percent)
    }

    private static func seconds(of duration: Duration) -> Double {
        let (seconds, attoseconds) = duration.components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}
