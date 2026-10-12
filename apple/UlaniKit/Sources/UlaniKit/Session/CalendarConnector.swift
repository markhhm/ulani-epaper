import Foundation

/// Opens a session the way `client.connect()` does: the whole setup (find, connect,
/// subscribe, unlock) is retried as one unit, because the calendar advertises sparsely
/// and drops new links while its panel refreshes (~40 s after an upload).
public struct CalendarConnector: Sendable {
    /// Finds and connects a calendar; on failure it cleans up whatever it opened itself.
    /// Like `GattLink`, it must throw transport failures as `UlaniError` (a connect timeout
    /// or cancelled subscribe as `linkLost`, no calendar as `notFound`): any other error is
    /// taken for a bug and thrown at once, without retrying.
    public typealias LinkFactory = @Sendable () async throws -> GattLink

    public let attempts: Int
    public let retryDelay: Duration
    public let timing: SessionTiming
    public let readBarrierEvery: Int?
    private let makeLink: LinkFactory

    public init(attempts: Int = 4, retryDelay: Duration = .seconds(5), timing: SessionTiming = .init(),
                readBarrierEvery: Int? = nil, makeLink: @escaping LinkFactory) {
        self.attempts = attempts
        self.retryDelay = retryDelay
        self.timing = timing
        self.readBarrierEvery = readBarrierEvery
        self.makeLink = makeLink
    }

    /// Setup (makeLink + session.start) retried as one unit; then body; then goodbye (best effort) and disconnect (always).
    ///
    /// A link whose setup failed is disconnected before the next attempt. Errors only
    /// the user can fix (`bondLost`, `bluetoothUnavailable`) and errors that are not
    /// UlaniErrors are thrown at once; after the last attempt it throws `connectFailed`.
    /// The goodbye is skipped when `body` throws.
    public func withCalendar<T: Sendable>(_ body: @Sendable (CalendarSession) async throws -> T) async throws -> T {
        let (link, session) = try await connect()
        let value: T
        do {
            value = try await body(session)
        } catch {
            await link.disconnect()
            throw error
        }
        await session.sayGoodbye()
        await link.disconnect()
        return value
    }

    private func connect() async throws -> (any GattLink, CalendarSession) {
        var last: UlaniError?
        var attempt = 0
        while attempt < attempts {
            attempt += 1
            var link: (any GattLink)?
            do {
                let made = try await makeLink()
                link = made
                let session = CalendarSession(link: made, timing: timing, readBarrierEvery: readBarrierEvery)
                try await session.start()
                return (made, session)
            } catch {
                if let link { await link.disconnect() }
                guard let failure = error as? UlaniError, failure.isRetryable else { throw error }
                last = failure
            }
            if attempt < attempts {
                try await Task.sleep(for: retryDelay)
            }
        }
        throw UlaniError.connectFailed(attempts: attempts, last: last.map(\.description) ?? "no attempt was made")
    }
}
