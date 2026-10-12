import Foundation
import Testing
@testable import UlaniKit

/// `ULANI_RELAY=host:port`, the address of `python -m ulani_epaper.relay --fake --refresh-seconds 2`.
private let relayAddress: (host: String, port: UInt16)? = {
    guard let value = ProcessInfo.processInfo.environment["ULANI_RELAY"],
          let colon = value.lastIndex(of: ":"),
          let port = UInt16(value[value.index(after: colon)...]) else { return nil }
    return (String(value[..<colon]), port)
}()

/// The relay serves a real calendar: these tests push noise, so they refuse it.
private struct NotTheFakeRelay: Error {}

/// UlaniKit end to end through RelayLink and the relay's fake calendar. The fake keeps
/// its pages (and stays silent while it "refreshes") across connections and test runs, so
/// every test pushes fresh random frames and expects the panel may still be refreshing
/// from the test before. One client at a time: the suite is serialized.
@Suite(.serialized, .enabled(if: relayAddress != nil,
                             "set ULANI_RELAY=host:port (python -m ulani_epaper.relay --fake --refresh-seconds 2)"))
struct RelayIntegrationTests {
    /// Short enough to keep the suite fast, long enough for a loaded machine; a refreshing
    /// fake costs one reply timeout per attempt.
    private static let timing = SessionTiming(replyTimeout: .seconds(1), resultTimeout: .seconds(20),
                                              busyTimeout: .seconds(20), retryDelay: .milliseconds(250))

    private func connector() -> CalendarConnector {
        CalendarConnector(attempts: 10, retryDelay: .milliseconds(500), timing: Self.timing) {
            let (host, port) = relayAddress!
            let link = try await RelayLink.connect(host: host, port: port, scanTimeout: .seconds(5))
            guard link.isFake else {
                await link.disconnect()
                throw NotTheFakeRelay()
            }
            return link
        }
    }

    /// Random content, so the fake never holds it already.
    private func randomFrame() -> Frame {
        var generator = SystemRandomNumberGenerator()
        return try! Frame(bytes: Data((0..<Frame.byteCount).map { _ in UInt8.random(in: 0...255, using: &generator) }))
    }

    /// Progress the relay reports for one frame: every 10 chunks of 230 bytes, and the end.
    private static let reportedProgress = (1...83).map { $0 * 2300 } + [Frame.byteCount]

    @Test func queries() async throws {
        let (info, model, firmware, battery) = try await connector().withCalendar { session in
            (try await session.deviceInfo(), try await session.model(), try await session.firmware(),
             try await session.battery())
        }
        #expect(info.serial == "FAKE00000001")
        #expect(model == "P7320E-B")
        #expect(firmware == "v1.0.09")
        #expect(battery == Battery(level: 4, charging: false))
    }

    @Test func pushTwoPagesThenAgainUnchangedThenProbe() async throws {
        let frames = [3: randomFrame(), 2: randomFrame()]
        let events = Recorder<PushEvent>()
        let (shown, results) = try await connector().withCalendar { session in
            let shown = try await session.currentSlot().page
            return (shown, try await session.push(frames) { events.append($0) })
        }
        #expect(results == [2: .ok, 3: .ok])
        let order = PushPlan.order(pages: [2, 3], shown: shown)
        #expect(events.values.filter { $0.phase == .start }.map(\.page) == order)
        for page in order {
            #expect(events.values.filter { $0.page == page && $0.phase == .sending }.map(\.sent) == Self.reportedProgress)
            #expect(events.values.contains(PushEvent(page: page, phase: .done, index: order.firstIndex(of: page)!,
                                                     count: 2, sent: Frame.byteCount, total: Frame.byteCount)))
        }

        let again = Recorder<PushEvent>()
        #expect(try await connector().withCalendar { try await $0.push(frames) { again.append($0) } }
                == [2: .unchanged, 3: .unchanged])
        #expect(again.values.map(\.phase) == [.start, .unchanged, .start, .unchanged])

        let probes = try await connector().withCalendar { session in
            [try await session.probe(page: 2, frame: frames[2]!), try await session.probe(page: 3, frame: frames[3]!)]
        }
        #expect(probes == [.matches, .matches])
    }

    @Test func fourPagesShownLastThenPushesDuringTheRefreshWait() async throws {
        let frames = Dictionary(uniqueKeysWithValues: (1...4).map { ($0, randomFrame()) })
        let replacement = randomFrame()
        let events = Recorder<PushEvent>()
        let clock = ContinuousClock()
        let (shown, first, second, waited) = try await connector().withCalendar { session in
            let shown = try await session.currentSlot().page
            let first = try await session.push(frames) { events.append($0) }
            // The panel refreshes and the fake is silent: the status query is retried.
            let start = clock.now
            let second = try await session.push([shown: replacement])
            return (shown, first, second, clock.now - start)
        }
        #expect(first == [1: .ok, 2: .ok, 3: .ok, 4: .ok])
        let starts = events.values.filter { $0.phase == .start }.map(\.page)
        #expect(starts == (1...4).filter { $0 != shown } + [shown])
        #expect(events.values.last == PushEvent(page: shown, phase: .refreshing, index: 3, count: 4,
                                                sent: Frame.byteCount, total: Frame.byteCount))
        #expect(second == [shown: .ok])
        #expect(waited >= Self.timing.replyTimeout)  // at least one query went unanswered

        // A new connection while the panel refreshes again: the connector retries the setup.
        let other = shown == 1 ? 2 : 1
        let start = clock.now
        let third = try await connector().withCalendar { session in
            try await session.push([shown: frames[shown]!, other: replacement])
        }
        #expect(clock.now - start >= Self.timing.replyTimeout)
        #expect(third == [shown: .ok, other: .ok])
    }
}
