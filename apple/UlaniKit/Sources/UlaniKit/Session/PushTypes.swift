import Foundation

/// Outcome of uploading one page.
public enum UploadResult: String, Sendable {
    case ok
    /// The page already holds an image with the same CRC; nothing was sent.
    case unchanged
}

/// Progress of `CalendarSession.push`, one event per step (Python: `PushEvent`).
///
/// `phase` is `start` (about to upload `page`), `sending` (`sent` of `total` bytes
/// written), `done` / `unchanged` (that page finished), `refreshing` (the page on
/// screen was replaced; the panel now refreshes for ~40 s), or `switching` (the display
/// is being switched to `page`; the panel then refreshes for ~40 s). `index` / `count`
/// give the position in the push (for `switching`: the uploads done so far).
public struct PushEvent: Sendable, Equatable {
    public enum Phase: String, Sendable { case start, sending, done, unchanged, refreshing, switching }

    public let page: Int, phase: Phase, index: Int, count: Int, sent: Int, total: Int

    public init(page: Int, phase: Phase, index: Int, count: Int, sent: Int = 0, total: Int = 0) {
        self.page = page
        self.phase = phase
        self.index = index
        self.count = count
        self.sent = sent
        self.total = total
    }
}

/// Upload order of a push.
public enum PushPlan {
    /// Only replacing the page on screen refreshes the panel (and silences the device for
    /// ~40 s), so that page goes last; the others go first in ascending order.
    public static func order(pages: [Int], shown: Int) -> [Int] {
        let unique = Set(pages)
        return unique.filter { $0 != shown }.sorted() + (unique.contains(shown) ? [shown] : [])
    }
}

/// Timeouts of a session; the defaults are the Python defaults.
public struct SessionTiming: Sendable, Equatable {
    /// How long a command waits for its reply.
    public var replyTimeout: Duration
    /// How long an upload waits for `02 xx` after the data.
    public var resultTimeout: Duration
    /// How long a header or status query is retried while the device is silent or busy.
    public var busyTimeout: Duration
    /// Pause between those attempts.
    public var retryDelay: Duration

    public init(replyTimeout: Duration = .seconds(5), resultTimeout: Duration = .seconds(90),
                busyTimeout: Duration = .seconds(60), retryDelay: Duration = .seconds(3)) {
        self.replyTimeout = replyTimeout
        self.resultTimeout = resultTimeout
        self.busyTimeout = busyTimeout
        self.retryDelay = retryDelay
    }
}
